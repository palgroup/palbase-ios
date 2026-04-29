import Foundation
@_exported import PalbaseCore

/// Errors raised by the Notifications module.
public enum NotificationsError: PalbaseError {
    case notConfigured
    case invalidPlatform(String)
    case emptyDeviceToken
    case emptyDeviceId

    // Transport-level (mapped from PalbaseCoreError).
    case network(String)
    case encoding(String)
    case decoding(String)
    case rateLimited(retryAfter: Int?)
    case http(status: Int, code: String, message: String, requestId: String?)
    case server(code: String, message: String, requestId: String?)

    public var code: String {
        switch self {
        case .notConfigured: return "not_configured"
        case .invalidPlatform: return "invalid_platform"
        case .emptyDeviceToken: return "empty_device_token"
        case .emptyDeviceId: return "empty_device_id"
        case .network: return "network_error"
        case .encoding: return "encoding_error"
        case .decoding: return "decoding_error"
        case .rateLimited: return "rate_limited"
        case .http(_, let c, _, _): return c
        case .server(let c, _, _): return c
        }
    }

    public var statusCode: Int? {
        switch self {
        case .rateLimited: return 429
        case .http(let s, _, _, _): return s
        default: return nil
        }
    }

    public var requestId: String? {
        switch self {
        case .http(_, _, _, let id), .server(_, _, let id): return id
        default: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "PalbaseNotifications not configured. Call Palbase.configure() first."
        case .invalidPlatform(let p):
            return "Invalid device platform: \(p). Expected one of: ios, android, web."
        case .emptyDeviceToken:
            return "Device token must not be empty."
        case .emptyDeviceId:
            return "Device id must not be empty."
        case .network(let m): return m
        case .encoding(let m): return m
        case .decoding(let m): return m
        case .rateLimited(let r):
            if let r { return "Rate limited. Retry after \(r)s." }
            return "Rate limited."
        case .http(_, _, let m, _), .server(_, let m, _): return m
        }
    }

    /// Map a PalbaseCoreError into a NotificationsError so callers see one
    /// typed error per call.
    package static func from(transport err: PalbaseCoreError) -> NotificationsError {
        switch err {
        case .network(let m): return .network(m)
        case .encoding(let m): return .encoding(m)
        case .decoding(let m): return .decoding(m)
        case .rateLimited(let r): return .rateLimited(retryAfter: r)
        case .http(let s, let c, let m, let id):
            return .http(status: s, code: c, message: m, requestId: id)
        case .server(let s, let m):
            // PalbaseCoreError's `.server` carries (status, message); we
            // expose it as an HTTP error keyed by the status to keep the
            // mapping lossless.
            return .http(status: s, code: "server_error", message: m, requestId: nil)
        case .notConfigured: return .notConfigured
        case .invalidConfiguration(let m): return .network("invalid configuration: \(m)")
        case .tokenRefreshFailed(let m): return .network("token refresh failed: \(m)")
        }
    }
}
