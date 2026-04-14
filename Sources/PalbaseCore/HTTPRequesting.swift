import Foundation

/// Abstraction over HTTP — production implementation is `HttpClient`, tests can mock.
package protocol HTTPRequesting: Sendable {
    /// Execute a request and decode the response as `T`.
    /// Throws `PalbaseCoreError` on transport/HTTP failures.
    /// On HTTP 4xx/5xx returns the raw response data so callers can map to module-specific errors.
    func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String]
    ) async throws -> T

    /// Execute a request that returns no body (204 / discarded).
    func requestVoid(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String]
    ) async throws

    /// Execute and return raw response data + status. Used by modules that need to map
    /// HTTP errors to their own error types via `PalbaseErrorEnvelope`.
    func requestRaw(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String]
    ) async throws -> (data: Data, status: Int)
}

extension HTTPRequesting {
    public func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        try await request(method: method, path: path, body: body, headers: headers)
    }

    public func requestVoid(
        method: String,
        path: String,
        body: (any Encodable & Sendable)? = nil,
        headers: [String: String] = [:]
    ) async throws {
        try await requestVoid(method: method, path: path, body: body, headers: headers)
    }
}
