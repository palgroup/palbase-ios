import Foundation

extension PalbaseAuth {
    // MARK: - Password

    /// Request a password reset email. Always returns success regardless of whether
    /// the email exists (to prevent user enumeration).
    public func requestPasswordReset(email: String) async throws(AuthError) {
        do {
            let _: SuccessResponseDTO = try await http.request(
                method: "POST",
                path: "/auth/password/reset",
                body: PasswordResetBody(email: email),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
    }

    /// Confirm a password reset using the token sent to the user's email.
    public func confirmPasswordReset(token: String, newPassword: String) async throws(AuthError) {
        do {
            let _: SuccessResponseDTO = try await http.request(
                method: "POST",
                path: "/auth/password/reset/confirm",
                body: PasswordResetConfirmBody(token: token, newPassword: newPassword),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
    }

    /// Change the password for the currently authenticated user.
    /// Requires the current password for re-authentication.
    public func changePassword(currentPassword: String, newPassword: String) async throws(AuthError) {
        do {
            let _: SuccessResponseDTO = try await http.request(
                method: "POST",
                path: "/auth/password/change",
                body: PasswordChangeBody(currentPassword: currentPassword, newPassword: newPassword),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
    }
}
