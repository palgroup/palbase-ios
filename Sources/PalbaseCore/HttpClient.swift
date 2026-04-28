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
        // Auto-refresh expired token before request
        if await tokens.isExpired, await tokens.refreshFunction != nil, await tokens.refreshToken != nil {
            _ = try? await tokens.refreshSession()
        }

        return try await executeWithRetry(method: method, path: path, body: body, extraHeaders: headers, attempt: 0)
    }

    package func requestRawBody(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String]
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int, headers: [String: String]) {
        if await tokens.isExpired, await tokens.refreshFunction != nil, await tokens.refreshToken != nil {
            _ = try? await tokens.refreshSession()
        }

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

        var merged = await buildHeaders(extra: headers)
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

    private func buildHeaders(extra: [String: String]) async -> [String: String] {
        var headers: [String: String] = [
            "apikey": config.apiKey,
            "Content-Type": "application/json"
        ]

        if let token = await tokens.accessToken {
            headers["Authorization"] = "Bearer \(token)"
        }

        if let serviceRole = config.serviceRoleKey {
            headers["Authorization"] = "Bearer \(serviceRole)"
        }

        for (k, v) in config.headers { headers[k] = v }
        for (k, v) in extra { headers[k] = v }
        return headers
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

        let headers = await buildHeaders(extra: extraHeaders)
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
