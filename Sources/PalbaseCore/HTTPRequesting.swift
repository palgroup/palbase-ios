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
}
