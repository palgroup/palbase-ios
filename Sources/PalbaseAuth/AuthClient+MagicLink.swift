import Foundation

extension PalbaseAuth {
    // MARK: - Magic Link

    /// Send a magic link to the user's email. The link, when opened, returns a token
    /// that you pass to `verifyMagicLink(token:)` to complete sign in.
    ///
    /// - Parameters:
    ///   - email: User's email address.
    ///   - redirectURL: Universal/custom URL the link points to. Your app handles this URL
    ///     and extracts the `token` query parameter.
    public func requestMagicLink(email: String, redirectURL: String? = nil) async throws(AuthError) {
        do {
            let _: SuccessResponseDTO = try await http.request(
                method: "POST",
                path: "/auth/magic-link",
                body: MagicLinkBody(email: email, redirectUrl: redirectURL),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
    }

    /// Verify a magic link token (extracted from the URL the user opened).
    /// On success, session is stored and refresh is wired automatically.
    @discardableResult
    public func verifyMagicLink(token: String) async throws(AuthError) -> AuthSuccess {
        let dto: AuthResultDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "/auth/magic-link/verify",
                body: MagicLinkVerifyBody(token: token),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }

        let session = dto.toSession()
        let user = dto.toUser()
        await tokens.setSession(session)

        return AuthSuccess(user: user, session: session)
    }
}
