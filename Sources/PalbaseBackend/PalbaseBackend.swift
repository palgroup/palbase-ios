import Foundation
@_exported import PalbaseCore

/// Errors specific to the typed backend RPC client.
public enum BackendError: Error, Sendable {
    case notConfigured
    case http(status: Int, body: Data)
    case decode(Error)
    case encode(Error)
    case transport(String)
}

/// Typed RPC client for the user's deployed `defineEndpoint` handlers.
/// Issues `POST /rpc/{name}` against the configured backend URL.
///
/// Routing:
///   * default — same per-tenant gateway as auth/db/docs
///   * `Palbase.configure(apiKey:mode:backendURL:)` — overrides only
///     backend RPC (e.g. `http://localhost:4000` for `palbase backend dev`)
///
/// Like every other module, PalbaseBackend rides on top of
/// `HTTPRequesting` so it inherits the SDK's auth header injection,
/// pre-flight token refresh, retry-on-429, and interceptors.
public struct PalbaseBackend: Sendable {
    let http: HTTPRequesting
    let tokens: TokenManager

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared backend client backed by the global SDK configuration.
    /// Throws `BackendError.notConfigured` if `Palbase.configure(apiKey:)`
    /// has not been called.
    public static var shared: PalbaseBackend {
        get throws(BackendError) {
            guard let http = Palbase.backendHttp, let tokens = Palbase.tokens else {
                throw BackendError.notConfigured
            }
            return PalbaseBackend(http: http, tokens: tokens)
        }
    }

    /// Invoke a backend endpoint by name. Wire convention is
    /// `POST /rpc/{name}` with the input JSON-encoded as the request
    /// body. Authorization headers are taken care of by the underlying
    /// HttpClient.
    ///
    /// ```swift
    /// struct CheckoutRequest: Encodable, Sendable { let items: [String] }
    /// struct CheckoutResponse: Decodable, Sendable { let orderId: String }
    /// let r: CheckoutResponse = try await PalbaseBackend.shared.call(
    ///     "checkout",
    ///     CheckoutRequest(items: ["a", "b"])
    /// )
    /// ```
    public func call<I: Encodable & Sendable, O: Decodable & Sendable>(
        _ name: String,
        _ input: I,
        as: O.Type = O.self,
        headers: [String: String] = [:]
    ) async throws(BackendError) -> O {
        let raw: (data: Data, status: Int)
        do {
            raw = try await http.requestRaw(
                method: "POST",
                path: "/rpc/\(name)",
                body: input,
                headers: headers
            )
        } catch let err as PalbaseCoreError {
            throw Self.map(err)
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(O.self, from: raw.data)
        } catch {
            throw BackendError.decode(error)
        }
    }

    /// Fetch the `/openapi.json` document for the configured project.
    /// Convenience for Studio-style introspection inside the iOS app.
    public func openAPISpec() async throws(BackendError) -> Data {
        let raw: (data: Data, status: Int)
        do {
            raw = try await http.requestRaw(
                method: "GET",
                path: "/openapi.json",
                body: nil,
                headers: [:]
            )
        } catch let err as PalbaseCoreError {
            throw Self.map(err)
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }
        return raw.data
    }

    private static func map(_ err: PalbaseCoreError) -> BackendError {
        switch err {
        case .http(let status, _, _, _):
            return .http(status: status, body: Data())
        case .server(let status, let message):
            return .http(status: status, body: Data(message.utf8))
        case .decoding(let m): return .decode(NSError(domain: "decode", code: 0, userInfo: [NSLocalizedDescriptionKey: m]))
        case .encoding(let m): return .encode(NSError(domain: "encode", code: 0, userInfo: [NSLocalizedDescriptionKey: m]))
        case .network(let m), .invalidConfiguration(let m), .tokenRefreshFailed(let m):
            return .transport(m)
        case .rateLimited(let r):
            return .http(status: 429, body: Data("retry after \(r ?? 0)s".utf8))
        case .notConfigured:
            return .notConfigured
        }
    }
}
