import Foundation
@_exported import PalbaseCore

/// Errors specific to the Auth module.
public enum AuthError: PalbaseError {
    // Auth-specific
    case invalidCredentials(message: String = "Invalid email or password")
    case userNotFound(message: String = "User not found")
    case emailAlreadyInUse(message: String = "Email already registered")
    case weakPassword(message: String = "Password does not meet requirements")
    case emailNotVerified(message: String = "Email not verified")
    case mfaRequired(challengeId: String)
    case sessionExpired(message: String = "Session expired, please sign in again")
    case noActiveSession(message: String = "No active session")
    case mfaInvalidCode(message: String = "Invalid MFA code")
    case mfaFactorNotFound(message: String = "MFA factor not found")
    case passkeyNotSupported(message: String = "Passkeys require iOS 16+")
    case passkeyCancelled(message: String = "Passkey authentication cancelled")

    // Generic transport (translated from PalbaseCoreError)
    case network(message: String)
    case decoding(message: String)
    case rateLimited(retryAfter: Int?)
    case serverError(status: Int, message: String)
    case http(status: Int, code: String, message: String, requestId: String?)

    /// Unrecognized server error.
    case server(code: String, message: String, requestId: String?)

    /// SDK not configured. Call `Palbase.configure(apiKey:)` first.
    case notConfigured

    public var code: String {
        switch self {
        case .invalidCredentials: return "invalid_credentials"
        case .userNotFound: return "user_not_found"
        case .emailAlreadyInUse: return "email_already_in_use"
        case .weakPassword: return "weak_password"
        case .emailNotVerified: return "email_not_verified"
        case .mfaRequired: return "mfa_required"
        case .sessionExpired: return "session_expired"
        case .noActiveSession: return "no_active_session"
        case .mfaInvalidCode: return "mfa_invalid_code"
        case .mfaFactorNotFound: return "mfa_factor_not_found"
        case .passkeyNotSupported: return "passkey_not_supported"
        case .passkeyCancelled: return "passkey_cancelled"
        case .network: return "network_error"
        case .decoding: return "decoding_error"
        case .rateLimited: return "rate_limited"
        case .serverError: return "server_error"
        case .http(_, let code, _, _): return code
        case .server(let code, _, _): return code
        case .notConfigured: return "not_configured"
        }
    }

    public var statusCode: Int? {
        switch self {
        case .invalidCredentials, .sessionExpired: return 401
        case .emailAlreadyInUse: return 409
        case .userNotFound: return 404
        case .rateLimited: return 429
        case .serverError(let s, _): return s
        case .http(let s, _, _, _): return s
        default: return nil
        }
    }

    public var requestId: String? {
        switch self {
        case .http(_, _, _, let id): return id
        case .server(_, _, let id): return id
        default: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials(let m), .userNotFound(let m), .emailAlreadyInUse(let m),
             .weakPassword(let m), .emailNotVerified(let m), .sessionExpired(let m),
             .noActiveSession(let m), .mfaInvalidCode(let m), .mfaFactorNotFound(let m),
             .passkeyNotSupported(let m), .passkeyCancelled(let m),
             .network(let m), .decoding(let m):
            return m
        case .mfaRequired: return "MFA challenge required"
        case .rateLimited(let retryAfter):
            return retryAfter.map { "Rate limited. Retry after \($0)s." } ?? "Rate limited."
        case .serverError(_, let m), .http(_, _, let m, _): return m
        case .server(_, let m, _): return m
        case .notConfigured: return "Palbase SDK not configured. Call Palbase.configure(apiKey:) first."
        }
    }

    /// Map a server-side error code to a typed AuthError case. Used by
    /// both the envelope decoder and the transport-error fallback so a
    /// fresh `password_too_short` from palauth ends up as
    /// `.weakPassword`, not the catch-all `.http(...)`.
    private static func mapServerCode(_ code: String, message: String, requestId: String?) -> AuthError? {
        switch code {
        // Credentials / sign-in
        case "invalid_credentials", "invalid_login_credentials":
            return .invalidCredentials(message: message)
        case "user_not_found":
            return .userNotFound(message: message)
        // Sign-up / password
        case "email_already_in_use", "user_already_exists", "email_exists":
            return .emailAlreadyInUse(message: message)
        case "weak_password", "password_too_short", "password_too_weak", "password_too_long":
            return .weakPassword(message: message)
        // Email verification
        case "email_not_verified", "email_unverified":
            return .emailNotVerified(message: message)
        // Sessions
        case "session_expired", "token_expired", "invalid_token", "unauthorized":
            return .sessionExpired(message: message)
        // MFA
        case "mfa_invalid_code", "invalid_mfa_code":
            return .mfaInvalidCode(message: message)
        case "mfa_factor_not_found":
            return .mfaFactorNotFound(message: message)
        default:
            return nil
        }
    }

    /// Map a generic envelope from the server into a typed AuthError case.
    static func from(envelope: PalbaseErrorEnvelope) -> AuthError {
        if envelope.code == "mfa_required" {
            let challengeId = envelope.details?["challenge_id"] ?? ""
            return .mfaRequired(challengeId: challengeId)
        }
        if let mapped = mapServerCode(envelope.code, message: envelope.message, requestId: envelope.requestId) {
            return mapped
        }
        return .server(code: envelope.code, message: envelope.message, requestId: envelope.requestId)
    }

    /// Map transport-level core errors to module-specific cases (so PalbaseCoreError
    /// stays internal/package and never leaks to the user).
    static func from(transport: PalbaseCoreError) -> AuthError {
        switch transport {
        case .network(let m): return .network(message: m)
        case .decoding(let m): return .decoding(message: m)
        case .encoding(let m): return .network(message: m)  // surface as network for users
        case .rateLimited(let r): return .rateLimited(retryAfter: r)
        case .server(let s, let m): return .serverError(status: s, message: m)
        case .http(let s, let c, let m, let id):
            // First try the auth-specific code map so server codes
            // like password_too_short / invalid_credentials surface as
            // typed cases. Falls back to .http when the code is
            // genuinely outside the auth domain.
            if let mapped = mapServerCode(c, message: m, requestId: id) {
                return mapped
            }
            return .http(status: s, code: c, message: m, requestId: id)
        case .invalidConfiguration(let m): return .network(message: m)
        case .notConfigured: return .notConfigured
        case .tokenRefreshFailed(let m): return .sessionExpired(message: m)
        }
    }
}
