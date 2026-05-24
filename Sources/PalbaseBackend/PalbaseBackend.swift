import Foundation
@_exported import PalbaseCore

/// Typed RPC client for the user's deployed `defineEndpoint` handlers.
/// Issues `POST /rpc/{name}` against the configured backend URL.
///
/// Routing:
///   * default — same per-tenant gateway as auth/db/docs
///   * `PalBackend.configure(apiKey:backendURL:)` — overrides only backend
///     RPC (e.g. `http://localhost:4003` for `palbase backend dev`)
///
/// Like every other module, PalbaseBackend rides on top of
/// `HTTPRequesting` so it inherits the SDK's auth header injection,
/// pre-flight token refresh, retry-on-429, reactive 401 replay, and
/// interceptors. On top of that it adds, for the backend specifically:
///
///   * typed, named errors decoded from the standard error envelope
///     (incl. Zod field errors) — see `BackendError`
///   * an `Idempotency-Key` on mutating calls so a retried POST is not
///     applied twice
///   * optional App Attest assertion headers when the project enforces it
public struct PalbaseBackend: Sendable {
    let http: HTTPRequesting
    let tokens: TokenManager
    let attestor: AppAttesting?

    package init(http: HTTPRequesting, tokens: TokenManager, attestor: AppAttesting? = nil) {
        self.http = http
        self.tokens = tokens
        self.attestor = attestor
    }

    /// Shared backend client backed by the global SDK configuration.
    /// Throws `BackendError.notConfigured` if the SDK has not been
    /// configured.
    public static var shared: PalbaseBackend {
        get throws(BackendError) {
            guard let http = Palbase.backendHttp, let tokens = Palbase.tokens else {
                throw BackendError.notConfigured
            }
            return PalbaseBackend(http: http, tokens: tokens, attestor: Palbase.attestor)
        }
    }

    /// Invoke a backend endpoint by name with a typed input and output.
    /// Wire convention is `POST /rpc/{name}` with the input JSON-encoded
    /// as the request body.
    ///
    /// ```swift
    /// struct CheckoutRequest: Encodable, Sendable { let items: [String] }
    /// struct CheckoutResponse: Decodable, Sendable { let orderId: String }
    /// let r: CheckoutResponse = try await PalbaseBackend.shared.call(
    ///     "checkout",
    ///     CheckoutRequest(items: ["a", "b"])
    /// )
    /// ```
    ///
    /// - On a non-2xx response the full error envelope is decoded into a
    ///   typed `BackendError` (`.server`, `.validation`, `.rateLimited`,
    ///   `.unauthorized`) — including Zod field errors for 400s.
    @discardableResult
    public func call<I: Encodable & Sendable, O: Decodable & Sendable>(
        _ name: String,
        _ input: I,
        as: O.Type = O.self,
        headers: [String: String] = [:]
    ) async throws(BackendError) -> O {
        let data = try await invokeRPC(method: "POST", name: name, body: input, extraHeaders: headers)
        do {
            return try JSONDecoder.palbaseDefault.decode(O.self, from: data)
        } catch {
            throw BackendError.decode(message: error.localizedDescription)
        }
    }

    /// Invoke an endpoint that takes no input. Convenience over `call`.
    @discardableResult
    public func call<O: Decodable & Sendable>(
        _ name: String,
        as: O.Type = O.self,
        headers: [String: String] = [:]
    ) async throws(BackendError) -> O {
        try await call(name, EmptyInput(), as: O.self, headers: headers)
    }

    /// Issue the RPC and return the raw success body. Shared by the typed
    /// `call` overloads and by generated code. Owns: idempotency key,
    /// App Attest headers, envelope error mapping.
    ///
    /// The body is encoded to bytes here (once) so the App Attest
    /// assertion can bind to the exact payload that goes on the wire, and
    /// so the same bytes are sent without a second encode.
    func invokeRPC(
        method: String,
        name: String,
        body: (any Encodable & Sendable)?,
        extraHeaders: [String: String]
    ) async throws(BackendError) -> Data {
        let path = "/rpc/\(name)"

        // Encode once. nil body → no body bytes (GET, no-input calls).
        let bodyData: Data?
        if let body {
            do {
                bodyData = try JSONEncoder.palbaseDefault.encode(RawEncodable(body))
            } catch {
                throw BackendError.encode(message: error.localizedDescription)
            }
        } else {
            bodyData = nil
        }

        var headers = extraHeaders
        headers["Content-Type"] = "application/json"

        // Idempotency: a single key per logical call, reused across the
        // transport's internal retries so a dropped-then-retried mutation
        // is de-duplicated server-side. GET is naturally idempotent.
        if method != "GET", headers["Idempotency-Key"] == nil {
            headers["Idempotency-Key"] = Self.newIdempotencyKey()
        }

        // App Attest: when the project enforces it, attach an assertion
        // bound to this request (incl. the payload hash). attestor is nil
        // when the flag is off — nothing is attached, nothing is computed.
        if let attestor {
            do {
                let attestHeaders = try await attestor.assertionHeaders(method: method, path: path, body: bodyData)
                for (k, v) in attestHeaders { headers[k] = v }
            } catch let err as BackendError {
                throw err
            } catch {
                throw BackendError.attestationUnavailable(reason: error.localizedDescription)
            }
        }

        let result: (data: Data, status: Int, headers: [String: String])
        do {
            result = try await http.requestRawBodyResult(
                method: method,
                path: path,
                body: bodyData,
                headers: headers
            )
        } catch {
            // requestRawBodyResult is `throws(PalbaseCoreError)`.
            throw BackendError.from(transport: error)
        }

        guard (200..<300).contains(result.status) else {
            let retryAfter = result.headers["Retry-After"].flatMap { Int($0) }
            throw BackendError.from(status: result.status, body: result.data, retryAfter: retryAfter)
        }
        return result.data
    }

    /// Fetch the `/openapi.json` document for the configured project.
    /// Convenience for Studio-style introspection and for the codegen
    /// tool's remote fetch.
    public func openAPISpec() async throws(BackendError) -> Data {
        let result: (data: Data, status: Int, headers: [String: String])
        do {
            result = try await http.requestRawBodyResult(
                method: "GET",
                path: "/openapi.json",
                body: Data?.none,
                headers: [:]
            )
        } catch {
            throw BackendError.from(transport: error)
        }
        guard (200..<300).contains(result.status) else {
            let retryAfter = result.headers["Retry-After"].flatMap { Int($0) }
            throw BackendError.from(status: result.status, body: result.data, retryAfter: retryAfter)
        }
        return result.data
    }

    /// A fresh idempotency key. UUIDv7-style: time-ordered prefix so keys
    /// sort by creation, with a random tail. Foundation only.
    static func newIdempotencyKey() -> String {
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        // 48-bit big-endian timestamp, hex-encoded (12 chars).
        var tsHex = ""
        for shift in stride(from: 40, through: 0, by: -8) {
            tsHex += String(format: "%02x", UInt8((millis >> UInt64(shift)) & 0xFF))
        }
        let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "idmp_\(tsHex)\(random.prefix(20))"
    }
}

/// Sentinel for endpoints that accept no input.
struct EmptyInput: Encodable, Sendable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

/// Erases a concrete `Encodable` so an existential `any Encodable` can be
/// handed to `JSONEncoder` (which requires a concrete generic type).
struct RawEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) {
        self.encodeFn = wrapped.encode
    }
    func encode(to encoder: Encoder) throws {
        try encodeFn(encoder)
    }
}
