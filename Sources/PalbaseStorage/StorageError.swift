import Foundation
@_exported import PalbaseCore

/// Errors specific to the Storage module.
public enum StorageError: PalbaseError {
    case notConfigured
    case invalidBucketName(String)
    case invalidPath(String)
    case fileNotFound(path: String)
    case bucketNotFound(name: String)
    case quotaExceeded(message: String)
    case fileTooLarge(maxBytes: Int)
    case invalidContentType(message: String)
    case uploadFailed(message: String)
    case uploadCancelled

    // Transport-level (mapped from PalbaseCoreError)
    case network(String)
    case decoding(String)
    case rateLimited(retryAfter: Int?)
    case serverError(status: Int, message: String)
    case http(status: Int, code: String, message: String, requestId: String?)
    case server(code: String, message: String, requestId: String?)

    public var code: String {
        switch self {
        case .notConfigured: return "not_configured"
        case .invalidBucketName: return "invalid_bucket_name"
        case .invalidPath: return "invalid_path"
        case .fileNotFound: return "file_not_found"
        case .bucketNotFound: return "bucket_not_found"
        case .quotaExceeded: return "quota_exceeded"
        case .fileTooLarge: return "file_too_large"
        case .invalidContentType: return "invalid_content_type"
        case .uploadFailed: return "upload_failed"
        case .uploadCancelled: return "upload_cancelled"
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
        case .fileNotFound, .bucketNotFound: return 404
        case .fileTooLarge: return 413
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
        case .invalidBucketName(let n):
            return "Invalid bucket name: \"\(n)\". Allowed: [a-zA-Z0-9_-]."
        case .invalidPath(let p):
            return "Invalid object path: \"\(p)\"."
        case .fileNotFound(let p):
            return "File not found at path: \"\(p)\"."
        case .bucketNotFound(let n):
            return "Bucket not found: \"\(n)\"."
        case .quotaExceeded(let m): return m
        case .fileTooLarge(let max):
            return "File exceeds maximum size of \(max) bytes."
        case .invalidContentType(let m): return m
        case .uploadFailed(let m): return m
        case .uploadCancelled: return "Upload was cancelled."
        case .network(let m), .decoding(let m): return m
        case .rateLimited(let retryAfter):
            return retryAfter.map { "Rate limited. Retry after \($0)s." } ?? "Rate limited."
        case .serverError(_, let m), .http(_, _, let m, _): return m
        case .server(_, let m, _): return m
        }
    }

    /// Map transport-level core errors to module-specific cases so
    /// `PalbaseCoreError` never leaks to callers.
    static func from(transport: PalbaseCoreError) -> StorageError {
        switch transport {
        case .network(let m): return .network(m)
        case .decoding(let m): return .decoding(m)
        case .encoding(let m): return .network(m)
        case .rateLimited(let r): return .rateLimited(retryAfter: r)
        case .server(let s, let m): return .serverError(status: s, message: m)
        case .http(let s, let c, let m, let id):
            if s == 404 {
                // Message usually contains key/path; preserve it.
                if c == "NoSuchBucket" || c.lowercased().contains("bucket") {
                    return .bucketNotFound(name: m)
                }
                return .fileNotFound(path: m)
            }
            if s == 413 {
                return .fileTooLarge(maxBytes: 0)
            }
            if c == "quota_exceeded" || c == "Payload too large" {
                return .quotaExceeded(message: m)
            }
            return .http(status: s, code: c, message: m, requestId: id)
        case .invalidConfiguration(let m): return .network(m)
        case .notConfigured: return .notConfigured
        case .tokenRefreshFailed(let m): return .network(m)
        }
    }
}
