import Foundation

extension PalbaseAuth {
    // MARK: - MFA Enrollment (TOTP)

    /// Enroll a new MFA factor. For TOTP, the result includes a `secret` and `otpUrl`
    /// — show them to the user (e.g., via a QR code) so they can add the factor to
    /// Google Authenticator / 1Password / etc.
    public func enrollMFA(type: MFAFactorType) async throws(AuthError) -> MFAEnrollResult {
        let dto: MFAEnrollResultDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "/auth/mfa/enroll",
                body: MFAEnrollBody(type: type.rawValue),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
        return dto.toResult()
    }

    /// Confirm enrollment by submitting the first TOTP code the user generated.
    public func verifyMFAEnrollment(code: String) async throws(AuthError) {
        do {
            let _: StatusResponseDTO = try await http.request(
                method: "POST",
                path: "/auth/mfa/verify",
                body: MFAVerifyEnrollmentBody(code: code),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
    }

    // MARK: - MFA Challenge (during sign-in)

    /// Submit an MFA code during the second step of sign-in. Use the `mfaToken`
    /// returned alongside `AuthError.mfaRequired(challengeId:)`.
    @discardableResult
    public func submitMFAChallenge(
        mfaToken: String,
        type: MFAFactorType,
        code: String
    ) async throws(AuthError) -> Session {
        let dto: TokenResponseDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "/auth/mfa/challenge",
                body: MFAChallengeBody(mfaToken: mfaToken, type: type.rawValue, code: code),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }

        let session = dto.toSession()
        await tokens.setSession(session)
        return session
    }

    /// Use a one-time recovery code instead of a TOTP code.
    @discardableResult
    public func recoverMFA(mfaToken: String, recoveryCode: String) async throws(AuthError) -> Session {
        let dto: TokenResponseDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "/auth/mfa/recovery",
                body: MFARecoveryBody(mfaToken: mfaToken, code: recoveryCode),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }

        let session = dto.toSession()
        await tokens.setSession(session)
        return session
    }

    // MARK: - Email MFA

    /// Enroll the user for email-based MFA. After this, sign-in flows that hit
    /// `mfa_required` may use email codes.
    public func enrollEmailMFA() async throws(AuthError) -> MFAEnrollResult {
        let dto: MFAEnrollResultDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "/auth/mfa/email/enroll",
                body: nil,
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
        return dto.toResult()
    }

    /// Request that the server send an email code for an email-MFA challenge.
    public func sendEmailMFACode(mfaToken: String) async throws(AuthError) {
        do {
            let _: StatusResponseDTO = try await http.request(
                method: "POST",
                path: "/auth/mfa/email/challenge",
                body: MFAEmailChallengeBody(mfaToken: mfaToken),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
    }

    /// Verify an email MFA code the user received.
    @discardableResult
    public func verifyEmailMFACode(mfaToken: String, code: String) async throws(AuthError) -> Session {
        let dto: TokenResponseDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "/auth/mfa/email/verify",
                body: MFAEmailVerifyBody(mfaToken: mfaToken, code: code),
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }

        let session = dto.toSession()
        await tokens.setSession(session)
        return session
    }

    // MARK: - Factor management

    /// List all MFA factors enrolled on the user's account.
    public func listMFAFactors() async throws(AuthError) -> [MFAFactor] {
        let dto: MFAFactorListDTO
        do {
            dto = try await http.request(
                method: "GET",
                path: "/auth/mfa/factors",
                body: nil,
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
        return dto.factors.compactMap { $0.toFactor() }
    }

    /// Remove an MFA factor by ID.
    public func removeMFAFactor(id: String) async throws(AuthError) {
        do {
            try await http.requestVoid(
                method: "DELETE",
                path: "/auth/mfa/factors/\(id)",
                body: nil,
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
    }

    /// Regenerate one-time recovery codes (invalidates the previous set).
    /// Show the new codes to the user once and ask them to save.
    public func regenerateRecoveryCodes() async throws(AuthError) -> [String] {
        let dto: RecoveryCodesDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "/auth/mfa/recovery-codes/regenerate",
                body: nil,
                headers: [:]
            )
        } catch {
            throw AuthError.from(transport: error)
        }
        return dto.recoveryCodes
    }
}
