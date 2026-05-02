import Foundation
@_exported import PalbaseCore

/// Auth module entry point. Use `PalbaseAuth.shared` after calling `Palbase.configure(apiKey:)`.
public struct PalbaseAuth: Sendable {
    let http: HTTPRequesting
    let tokens: TokenManager

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared auth client backed by the global SDK configuration.
    /// Throws `AuthError.notConfigured` if `Palbase.configure(apiKey:)` was not called.
    public static var shared: PalbaseAuth {
        get throws(AuthError) {
            guard let http = Palbase.http, let tokens = Palbase.tokens else {
                throw AuthError.notConfigured
            }
            return PalbaseAuth(http: http, tokens: tokens)
        }
    }

    // MARK: - Session inspection

    /// Currently active session, or nil if signed out.
    public var currentSession: Session? {
        get async { await tokens.currentSession }
    }

    /// Convenience: true if there's an active (not expired) session.
    public var isSignedIn: Bool {
        get async {
            guard let s = await tokens.currentSession else { return false }
            return !s.isExpired
        }
    }

    // MARK: - Auth state listener

    /// Subscribe to auth events (sessionSet, sessionCleared, tokenRefreshed).
    /// Returns an `Unsubscribe` closure — call it when you no longer want events.
    ///
    /// > Warning: Capture `self` weakly in the closure to avoid retain cycles:
    /// > ```swift
    /// > let unsub = await PalbaseAuth.shared.onAuthStateChange { [weak self] event, session in
    /// >     self?.handle(event, session)
    /// > }
    /// > ```
    @discardableResult
    public func onAuthStateChange(_ callback: @escaping AuthStateCallback) async -> Unsubscribe {
        await tokens.onAuthStateChange(callback)
    }

    // MARK: - Core Auth

    /// Create a new user with email and password.
    /// On success, the returned session is automatically stored and refresh is wired.
    @discardableResult
    public func signUp(email: String, password: String) async throws(AuthError) -> AuthSuccess {
        try await performAuth(path: "/auth/signup", body: SignUpCredentials(email: email, password: password))
    }

    /// Sign in with email and password.
    @discardableResult
    public func signIn(email: String, password: String) async throws(AuthError) -> AuthSuccess {
        try await performAuth(path: "/auth/login", body: SignInCredentials(email: email, password: password))
    }

    /// Sign out the current user. Always clears the local session, even if the
    /// server call fails.
    public func signOut() async throws(AuthError) {
        defer { Task { await tokens.clearSession() } }
        do {
            try await http.requestVoid(method: "POST", path: "/auth/logout", body: nil, headers: [:])
        } catch {
            throw AuthError.from(transport: error)
        }
    }

    /// Fetch the currently authenticated user from the server.
    public func getUser() async throws(AuthError) -> User {
        let dto: UserResponseDTO
        do {
            dto = try await http.request(method: "GET", path: "/auth/user", body: nil, headers: [:])
        } catch {
            throw AuthError.from(transport: error)
        }
        return dto.toUser()
    }

    // MARK: - Private

    private func performAuth(path: String, body: any Encodable & Sendable) async throws(AuthError) -> AuthSuccess {
        let dto: AuthResultDTO
        do {
            dto = try await http.request(method: "POST", path: path, body: body, headers: [:])
        } catch {
            throw AuthError.from(transport: error)
        }

        let session = dto.toSession()
        let user = dto.toUser()
        await tokens.setSession(session)
        // Refresh function is wired once at `Palbase.configure` time
        // (PalbaseCore/Palbase.swift). Re-wiring here on every signIn /
        // signUp would shadow that with a duplicate closure pointing
        // at a different path/body shape — exactly what produced the
        // `/auth/refresh` 404 / silent-fail loop earlier this week.
        return AuthSuccess(user: user, session: session)
    }
}
