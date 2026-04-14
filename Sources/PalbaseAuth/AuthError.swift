import Foundation
import PalbaseCore

/// Errors specific to the Auth module.
public enum AuthError: PalbaseError {
    case invalidCredentials(message: String = "Invalid email or password")
    case userNotFound(message: String = "User not found")
    case emailAlreadyInUse(message: String = "Email already registered")
    case weakPassword(message: String = "Password does not meet requirements")
    case emailNotVerified(message: String = "Email not verified")
    case mfaRequired(challengeId: String)
    case sessionExpired(message: String = "Session expired, please sign in again")
    case noActiveSession(message: String = "No active session")

    /// HTTP transport error wrapped with auth context.
    case transport(PalbaseCoreError)

    /// Unrecognized server error.
    case server(code: String, message: String, requestId: String?)

    /// SDK not configured. Call `PalbaseSDK.configure(apiKey:)` first.
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
        case .transport(let core): return core.code
        case .server(let code, _, _): return code
        case .notConfigured: return "not_configured"
        }
    }

    public var statusCode: Int? {
        switch self {
        case .invalidCredentials, .sessionExpired: return 401
        case .emailAlreadyInUse: return 409
        case .userNotFound: return 404
        case .transport(let core): return core.statusCode
        default: return nil
        }
    }

    public var requestId: String? {
        switch self {
        case .transport(let core): return core.requestId
        case .server(_, _, let id): return id
        default: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials(let m), .userNotFound(let m), .emailAlreadyInUse(let m),
             .weakPassword(let m), .emailNotVerified(let m), .sessionExpired(let m),
             .noActiveSession(let m):
            return m
        case .mfaRequired: return "MFA challenge required"
        case .transport(let core): return core.errorDescription
        case .server(_, let m, _): return m
        case .notConfigured: return "Palbase SDK not configured. Call PalbaseSDK.configure(apiKey:) first."
        }
    }

    /// Map a generic envelope from the server into a typed AuthError case.
    static func from(envelope: PalbaseErrorEnvelope) -> AuthError {
        switch envelope.code {
        case "invalid_credentials": return .invalidCredentials(message: envelope.message)
        case "user_not_found": return .userNotFound(message: envelope.message)
        case "email_already_in_use": return .emailAlreadyInUse(message: envelope.message)
        case "weak_password": return .weakPassword(message: envelope.message)
        case "email_not_verified": return .emailNotVerified(message: envelope.message)
        case "mfa_required":
            let challengeId = envelope.details?["challenge_id"] ?? ""
            return .mfaRequired(challengeId: challengeId)
        case "session_expired": return .sessionExpired(message: envelope.message)
        default:
            return .server(code: envelope.code, message: envelope.message, requestId: envelope.requestId)
        }
    }

    static func fromTransport(_ error: PalbaseCoreError) -> AuthError {
        .transport(error)
    }
}
