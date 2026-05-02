import Foundation

extension PalbaseAuth {
    // MARK: - Token Refresh

    /// Force a token refresh now using the stored refresh token.
    /// Normally you don't call this — `HttpClient` auto-refreshes on expiry
    /// and clears the session if refresh is fatal.
    @discardableResult
    public func refresh() async throws(AuthError) -> Session {
        guard let refreshToken = await tokens.refreshToken else {
            throw AuthError.noActiveSession()
        }

        // Encoder applies convertToSnakeCase, so `refreshToken` →
        // `refresh_token` on the wire. PalbaseCore wires the same
        // shape into TokenManager.refreshFunction at boot — single
        // source of truth for the refresh contract.
        struct Body: Encodable, Sendable { let refreshToken: String }

        let dto: TokenResponseDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "/auth/token/refresh",
                body: Body(refreshToken: refreshToken),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }

        let session = dto.toSession()
        await tokens.setSession(session)
        return session
    }

    // MARK: - Session Management

    /// List all active sessions for the current user across devices.
    public func listSessions() async throws(AuthError) -> [AuthSession] {
        let dto: AuthSessionListDTO
        do {
            dto = try await http.request(
                method: "GET",
                path: "/auth/sessions",
                body: nil,
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
        return dto.sessions.map { $0.toAuthSession() }
    }

    /// Revoke a specific session by ID. The user remains signed in if the session is not the current one.
    public func revokeSession(id: String) async throws(AuthError) {
        do {
            try await http.requestVoid(
                method: "DELETE",
                path: "/auth/sessions/\(id)",
                body: nil,
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
    }

    /// Revoke all sessions for the current user (signs out all devices including this one).
    public func revokeAllSessions() async throws(AuthError) {
        defer { Task { await tokens.clearSession() } }
        do {
            try await http.requestVoid(
                method: "DELETE",
                path: "/auth/sessions",
                body: nil,
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
    }
}
