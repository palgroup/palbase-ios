import Foundation

extension PalbaseAuth {
    // MARK: - Email Verification

    /// Verify a user's email using either a token (from email link) or a code.
    /// Pass at least one of `token` or `code`.
    public func verifyEmail(token: String? = nil, code: String? = nil, email: String? = nil) async throws(AuthError) {
        let body = VerifyEmailBody(token: token, code: code, email: email)
        do {
            let _: StatusResponseDTO = try await http.request(
                method: "POST",
                path: "/auth/verify-email",
                body: body,
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
    }

    /// Resend a verification challenge to the given email.
    /// Returns the new challenge (token/code) the server issued, when available.
    @discardableResult
    public func resendVerification(email: String) async throws(AuthError) -> VerificationChallenge {
        do {
            let dto: VerificationResponseDTO = try await http.request(
                method: "POST",
                path: "/auth/resend-verification",
                body: ResendVerificationBody(email: email),
                headers: [:]
            )
            return dto.toChallenge()
        } catch {
            throw AuthError.from(transport: error)
        }
    }
}
