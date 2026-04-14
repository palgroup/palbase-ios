import Foundation
@_exported import PalbaseCore

/// Errors specific to the DB module.
public enum DBError: PalbaseError {
    case notConfigured
    case invalidTable(String)
    case invalidColumn(String)
    case invalidFunctionName(String)
    case invalidTransactionId(String)
    case transactionTimeout
    case transactionFailed(String)

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
        case .invalidTable: return "invalid_table"
        case .invalidColumn: return "invalid_column"
        case .invalidFunctionName: return "invalid_function_name"
        case .invalidTransactionId: return "invalid_transaction_id"
        case .transactionTimeout: return "transaction_timeout"
        case .transactionFailed: return "transaction_failed"
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
        case .transactionTimeout: return 408
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
        case .invalidTable(let name):
            return "Invalid table name: \"\(name)\"."
        case .invalidColumn(let name):
            return "Invalid column name: \"\(name)\"."
        case .invalidFunctionName(let name):
            return "Invalid function name: \"\(name)\"."
        case .invalidTransactionId(let id):
            return "Invalid transaction id: \"\(id)\"."
        case .transactionTimeout:
            return "Transaction timed out."
        case .transactionFailed(let m): return m
        case .network(let m), .decoding(let m): return m
        case .rateLimited(let retryAfter):
            return retryAfter.map { "Rate limited. Retry after \($0)s." } ?? "Rate limited."
        case .serverError(_, let m), .http(_, _, let m, _): return m
        case .server(_, let m, _): return m
        }
    }

    /// Map transport-level core errors to module-specific cases so
    /// `PalbaseCoreError` never leaks to callers.
    static func from(transport: PalbaseCoreError) -> DBError {
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
