import Foundation
@_exported import PalbaseCore

/// Errors specific to the Analytics module.
public enum AnalyticsError: PalbaseError {
    /// SDK not configured. Call `Palbase.configure(apiKey:)` first.
    case notConfigured

    /// Event name failed validation. Must match `^[a-zA-Z][a-zA-Z0-9_.:-]{0,64}$`.
    case invalidEventName(String)

    /// Single event exceeds the configured byte budget.
    case eventTooLarge(maxBytes: Int)

    /// Batch exceeds the configured byte or event-count budget.
    case batchTooLarge(maxBytes: Int, maxEvents: Int)

    /// Local queue overflow.
    case queueFull(maxSize: Int)

    /// Caller invoked an explicit Analytics API while the user is opted out.
    case optedOut

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
        case .invalidEventName: return "invalid_event_name"
        case .eventTooLarge: return "event_too_large"
        case .batchTooLarge: return "batch_too_large"
        case .queueFull: return "queue_full"
        case .optedOut: return "opted_out"
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
        case .invalidEventName(let n):
            return "Invalid event name: \"\(n)\". Allowed: [a-zA-Z][a-zA-Z0-9_.:-]{0,64}."
        case .eventTooLarge(let max):
            return "Single event exceeds maximum of \(max) bytes."
        case .batchTooLarge(let bytes, let events):
            return "Batch exceeds limits: max \(bytes) bytes or \(events) events."
        case .queueFull(let max):
            return "Analytics queue full (max \(max) events)."
        case .optedOut:
            return "User is opted out. Call optIn() before capturing events."
        case .network(let m), .decoding(let m):
            return m
        case .rateLimited(let retryAfter):
            return retryAfter.map { "Rate limited. Retry after \($0)s." } ?? "Rate limited."
        case .serverError(_, let m), .http(_, _, let m, _): return m
        case .server(_, let m, _): return m
        }
    }

    /// Map a generic envelope from the server into a typed AnalyticsError case.
    static func from(envelope: PalbaseErrorEnvelope) -> AnalyticsError {
        switch envelope.code {
        case "invalid_event_name":
            return .invalidEventName(envelope.details?["event"] ?? envelope.message)
        case "payload_too_large":
            return .eventTooLarge(maxBytes: Int(envelope.details?["max_bytes"] ?? "") ?? 32_768)
        default:
            return .server(code: envelope.code, message: envelope.message, requestId: envelope.requestId)
        }
    }

    /// Map transport-level core errors to module-specific cases so
    /// `PalbaseCoreError` never leaks to callers.
    static func from(transport: PalbaseCoreError) -> AnalyticsError {
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
