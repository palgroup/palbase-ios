import Foundation

/// Common protocol for all Palbase errors. Each module defines its own concrete error type
/// that conforms to this — uniform handling, module-specific cases.
public protocol PalbaseError: Error, Sendable, LocalizedError {
    /// Stable error code (snake_case). Useful for programmatic handling and i18n keys.
    var code: String { get }

    /// HTTP status code if the error originated from an HTTP response.
    var statusCode: Int? { get }

    /// Server-provided request ID for tracing.
    var requestId: String? { get }
}

extension PalbaseError {
    public var statusCode: Int? { nil }
    public var requestId: String? { nil }
}

// MARK: - Core (transport-level) errors

/// Errors raised by the HTTP transport layer and SDK configuration.
/// Module-specific errors (e.g., `AuthError`) are defined in their own module.
public enum PalbaseCoreError: PalbaseError {
    /// Network-level failure (no response, connection lost, timeout).
    case network(message: String)

    /// Server returned an HTTP error response without a recognized envelope.
    case http(status: Int, code: String, message: String, requestId: String? = nil)

    /// Failed to decode the response body.
    case decoding(message: String)

    /// Failed to encode the request body.
    case encoding(message: String)

    /// Rate limit exceeded (429).
    case rateLimited(retryAfter: Int? = nil)

    /// Server error (5xx).
    case server(status: Int, message: String)

    /// Invalid configuration (e.g., malformed API key, missing URL).
    case invalidConfiguration(message: String)

    /// SDK not configured. Call `Palbase.configure(apiKey:)` first.
    case notConfigured

    /// Token refresh failed (no refresh token, refresh endpoint failed).
    case tokenRefreshFailed(message: String)

    public var code: String {
        switch self {
        case .network: return "network_error"
        case .http(_, let code, _, _): return code
        case .decoding: return "decoding_error"
        case .encoding: return "encoding_error"
        case .rateLimited: return "rate_limited"
        case .server: return "server_error"
        case .invalidConfiguration: return "invalid_configuration"
        case .notConfigured: return "not_configured"
        case .tokenRefreshFailed: return "token_refresh_failed"
        }
    }

    public var statusCode: Int? {
        switch self {
        case .http(let status, _, _, _): return status
        case .rateLimited: return 429
        case .server(let status, _): return status
        default: return nil
        }
    }

    public var requestId: String? {
        switch self {
        case .http(_, _, _, let requestId): return requestId
        default: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .http(_, _, let message, _): return message
        case .decoding(let message): return "Decoding error: \(message)"
        case .encoding(let message): return "Encoding error: \(message)"
        case .rateLimited(let retryAfter):
            return retryAfter.map { "Rate limited. Retry after \($0)s." } ?? "Rate limited."
        case .server(_, let message): return message
        case .invalidConfiguration(let message): return message
        case .notConfigured: return "Palbase SDK not configured. Call Palbase.configure(apiKey:) first."
        case .tokenRefreshFailed(let message): return message
        }
    }
}

// MARK: - HTTP error envelope (internal — used by HttpClient and module errors)

/// Represents the error JSON returned by the Palbase server.
/// Modules use this to map server errors to their own error cases.
package struct PalbaseErrorEnvelope: Sendable, Decodable {
    package let code: String
    package let message: String
    package let status: Int
    package let requestId: String?
    package let details: [String: String]?

    enum CodingKeys: String, CodingKey {
        case code = "error"
        case message = "error_description"
        case status
        case requestId = "request_id"
        case details
    }
}
