import Foundation
@_exported import PalbaseCore

/// Errors specific to the Flags module.
public enum FlagsError: PalbaseError {
    /// SDK not configured. Call `Palbase.configure(apiKey:)` first.
    case notConfigured

    /// Realtime subscription requested before `start()` was called.
    case notStarted

    /// No authenticated user — sign in before fetching user-scoped flags.
    case noActiveSession

    // Transport-level (mapped from PalbaseCoreError)
    case network(String)
    case decoding(String)
    case rateLimited(retryAfter: Int?)
    case serverError(status: Int, message: String)
    case http(status: Int, code: String, message: String, requestId: String?)

    /// Unrecognized server error.
    case server(code: String, message: String, requestId: String?)

    public var code: String {
        switch self {
        case .notConfigured: return "not_configured"
        case .notStarted: return "not_started"
        case .noActiveSession: return "no_active_session"
        case .network: return "network_error"
        case .decoding: return "decoding_error"
        case .rateLimited: return "rate_limited"
        case .serverError: return "server_error"
        case .http(_, let code, _, _): return code
        case .server(let code, _, _): return code
        }
    }

    public var statusCode: Int? {
        switch self {
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
        case .notConfigured:
            return "Palbase SDK not configured. Call Palbase.configure(apiKey:) first."
        case .notStarted:
            return "PalbaseFlags not started. Call start() before subscribing to changes."
        case .noActiveSession:
            return "No authenticated user. Sign in before fetching user flags."
        case .network(let m), .decoding(let m):
            return m
        case .rateLimited(let retryAfter):
            return retryAfter.map { "Rate limited. Retry after \($0)s." } ?? "Rate limited."
        case .serverError(_, let m), .http(_, _, let m, _): return m
        case .server(_, let m, _): return m
        }
    }

    /// Map a generic envelope from the server into a typed FlagsError case.
    static func from(envelope: PalbaseErrorEnvelope) -> FlagsError {
        .server(code: envelope.code, message: envelope.message, requestId: envelope.requestId)
    }

    /// Map transport-level core errors to module-specific cases so
    /// `PalbaseCoreError` never leaks to callers.
    static func from(transport: PalbaseCoreError) -> FlagsError {
        switch transport {
        case .network(let m): return .network(m)
        case .decoding(let m): return .decoding(m)
        case .encoding(let m): return .network(m)
        case .rateLimited(let r): return .rateLimited(retryAfter: r)
        case .server(let s, let m): return .serverError(status: s, message: m)
        case .http(let s, let c, let m, let id):
            return .http(status: s, code: c, message: m, requestId: id)
        case .invalidConfiguration(let m): return .network(m)
        case .notConfigured: return .notConfigured
        case .tokenRefreshFailed(let m): return .network(m)
        }
    }
}
