import Foundation
@_exported import PalbaseCore

/// Errors specific to the Realtime module.
public enum RealtimeError: PalbaseError {
    /// SDK not configured. Call `Palbase.configure(apiKey:)` first.
    case notConfigured

    /// Channel name failed validation (must match `^[a-zA-Z0-9_\-:]+$`, max 255 chars).
    case invalidChannelName(String)

    /// Operation requires the channel to be subscribed first.
    case notSubscribed(channel: String)

    /// `phx_join` did not receive `phx_reply` ok within the timeout.
    case subscriptionTimeout(channel: String)

    /// Underlying WebSocket connection was closed.
    case connectionClosed(reason: String)

    /// WebSocket connection failed to open.
    case connectionFailed(message: String)

    /// Failed to encode an outgoing message.
    case messageEncodingFailed(message: String)

    /// Failed to decode an incoming message.
    case messageDecodingFailed(message: String)

    /// Network-level failure (mapped from `PalbaseCoreError.network`).
    case network(String)

    /// Server returned an error reply for a join/send.
    case serverError(message: String)

    public var code: String {
        switch self {
        case .notConfigured: return "not_configured"
        case .invalidChannelName: return "invalid_channel_name"
        case .notSubscribed: return "not_subscribed"
        case .subscriptionTimeout: return "subscription_timeout"
        case .connectionClosed: return "connection_closed"
        case .connectionFailed: return "connection_failed"
        case .messageEncodingFailed: return "message_encoding_failed"
        case .messageDecodingFailed: return "message_decoding_failed"
        case .network: return "network_error"
        case .serverError: return "server_error"
        }
    }

    public var statusCode: Int? { nil }
    public var requestId: String? { nil }

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Palbase SDK not configured. Call Palbase.configure(apiKey:) first."
        case .invalidChannelName(let n):
            return "Invalid channel name: \"\(n)\". Allowed: [a-zA-Z0-9_-:], max 255 chars."
        case .notSubscribed(let c):
            return "Channel \"\(c)\" is not subscribed. Call subscribe() first."
        case .subscriptionTimeout(let c):
            return "Channel \"\(c)\" subscription timed out waiting for phx_reply."
        case .connectionClosed(let r):
            return "Realtime connection closed: \(r)"
        case .connectionFailed(let m):
            return "Realtime connection failed: \(m)"
        case .messageEncodingFailed(let m):
            return "Failed to encode message: \(m)"
        case .messageDecodingFailed(let m):
            return "Failed to decode message: \(m)"
        case .network(let m):
            return m
        case .serverError(let m):
            return m
        }
    }

    /// Map transport-level core errors to module-specific cases so
    /// `PalbaseCoreError` never leaks to callers.
    static func from(transport: PalbaseCoreError) -> RealtimeError {
        switch transport {
        case .network(let m): return .network(m)
        case .decoding(let m): return .messageDecodingFailed(message: m)
        case .encoding(let m): return .messageEncodingFailed(message: m)
        case .rateLimited: return .network("Rate limited")
        case .server(_, let m): return .serverError(message: m)
        case .http(_, _, let m, _): return .serverError(message: m)
        case .invalidConfiguration(let m): return .connectionFailed(message: m)
        case .notConfigured: return .notConfigured
        case .tokenRefreshFailed(let m): return .network(m)
        }
    }
}
