import Foundation

/// Abstraction over HTTP — production implementation is `HttpClient`, tests can mock.
/// All methods throw `PalbaseCoreError` for transport/HTTP failures.
package protocol HTTPRequesting: Sendable {
    /// Execute and decode response.
    func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String]
    ) async throws(PalbaseCoreError) -> T

    /// Execute, ignore body.
    func requestVoid(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String]
    ) async throws(PalbaseCoreError)

    /// Execute and return raw data + status. Used when caller wants to map server
    /// envelope to a module-specific error.
    func requestRaw(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String]
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int)

    /// Execute with a raw `Data` body (multipart, binary, TUS chunks) and return raw
    /// response data + status + headers. Skips JSON encoding; caller sets `Content-Type`
    /// via `headers`. Non-2xx responses throw; 206 is treated as success.
    func requestRawBody(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String]
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int, headers: [String: String])

    /// Execute with a raw `Data` body and return the response **without
    /// throwing on non-2xx**.
    ///
    /// Runs the full pipeline (pre-flight refresh, 429 backoff, reactive
    /// 401 replay, transport retry), but instead of mapping a terminal
    /// non-2xx response to a `PalbaseCoreError`, it hands the raw body,
    /// status, and headers back to the caller. This lets a module decode
    /// the *complete* error envelope itself (including `details[]` and
    /// `Retry-After`) and produce a richer module-specific error than the
    /// lossy `PalbaseCoreError.http` mapping allows.
    ///
    /// The caller is responsible for JSON-encoding and for setting
    /// `Content-Type` via `headers`. Still throws `PalbaseCoreError` for
    /// genuine transport failures (no response, connection lost) and for
    /// cancellation — those have no HTTP response to return.
    func requestRawBodyResult(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String]
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int, headers: [String: String])

    /// Upload a raw body and report send progress, returning the response
    /// **without throwing on non-2xx** (like `requestRawBodyResult`).
    ///
    /// Backed by `URLSession.upload(for:from:delegate:)` so the caller
    /// gets per-chunk byte counts via `onProgress`. No automatic retry —
    /// an interrupted upload should be restarted by the caller (and a
    /// retried upload is de-duplicated by the idempotency key the backend
    /// attaches). Auth headers, anon key, and the base URL are applied by
    /// the transport, exactly as for a normal request.
    func uploadRawBodyResult(
        method: String,
        path: String,
        body: Data,
        headers: [String: String],
        onProgress: (@Sendable (_ sent: Int64, _ total: Int64) -> Void)?
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int, headers: [String: String])
}

extension HTTPRequesting {
    package func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)? = nil,
        headers: [String: String] = [:]
    ) async throws(PalbaseCoreError) -> T {
        try await request(method: method, path: path, body: body, headers: headers)
    }

    package func requestVoid(
        method: String,
        path: String,
        body: (any Encodable & Sendable)? = nil,
        headers: [String: String] = [:]
    ) async throws(PalbaseCoreError) {
        try await requestVoid(method: method, path: path, body: body, headers: headers)
    }

    /// Default stub so existing mocks needn't implement it. Real transport
    /// (`HttpClient`) overrides with a working implementation.
    package func requestRawBody(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String]
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int, headers: [String: String]) {
        throw PalbaseCoreError.invalidConfiguration(
            message: "requestRawBody not implemented by this HTTPRequesting."
        )
    }

    /// Default bridge so existing mocks needn't implement
    /// `requestRawBodyResult`. Delegates to `requestRawBody`: a 2xx is
    /// returned as-is; a non-2xx still throws (the default cannot recover
    /// the body once `requestRawBody` has mapped it to an error). Real
    /// transport (`HttpClient`) overrides with a non-throwing
    /// implementation that preserves the full error body and `Retry-After`.
    package func requestRawBodyResult(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String]
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int, headers: [String: String]) {
        try await requestRawBody(method: method, path: path, body: body, headers: headers)
    }

    /// Default bridge: ignore progress and fall back to
    /// `requestRawBodyResult`. Real transport (`HttpClient`) overrides
    /// with a delegate-backed upload that reports byte progress.
    package func uploadRawBodyResult(
        method: String,
        path: String,
        body: Data,
        headers: [String: String],
        onProgress: (@Sendable (_ sent: Int64, _ total: Int64) -> Void)?
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int, headers: [String: String]) {
        try await requestRawBodyResult(method: method, path: path, body: body, headers: headers)
    }
}
