import Foundation

/// Default HTTP client implementation backed by URLSession.
package actor HttpClient: HTTPRequesting {
    private let config: PalbaseConfig
    private let tokens: TokenManager
    private var interceptors: [RequestInterceptor] = []

    package init(config: PalbaseConfig, tokens: TokenManager) {
        self.config = config
        self.tokens = tokens
    }

    package func addInterceptor(_ interceptor: RequestInterceptor) {
        interceptors.append(interceptor)
    }

    package func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String]
    ) async throws(PalbaseCoreError) -> T {
        let (data, _) = try await requestRaw(method: method, path: path, body: body, headers: headers)

        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }

        do {
            return try JSONDecoder.palbaseDefault.decode(T.self, from: data)
        } catch {
            throw PalbaseCoreError.decoding(message: error.localizedDescription)
        }
    }

    package func requestVoid(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String]
    ) async throws(PalbaseCoreError) {
        _ = try await requestRaw(method: method, path: path, body: body, headers: headers)
    }

    package func requestRaw(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String]
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int) {
        await preflightRefresh(path: path)

        do {
            return try await executeWithRetry(method: method, path: path, body: body, extraHeaders: headers, attempt: 0)
        } catch let err as PalbaseCoreError {
            // Reactive refresh: if the server rejected our access token
            // mid-call, try once to renew and replay. If renewal itself
            // is fatal, TokenManager has already cleared and the host
            // app will see sessionCleared(.refreshFailed); we surface
            // the original 401 so the caller's error path is consistent.
            if await shouldAttemptReactiveRefresh(err: err, path: path) {
                let renewed = (try? await tokens.refreshSession()) != nil
                if renewed {
                    return try await executeWithRetry(method: method, path: path, body: body, extraHeaders: headers, attempt: 0)
                }
            }
            throw err
        }
    }

    package func requestRawBody(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String]
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int, headers: [String: String]) {
        await preflightRefresh(path: path)

        let url: URL
        do {
            url = try getBaseURL().appendingPathComponent(path)
        } catch {
            throw error
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = config.requestTimeout
        if let body { request.httpBody = body }

        var merged = await buildHeaders(extra: headers, path: path)
        // Caller-provided Content-Type wins; strip the default JSON one unless caller set it.
        if headers["Content-Type"] == nil && headers["content-type"] == nil {
            merged.removeValue(forKey: "Content-Type")
        }
        for (k, v) in merged { request.setValue(v, forHTTPHeaderField: k) }

        for interceptor in interceptors {
            do {
                try await interceptor.intercept(&request)
            } catch let err as PalbaseCoreError {
                throw err
            } catch {
                throw PalbaseCoreError.network(message: "Interceptor failed: \(error.localizedDescription)")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await config.urlSession.data(for: request)
        } catch {
            throw PalbaseCoreError.network(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PalbaseCoreError.network(message: "Invalid response (not HTTP).")
        }

        var respHeaders: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String {
                respHeaders[ks] = vs
            }
        }

        if !(200..<300).contains(http.statusCode) {
            throw mapHTTPError(status: http.statusCode, data: data)
        }
        return (data, http.statusCode, respHeaders)
    }

    // MARK: - Internal

    nonisolated static func parseProjectRef(from apiKey: String) -> String? {
        let parts = apiKey.split(separator: "_")
        guard parts.count >= 3, parts[0] == "pb" else { return nil }
        return String(parts[1])
    }

    // MARK: - Private

    private func getBaseURL() throws(PalbaseCoreError) -> URL {
        if let urlString = config.url, let url = URL(string: urlString) {
            return url
        }

        guard let ref = Self.parseProjectRef(from: config.apiKey) else {
            throw PalbaseCoreError.invalidConfiguration(
                message: "Invalid API key format. Expected: pb_{ref}_{random}. Provide an explicit url for custom endpoints."
            )
        }

        guard let url = URL(string: "https://\(ref).\(config.mode.domain)") else {
            throw PalbaseCoreError.invalidConfiguration(message: "Could not construct base URL from API key.")
        }
        return url
    }

    private func buildHeaders(extra: [String: String], path: String) async -> [String: String] {
        var headers: [String: String] = [
            "apikey": config.apiKey,
            "Content-Type": "application/json"
        ]

        // Unauthenticated endpoints must never carry a stale Bearer.
        // The login form, signup, password reset and refresh itself
        // are all entry points the user can hit when the cached
        // access_token is already revoked — attaching it would let a
        // dead token poison a fresh credential exchange.
        let attachAuth = !Self.isUnauthenticatedPath(path)

        if attachAuth, let token = await tokens.accessToken {
            headers["Authorization"] = "Bearer \(token)"
        }

        if attachAuth, let serviceRole = config.serviceRoleKey {
            headers["Authorization"] = "Bearer \(serviceRole)"
        }

        for (k, v) in config.headers { headers[k] = v }
        for (k, v) in extra { headers[k] = v }
        return headers
    }

    /// Paths that establish or rotate credentials. They never carry an
    /// `Authorization: Bearer <stale>` header from the cached session.
    nonisolated static func isUnauthenticatedPath(_ path: String) -> Bool {
        let unauthed: [String] = [
            "/auth/login",
            "/auth/signup",
            "/auth/token/refresh",
            "/auth/password/reset",
            "/auth/password/reset/confirm",
            "/auth/magic-link",
            "/auth/magic-link/verify",
            "/auth/verify-email",
            "/auth/resend-verification",
            "/auth/oauth/credential",
        ]
        for prefix in unauthed where path.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// Block until boot finished, then opportunistically renew an
    /// already-expired access token before the request goes out. The
    /// refresh endpoint itself is excluded — it would recurse, and so
    /// is anything in the unauthenticated allowlist (no point renewing
    /// for a request that won't carry a Bearer anyway).
    private func preflightRefresh(path: String) async {
        guard !Self.isUnauthenticatedPath(path) else { return }
        await tokens.waitUntilReady()
        guard await tokens.isExpired,
              await tokens.refreshFunction != nil,
              await tokens.refreshToken != nil
        else { return }
        // TokenManager classifies the failure: 4xx clears the keychain
        // and emits sessionCleared(.refreshFailed); transient errors
        // leave the session and we just send the (still expired) token
        // and let the server respond — the post-401 path retries once.
        _ = try? await tokens.refreshSession()
    }

    /// Decide whether a thrown `PalbaseCoreError` from `executeWithRetry`
    /// is worth one reactive refresh attempt. Only 401 on a path that
    /// would actually carry a Bearer qualifies.
    private func shouldAttemptReactiveRefresh(err: PalbaseCoreError, path: String) async -> Bool {
        guard !Self.isUnauthenticatedPath(path) else { return false }
        guard case .http(let status, _, _, _) = err, status == 401 else { return false }
        let hasFn = await tokens.refreshFunction != nil
        let hasRt = await tokens.refreshToken != nil
        return hasFn && hasRt
    }

    private func executeWithRetry(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        extraHeaders: [String: String],
        attempt: Int
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int) {
        let url = try getBaseURL().appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = config.requestTimeout

        let headers = await buildHeaders(extra: extraHeaders, path: path)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        if let body = body {
            do {
                request.httpBody = try JSONEncoder.palbaseDefault.encode(body)
            } catch {
                throw PalbaseCoreError.encoding(message: error.localizedDescription)
            }
        }

        for interceptor in interceptors {
            do {
                try await interceptor.intercept(&request)
            } catch let err as PalbaseCoreError {
                throw err
            } catch {
                throw PalbaseCoreError.network(message: "Interceptor failed: \(error.localizedDescription)")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await config.urlSession.data(for: request)
        } catch {
            if attempt < config.maxRetries - 1 {
                let backoff = config.initialBackoffMs * UInt64(pow(2.0, Double(attempt)))
                try? await Task.sleep(nanoseconds: backoff * 1_000_000)
                return try await executeWithRetry(method: method, path: path, body: body, extraHeaders: extraHeaders, attempt: attempt + 1)
            }
            throw PalbaseCoreError.network(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PalbaseCoreError.network(message: "Invalid response (not HTTP).")
        }

        // 429 retry
        if http.statusCode == 429, attempt < config.maxRetries - 1 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
            let delayMs = retryAfter.map { UInt64($0 * 1000) } ?? (config.initialBackoffMs * UInt64(pow(2.0, Double(attempt))))
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            return try await executeWithRetry(method: method, path: path, body: body, extraHeaders: extraHeaders, attempt: attempt + 1)
        }

        // Map non-2xx to PalbaseCoreError unless modules want to handle it
        if !(200..<300).contains(http.statusCode) {
            throw mapHTTPError(status: http.statusCode, data: data)
        }

        return (data, http.statusCode)
    }

    private func mapHTTPError(status: Int, data: Data) -> PalbaseCoreError {
        let envelope = try? JSONDecoder.palbaseDefault.decode(PalbaseErrorEnvelope.self, from: data)
        let code = envelope?.code ?? "unknown_error"
        let message = envelope?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let requestId = envelope?.requestId

        switch status {
        case 429: return .rateLimited(retryAfter: nil)
        case 500...599: return .server(status: status, message: message)
        default: return .http(status: status, code: code, message: message, requestId: requestId)
        }
    }
}

// MARK: - Empty response sentinel for void endpoints

package struct EmptyResponse: Decodable, Sendable {
    package init() {}
}
