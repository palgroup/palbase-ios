import Foundation
import PalbaseCore

/// Auth module entry point. Use `PalbaseAuth.shared` after calling `PalbaseSDK.configure(apiKey:)`.
public struct PalbaseAuth: Sendable {
    private let http: HTTPRequesting
    private let tokens: TokenManager

    /// Internal — used by `.shared` and tests.
    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared auth client backed by the global SDK configuration.
    /// Trapping access if `PalbaseSDK.configure(_:)` was not called.
    public static var shared: PalbaseAuth {
        get throws {
            let http = try PalbaseSDK.requireHTTP()
            let tokens = try PalbaseSDK.requireTokens()
            return PalbaseAuth(http: http, tokens: tokens)
        }
    }

    // MARK: - Core Auth

    /// Create a new user with email and password.
    /// On success, the returned session is automatically stored and refresh is wired.
    @discardableResult
    public func signUp(email: String, password: String) async throws -> AuthSuccess {
        try await performAuth(path: "/auth/signup", body: SignUpCredentials(email: email, password: password))
    }

    /// Sign in with email and password.
    @discardableResult
    public func signIn(email: String, password: String) async throws -> AuthSuccess {
        try await performAuth(path: "/auth/login", body: SignInCredentials(email: email, password: password))
    }

    /// Sign out the current user. Always clears the local session, even if the
    /// server call fails.
    public func signOut() async throws {
        defer { Task { await tokens.clearSession() } }
        try await http.requestVoid(method: "POST", path: "/auth/logout", body: nil, headers: [:])
    }

    /// Fetch the currently authenticated user from the server.
    public func getUser() async throws -> User {
        let dto: UserResponseDTO
        do {
            dto = try await http.request(method: "GET", path: "/auth/user", body: nil, headers: [:])
        } catch let core as PalbaseCoreError {
            throw mapAuthError(core)
        }
        return dto.toUser()
    }

    // MARK: - Private

    private func performAuth(path: String, body: any Encodable & Sendable) async throws -> AuthSuccess {
        let dto: AuthResultDTO
        do {
            dto = try await http.request(method: "POST", path: path, body: body, headers: [:])
        } catch let core as PalbaseCoreError {
            throw mapAuthError(core)
        }

        let session = dto.toSession()
        let user = dto.toUser()
        await tokens.setSession(session)
        await wireRefresh()

        return AuthSuccess(user: user, session: session)
    }

    private func wireRefresh() async {
        let httpRef = http
        let fn: RefreshFunction = { refreshToken in
            struct RefreshBody: Encodable, Sendable {
                let refreshToken: String
            }
            let dto: AuthResultDTO = try await httpRef.request(
                method: "POST",
                path: "/auth/refresh",
                body: RefreshBody(refreshToken: refreshToken),
                headers: [:]
            )
            return dto.toSession()
        }
        await tokens.setRefreshFunction(fn)
    }

    /// Map transport-level core error to auth-specific error if the server envelope matches.
    private func mapAuthError(_ core: PalbaseCoreError) -> Error {
        if case .http(_, _, _, _) = core {
            // Server sends a structured envelope on 4xx — but PalbaseCoreError already lost
            // the parsed envelope. We surface as transport for now; module-specific mapping
            // happens server-side via well-known error codes.
            return AuthError.transport(core)
        }
        return AuthError.transport(core)
    }
}
