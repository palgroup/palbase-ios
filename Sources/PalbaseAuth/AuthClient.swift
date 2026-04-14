import Foundation
@_exported import PalbaseCore

public actor PalbaseAuthClient {
    private let http: HttpClient
    private let tokens: TokenManager

    /// Direct construction — for granular module-only usage.
    /// ```swift
    /// let auth = PalbaseAuthClient(apiKey: "pb_abc123_xxx")
    /// ```
    public init(apiKey: String, options: HttpClientOptions = .init()) {
        let http = HttpClient(apiKey: apiKey, options: options)
        let tokens = TokenManager()
        self.http = http
        self.tokens = tokens
        Task { await http.setTokenManager(tokens) }
    }

    /// Internal — used by `PalbaseClient` umbrella to share HttpClient/TokenManager.
    public init(sharedHttp: HttpClient, sharedTokens: TokenManager) {
        self.http = sharedHttp
        self.tokens = sharedTokens
    }

    // MARK: - Public properties (read-only access for advanced cases)

    public var httpClient: HttpClient { http }
    public var tokenManager: TokenManager { tokens }

    // MARK: - Core Auth

    /// Create a new user with email and password.
    public func signUp(email: String, password: String) async -> PalbaseResponse<AuthSuccess> {
        let creds = SignUpCredentials(email: email, password: password)
        let response = await http.request(
            "POST",
            path: "/auth/signup",
            body: creds,
            decoding: AuthResultDTO.self
        )

        return await handleAuthResult(response)
    }

    /// Sign in with email and password.
    public func signIn(email: String, password: String) async -> PalbaseResponse<AuthSuccess> {
        let creds = SignInCredentials(email: email, password: password)
        let response = await http.request(
            "POST",
            path: "/auth/login",
            body: creds,
            decoding: AuthResultDTO.self
        )

        return await handleAuthResult(response)
    }

    /// Sign out the current user. Clears the local session.
    @discardableResult
    public func signOut() async -> PalbaseResponse<EmptyResponse> {
        let response = await http.requestVoid("POST", path: "/auth/logout")
        await tokens.clearSession()
        return response
    }

    /// Fetch the current user from the server. Requires active session.
    public func getUser() async -> PalbaseResponse<User> {
        struct UserResponseDTO: Decodable {
            let user: UserInfoDTO
        }

        let response = await http.request(
            "GET",
            path: "/auth/user",
            decoding: UserResponseDTO.self
        )

        if let dto = response.data {
            let user = User(
                id: dto.user.id,
                email: dto.user.email,
                emailVerified: dto.user.emailVerified,
                createdAt: dto.user.createdAt,
                updatedAt: dto.user.createdAt
            )
            return PalbaseResponse(data: user, error: nil, status: response.status)
        }
        return PalbaseResponse(data: nil, error: response.error, status: response.status)
    }

    // MARK: - Private helpers

    private func handleAuthResult(_ response: PalbaseResponse<AuthResultDTO>) async -> PalbaseResponse<AuthSuccess> {
        guard let dto = response.data else {
            return PalbaseResponse(data: nil, error: response.error, status: response.status)
        }

        let session = dto.toSession()
        let user = dto.toUser()

        await tokens.setSession(session)
        await wireRefreshFunction()

        return PalbaseResponse(
            data: AuthSuccess(user: user, session: session),
            error: nil,
            status: response.status
        )
    }

    /// Wires the refresh function into TokenManager so HttpClient auto-refreshes on expiry.
    private func wireRefreshFunction() async {
        let client = http
        let fn: RefreshFunction = { refreshToken in
            struct RefreshBody: Encodable {
                let refreshToken: String
                enum CodingKeys: String, CodingKey {
                    case refreshToken = "refresh_token"
                }
            }

            let body = RefreshBody(refreshToken: refreshToken)
            let response = await client.request(
                "POST",
                path: "/auth/refresh",
                body: body,
                decoding: AuthResultDTO.self
            )

            if let dto = response.data {
                return dto.toSession()
            }
            throw response.error ?? PalbaseError(code: "refresh_failed", message: "Failed to refresh session")
        }

        await tokens.setRefreshFunction(fn)
    }
}
