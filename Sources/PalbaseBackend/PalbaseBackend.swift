import Foundation
@_exported import PalbaseCore

/// Errors specific to the typed backend RPC client.
public enum BackendError: Error, Sendable {
    case notConfigured
    case invalidEnvironment(String)
    case localServerNotFound(String)
    case http(status: Int, body: Data)
    case decode(Error)
    case encode(Error)
    case transport(Error)
}

/// Typed RPC client for the user's deployed `defineEndpoint` handlers.
/// Issues `POST /rpc/{name}` against either the configured Kong gateway
/// (`environment = .remote`, default) or a developer-set local
/// `palbase backend dev` server (`.custom(URL)` / `.autoDiscover`).
///
/// Adım B14 — typed RPC + local auto-discovery.
public actor PalbaseBackend {
    private let apiKey: String
    private let endpointRef: String
    private let tokens: TokenManager?
    private let urlSession: URLSession
    private let requestTimeout: TimeInterval

    private var environment: BackendEnvironment = .remote
    private var cachedAutoDiscoveredURL: URL?

    package init(
        apiKey: String,
        endpointRef: String,
        tokens: TokenManager? = nil,
        urlSession: URLSession = .shared,
        requestTimeout: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.endpointRef = endpointRef
        self.tokens = tokens
        self.urlSession = urlSession
        self.requestTimeout = requestTimeout
    }

    /// Shared backend client backed by the global SDK configuration.
    /// Throws `BackendError.notConfigured` if `Palbase.configure(apiKey:)`
    /// has not been called.
    public static var shared: PalbaseBackend {
        get throws(BackendError) {
            guard let apiKey = Palbase.apiKey else { throw BackendError.notConfigured }
            let endpointRef = Palbase.endpointRef ?? PalbaseBackend.parseEndpointRef(from: apiKey)
            return PalbaseBackend(apiKey: apiKey, endpointRef: endpointRef, tokens: Palbase.tokens)
        }
    }

    // MARK: - Environment switching

    /// Switch the backend connection target. New `call(_:_:as:)`
    /// invocations route to the new environment immediately;
    /// in-flight calls finish against their original URL.
    public func setEnvironment(_ env: BackendEnvironment) {
        environment = env
        cachedAutoDiscoveredURL = nil
    }

    /// Read the current environment.
    public func currentEnvironment() -> BackendEnvironment {
        environment
    }

    // MARK: - Typed RPC

    /// Invoke a backend endpoint by name. The wire convention is
    /// `POST /rpc/{name}` with the `input` JSON-encoded as the request
    /// body. Authorization is the configured Palbase apikey.
    ///
    /// ```swift
    /// struct CheckoutRequest: Encodable { let items: [String] }
    /// struct CheckoutResponse: Decodable { let orderId: String }
    /// let r: CheckoutResponse = try await Palbase.shared.backend.call(
    ///     "checkout",
    ///     CheckoutRequest(items: ["a", "b"])
    /// )
    /// ```
    public func call<I: Encodable & Sendable, O: Decodable & Sendable>(
        _ name: String,
        _ input: I,
        as: O.Type = O.self,
        headers: [String: String] = [:]
    ) async throws -> O {
        let baseURL = try await resolveBaseURL()
        let url = baseURL.appendingPathComponent("rpc").appendingPathComponent(name)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        // Only attach Authorization when a real user session exists.
        // Sending the apikey itself as Bearer would be parsed by the
        // backend-runtime auth pipeline as a JWT to verify and 401.
        // When signed out, the apikey header alone is enough for Kong
        // to gate the request and `auth.required: false` endpoints.
        if let userBearer = await currentUserBearer() {
            request.setValue("Bearer \(userBearer)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        do {
            request.httpBody = try JSONEncoder().encode(input)
        } catch {
            throw BackendError.encode(error)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw BackendError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(status: http.statusCode, body: data)
        }

        do {
            return try JSONDecoder().decode(O.self, from: data)
        } catch {
            throw BackendError.decode(error)
        }
    }

    /// Fetch the `/openapi.json` document for the configured project.
    /// Convenience for Studio-style introspection inside the iOS app.
    public func openAPISpec() async throws -> Data {
        let baseURL = try await resolveBaseURL()
        let url = baseURL.appendingPathComponent("openapi.json")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let userBearer = await currentUserBearer() {
            request.setValue("Bearer \(userBearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await urlSession.data(for: request) }
        catch { throw BackendError.transport(error) }
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(status: http.statusCode, body: data)
        }
        return data
    }

    // MARK: - Internals

    // When a user session is active, return their access token so the
    // backend-runtime auth pipeline can resolve `ctx.user`. Returns nil
    // when signed out — caller should skip the Authorization header
    // entirely in that case (sending the apikey as Bearer would be
    // parsed as an invalid JWT and 401).
    private func currentUserBearer() async -> String? {
        guard let tokens else { return nil }
        return await tokens.accessToken
    }

    /// Resolve the environment to a concrete base URL. Auto-discover
    /// caches the resolved URL for the session; `.custom` returns
    /// directly; `.remote` builds the per-tenant gateway URL.
    private func resolveBaseURL() async throws -> URL {
        switch environment {
        case .remote:
            return try remoteBaseURL()
        case .custom(let url):
            return url
        #if DEBUG
        case .autoDiscover(let fallback):
            if let cached = cachedAutoDiscoveredURL {
                return cached
            }
            if let discovered = await BonjourDiscovery.discover(expectedRef: endpointRef) {
                cachedAutoDiscoveredURL = discovered
                return discovered
            }
            switch fallback {
            case .remote: return try remoteBaseURL()
            case .custom(let url): return url
            }
        #endif
        }
    }

    private func remoteBaseURL() throws -> URL {
        // Mirrors HttpClient's tenant-host derivation: `https://<ref>.<domain>`.
        let domain = Palbase.host ?? "palbase.studio"
        guard let url = URL(string: "https://\(endpointRef).\(domain)") else {
            throw BackendError.invalidEnvironment("could not build remote URL for ref=\(endpointRef)")
        }
        return url
    }

    /// Best-effort: extract the project ref from an apikey of the form
    /// `pb_<ref>_c<random>` or `pb_<ref>_s<random>`. Returns the apikey
    /// itself on parse failure so a malformed key surfaces as an HTTP
    /// error rather than a silent ref mismatch.
    private static func parseEndpointRef(from apiKey: String) -> String {
        let parts = apiKey.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return apiKey }
        return String(parts[1])
    }
}
