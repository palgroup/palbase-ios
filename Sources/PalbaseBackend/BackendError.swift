import Foundation
@_exported import PalbaseCore

/// A single field-level validation failure, surfaced from a backend
/// endpoint whose Zod `input` schema rejected the request. The backend
/// returns these as `details: [{ field, message }]` in the standard
/// error envelope; `PalbaseBackend` lifts them into `.validation` so a
/// form can map each message back to the input that produced it.
public struct FieldError: Sendable, Equatable, Decodable {
    public let field: String
    public let message: String

    package init(field: String, message: String) {
        self.field = field
        self.message = message
    }
}

/// Errors raised by the typed backend RPC client.
///
/// Every failure a `defineEndpoint` handler can produce maps onto one of
/// these cases. The cases mirror the standard Palbase error envelope
/// (`{ error, error_description, status, request_id, details }`) the
/// backend runtime returns, so a caller can `switch` on a *named* outcome
/// instead of inspecting raw status codes.
///
/// `PalbaseCoreError` never leaks through this type — transport failures
/// are mapped to `.transport` / `.network`, keeping a single error
/// surface per call (the same contract every other module follows).
public enum BackendError: PalbaseError {
    /// SDK not configured. Call `PalBackend.configure(apiKey:)` first.
    case notConfigured

    /// A `defineEndpoint` handler returned a structured error
    /// (`throw new HttpError(status, code, description)`), or the runtime
    /// produced one. `code` is the stable snake_case identifier
    /// (e.g. `room_not_found`) a caller switches on.
    case server(code: String, status: Int, message: String, requestId: String?)

    /// Input failed the endpoint's Zod schema (HTTP 400). `fields`
    /// carries the per-field messages so a form can render them inline.
    case validation(fields: [FieldError], requestId: String?)

    /// Rate limit exceeded (HTTP 429). `retryAfter` is the server's
    /// `Retry-After` in seconds when present.
    case rateLimited(retryAfter: Int?)

    /// Authentication failed or expired (HTTP 401) — surfaced only after
    /// the shared transport has already attempted a reactive refresh.
    case unauthorized(requestId: String?)

    /// App Attest is enforced for this project but the device cannot
    /// produce a valid attestation (e.g. running in the Simulator, or on
    /// hardware without a Secure Enclave). The request was not sent.
    case attestationUnavailable(reason: String)

    /// Network-level failure (no response, connection lost, timeout).
    case network(message: String)

    /// Any other transport-level failure.
    case transport(message: String)

    /// Response body could not be decoded into the expected output type.
    case decode(message: String)

    /// Request body could not be encoded.
    case encode(message: String)

    public var code: String {
        switch self {
        case .notConfigured: return "not_configured"
        case .server(let code, _, _, _): return code
        case .validation: return "validation_error"
        case .rateLimited: return "rate_limited"
        case .unauthorized: return "unauthorized"
        case .attestationUnavailable: return "attestation_unavailable"
        case .network: return "network_error"
        case .transport: return "transport_error"
        case .decode: return "decoding_error"
        case .encode: return "encoding_error"
        }
    }

    public var statusCode: Int? {
        switch self {
        case .server(_, let status, _, _): return status
        case .validation: return 400
        case .rateLimited: return 429
        case .unauthorized: return 401
        default: return nil
        }
    }

    public var requestId: String? {
        switch self {
        case .server(_, _, _, let rid),
             .validation(_, let rid),
             .unauthorized(let rid):
            return rid
        default: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "PalBackend not configured. Call PalBackend.configure(apiKey:) first."
        case .server(_, _, let message, _):
            return message
        case .validation(let fields, _):
            if fields.isEmpty { return "Input validation failed." }
            return "Input validation failed: " + fields.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
        case .rateLimited(let retryAfter):
            return retryAfter.map { "Rate limited. Retry after \($0)s." } ?? "Rate limited."
        case .unauthorized:
            return "Unauthorized."
        case .attestationUnavailable(let reason):
            return "App Attest unavailable: \(reason)"
        case .network(let message):
            return message
        case .transport(let message):
            return message
        case .decode(let message):
            return "Decoding error: \(message)"
        case .encode(let message):
            return "Encoding error: \(message)"
        }
    }
}

// MARK: - Envelope decoding

/// The standard Palbase error envelope as the *backend runtime* emits it.
///
/// Distinct from `PalbaseCore.PalbaseErrorEnvelope` because the backend's
/// `details` is an **array of `{ field, message }`** (Zod field errors),
/// whereas Core models `details` as `[String: String]`. Decoding the
/// backend shape here is what lets `BackendError.validation` carry real
/// field errors. Kept `internal` to the module.
/// Decoded with `JSONDecoder.palbaseDefault`, which applies
/// `.convertFromSnakeCase` — so `error_description` and `request_id`
/// arrive as `errorDescription` / `requestId` automatically. Declaring
/// explicit snake_case `CodingKeys` here would fight that converter and
/// silently drop the fields, so the property names are left to match the
/// converted keys.
struct BackendErrorEnvelope: Decodable {
    let error: String
    let errorDescription: String?
    let status: Int?
    let requestId: String?
    let details: [FieldError]?
}

extension BackendError {
    /// Map a non-2xx response (raw body + status) to a typed `BackendError`,
    /// decoding the standard envelope when present.
    static func from(status: Int, body: Data, retryAfter: Int?) -> BackendError {
        let envelope = try? JSONDecoder.palbaseDefault.decode(BackendErrorEnvelope.self, from: body)
        let code = envelope?.error ?? "unknown_error"
        let message = envelope?.errorDescription ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let requestId = envelope?.requestId

        switch status {
        case 400 where envelope?.details?.isEmpty == false || code == "validation_error":
            return .validation(fields: envelope?.details ?? [], requestId: requestId)
        case 401:
            return .unauthorized(requestId: requestId)
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .server(code: code, status: status, message: message, requestId: requestId)
        }
    }

    /// Map a transport-level `PalbaseCoreError` (thrown when the raw body
    /// is no longer available) to a typed `BackendError`. Used as the
    /// fallback path; the envelope-aware `from(status:body:)` is preferred
    /// when the body is in hand.
    static func from(transport err: PalbaseCoreError) -> BackendError {
        switch err {
        case .http(let status, let code, let message, let requestId):
            switch status {
            case 400: return .validation(fields: [], requestId: requestId)
            case 401: return .unauthorized(requestId: requestId)
            default: return .server(code: code, status: status, message: message, requestId: requestId)
            }
        case .server(let status, let message):
            return .server(code: "server_error", status: status, message: message, requestId: nil)
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .decoding(let m):
            return .decode(message: m)
        case .encoding(let m):
            return .encode(message: m)
        case .network(let m):
            return .network(message: m)
        case .invalidConfiguration(let m), .tokenRefreshFailed(let m):
            return .transport(message: m)
        case .notConfigured:
            return .notConfigured
        }
    }
}
