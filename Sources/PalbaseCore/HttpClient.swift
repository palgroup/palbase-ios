import Foundation

/// Default HTTP client implementation backed by URLSession.
package actor HttpClient: HTTPRequesting {
    private let config: PalbaseConfig
    private let tokens: TokenManager
    private var interceptors: [RequestInterceptor] = []
    private var attestor: AppAttesting?

    package init(config: PalbaseConfig, tokens: TokenManager) {
        self.config = config
        self.tokens = tokens
    }

    package func addInterceptor(_ interceptor: RequestInterceptor) {
        interceptors.append(interceptor)
    }

    /// Install the App Attest provider. When set, every request (except
    /// the attestation endpoints themselves and unauthenticated credential
    /// exchanges) carries a fresh, request-bound assertion proving the
    /// call came from a genuine build of the app. `nil` = off.
    package func setAttestor(_ attestor: AppAttesting?) {
        self.attestor = attestor
    }

    /// Compute App Attest headers for an outgoing request, or `nil` when
    /// attestation is off / not applicable. Skips the `/attest/*`
    /// endpoints (the attestor calls them itself — attaching an assertion
    /// there would recurse) and unauthenticated credential paths.
    private func attestationHeaders(method: String, path: String, body: Data?) async throws(PalbaseCoreError) -> [String: String] {
        guard let attestor, !Self.isAttestPath(path), !Self.isUnauthenticatedPath(path) else {
            return [:]
        }
        do {
            return try await attestor.assertionHeaders(method: method, path: path, body: body)
        } catch {
            // An attestation failure must not be silently dropped — the
            // server would reject the request anyway. Surface it as a
            // network-class error so the caller sees a clear failure.
            throw PalbaseCoreError.network(message: "App Attest failed: \(error.localizedDescription)")
        }
    }

    /// Attestation endpoints the attestor itself drives; never attested.
    nonisolated static func isAttestPath(_ path: String) -> Bool {
        path.hasPrefix("/attest/")
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
            let status: Int? = { if case .http(let s, _, _, _) = err { return s }; return nil }()
            if let status, await shouldAttemptReactiveRefresh(status: status, path: path) {
                let renewed = (try? await tokens.refreshSession()) != nil
                if renewed {
                    return try await executeWithRetry(method: method, path: path, body: body, extraHeaders: headers, attempt: 0)
                }
            }
            throw err
        }
    }

    package func requestRawBodyResult(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String]
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int, headers: [String: String]) {
        await preflightRefresh(path: path)

        var result = try await executeResult(method: method, path: path, body: body, extraHeaders: headers, attempt: 0)

        // Reactive refresh: a 401 on a Bearer-carrying path gets one
        // renew-and-replay attempt, mirroring requestRaw's behavior — but
        // here the 401 is a returned response, not a thrown error.
        if result.status == 401, await shouldAttemptReactiveRefresh(status: 401, path: path) {
            let renewed = (try? await tokens.refreshSession()) != nil
            if renewed {
                result = try await executeResult(method: method, path: path, body: body, extraHeaders: headers, attempt: 0)
            }
        }
        return (result.data, result.status, result.headers)
    }

    package func uploadRawBodyResult(
        method: String,
        path: String,
        body: Data,
        headers: [String: String],
        onProgress: (@Sendable (_ sent: Int64, _ total: Int64) -> Void)?
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

        var merged = await buildHeaders(extra: headers, path: path)
        // Caller sets multipart Content-Type via headers; never override it.
        if headers["Content-Type"] == nil && headers["content-type"] == nil {
            merged.removeValue(forKey: "Content-Type")
        }
        for (k, v) in try await attestationHeaders(method: method, path: path, body: body) { merged[k] = v }
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

        let delegate = onProgress.map { UploadProgressDelegate(onProgress: $0) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await config.urlSession.upload(for: request, from: body, delegate: delegate)
        } catch {
            if Task.isCancelled || Self.isCancellation(error) {
                throw PalbaseCoreError.network(message: "Upload cancelled.")
            }
            throw PalbaseCoreError.network(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PalbaseCoreError.network(message: "Invalid response (not HTTP).")
        }

        var respHeaders: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { respHeaders[ks] = vs }
        }
        return (data, http.statusCode, respHeaders)
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
        for (k, v) in try await attestationHeaders(method: method, path: path, body: body) { merged[k] = v }
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

    /// Decide whether a 401 on `path` is worth one reactive refresh
    /// attempt. Only a Bearer-carrying path with a usable refresh token
    /// qualifies. Shared by the throwing (`requestRaw`) and non-throwing
    /// (`requestRawResult`) paths.
    private func shouldAttemptReactiveRefresh(status: Int, path: String) async -> Bool {
        guard status == 401 else { return false }
        guard !Self.isUnauthenticatedPath(path) else { return false }
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

        // Bind App Attest to the exact bytes on the wire (request.httpBody).
        for (k, v) in try await attestationHeaders(method: method, path: path, body: request.httpBody) {
            request.setValue(v, forHTTPHeaderField: k)
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
            // A cancelled Task must surface immediately — never retried,
            // never re-mapped to a network error. URLSession reports this
            // as URLError.cancelled; Swift Concurrency may also throw
            // CancellationError directly.
            if Task.isCancelled || Self.isCancellation(error) {
                throw PalbaseCoreError.network(message: "Request cancelled.")
            }
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

    /// Non-throwing sibling of `executeWithRetry`: runs the same transport
    /// retry + 429 backoff, but a terminal non-2xx is **returned** (body,
    /// status, headers, parsed `Retry-After`) instead of being mapped to a
    /// `PalbaseCoreError`. Genuine transport failures and cancellation
    /// still throw — there is no HTTP response to hand back.
    private func executeResult(
        method: String,
        path: String,
        body: Data?,
        extraHeaders: [String: String],
        attempt: Int
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int, headers: [String: String], retryAfter: Int?) {
        let url = try getBaseURL().appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = config.requestTimeout
        if let body { request.httpBody = body }

        var merged = await buildHeaders(extra: extraHeaders, path: path)
        // Caller-provided Content-Type wins; strip the default JSON one
        // unless the caller set it (matches requestRawBody behavior).
        if extraHeaders["Content-Type"] == nil && extraHeaders["content-type"] == nil {
            merged.removeValue(forKey: "Content-Type")
        }
        for (k, v) in try await attestationHeaders(method: method, path: path, body: body) { merged[k] = v }
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
            if Task.isCancelled || Self.isCancellation(error) {
                throw PalbaseCoreError.network(message: "Request cancelled.")
            }
            if attempt < config.maxRetries - 1 {
                let backoff = config.initialBackoffMs * UInt64(pow(2.0, Double(attempt)))
                try? await Task.sleep(nanoseconds: backoff * 1_000_000)
                return try await executeResult(method: method, path: path, body: body, extraHeaders: extraHeaders, attempt: attempt + 1)
            }
            throw PalbaseCoreError.network(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PalbaseCoreError.network(message: "Invalid response (not HTTP).")
        }

        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }

        // 429 backoff/retry (same policy as the throwing path).
        if http.statusCode == 429, attempt < config.maxRetries - 1 {
            let delayMs = retryAfter.map { UInt64($0 * 1000) } ?? (config.initialBackoffMs * UInt64(pow(2.0, Double(attempt))))
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            return try await executeResult(method: method, path: path, body: body, extraHeaders: extraHeaders, attempt: attempt + 1)
        }

        var respHeaders: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { respHeaders[ks] = vs }
        }
        return (data, http.statusCode, respHeaders, retryAfter)
    }

    /// True when an error thrown by `URLSession` represents cancellation.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
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

// MARK: - Upload progress delegate

/// Per-task delegate that forwards `URLSession` send-progress to a
/// caller-supplied closure. URLSession invokes delegate callbacks on its
/// own delegate queue, so the closure must be `@Sendable`.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (_ sent: Int64, _ total: Int64) -> Void

    init(onProgress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}
