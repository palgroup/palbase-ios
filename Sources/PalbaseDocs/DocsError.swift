import Foundation
@_exported import PalbaseCore

/// Errors specific to the Docs module.
public enum DocsError: PalbaseError {
    case notConfigured
    case invalidPath(String)
    case invalidFieldName(String)
    case batchTooLarge(max: Int)
    case transformsTooLarge(max: Int)
    case documentNotFound(path: String)
    case transactionTimeout
    case transactionFailed(String)
    case streamingUnsupported

    // Transport-level (mapped from PalbaseCoreError)
    case network(String)
    case encoding(String)
    case decoding(String)
    case rateLimited(retryAfter: Int?)
    case serverError(status: Int, message: String)
    case http(status: Int, code: String, message: String, requestId: String?)
    case server(code: String, message: String, requestId: String?)

    public var code: String {
        switch self {
        case .notConfigured: return "not_configured"
        case .invalidPath: return "invalid_path"
        case .invalidFieldName: return "invalid_field_name"
        case .batchTooLarge: return "batch_too_large"
        case .transformsTooLarge: return "transforms_too_large"
        case .documentNotFound: return "document_not_found"
        case .transactionTimeout: return "transaction_timeout"
        case .transactionFailed: return "transaction_failed"
        case .streamingUnsupported: return "streaming_unsupported"
        case .network: return "network_error"
        case .encoding: return "encoding_error"
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
        case .transactionTimeout: return 408
        case .documentNotFound: return 404
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
        case .invalidPath(let p):
            return "Invalid document or collection path: \"\(p)\"."
        case .invalidFieldName(let f):
            return "Invalid field name: \"\(f)\"."
        case .batchTooLarge(let max):
            return "Batch exceeds maximum of \(max) operations."
        case .transformsTooLarge(let max):
            return "Transforms exceed maximum of \(max) per request."
        case .documentNotFound(let path):
            return "Document not found: \"\(path)\"."
        case .transactionTimeout:
            return "Transaction timed out."
        case .transactionFailed(let m): return m
        case .streamingUnsupported:
            return "Server-sent events stream is not available on this platform."
        case .network(let m), .encoding(let m), .decoding(let m): return m
        case .rateLimited(let retryAfter):
            return retryAfter.map { "Rate limited. Retry after \($0)s." } ?? "Rate limited."
        case .serverError(_, let m), .http(_, _, let m, _): return m
        case .server(_, let m, _): return m
        }
    }

    /// Map transport-level core errors to module-specific cases so
    /// `PalbaseCoreError` never leaks to callers.
    static func from(transport: PalbaseCoreError) -> DocsError {
        switch transport {
        case .network(let m): return .network(m)
        case .decoding(let m): return .decoding(m)
        case .encoding(let m): return .encoding(m)
        case .rateLimited(let r): return .rateLimited(retryAfter: r)
        case .server(let s, let m): return .serverError(status: s, message: m)
        case .http(let s, let c, let m, let id):
            if s == 404 {
                return .documentNotFound(path: m)
            }
            return .http(status: s, code: c, message: m, requestId: id)
        case .invalidConfiguration(let m): return .network(m)
        case .notConfigured: return .notConfigured
        case .tokenRefreshFailed(let m): return .network(m)
        }
    }
}
