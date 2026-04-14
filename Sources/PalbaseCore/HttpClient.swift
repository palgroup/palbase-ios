import Foundation

private let palbaseDomain = "palbase.studio"
private let maxRetries = 3
private let initialBackoffMs: UInt64 = 200

public typealias RequestInterceptor = @Sendable (inout URLRequest) async throws -> Void

public actor HttpClient {
    private let apiKey: String
    private let options: HttpClientOptions
    private let urlSession: URLSession
    private var interceptors: [RequestInterceptor] = []
    public private(set) var tokenManager: TokenManager?

    public init(
        apiKey: String,
        options: HttpClientOptions = .init(),
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.options = options
        self.urlSession = urlSession
    }

    public func setTokenManager(_ manager: TokenManager) {
        self.tokenManager = manager
    }

    public func addInterceptor(_ interceptor: @escaping RequestInterceptor) {
        interceptors.append(interceptor)
    }

    public func request<T: Decodable & Sendable>(
        _ method: String,
        path: String,
        body: (any Encodable & Sendable)? = nil,
        headers: [String: String] = [:],
        decoding: T.Type = T.self
    ) async -> PalbaseResponse<T> {
        // Auto-refresh if token is expired
        if let tm = tokenManager, await tm.isExpired, await tm.refreshFunction != nil {
            _ = try? await tm.refreshSession()
        }

        return await executeWithRetry(method: method, path: path, body: body, extraHeaders: headers, attempt: 0)
    }

    /// Request without response body (204 No Content or discardable)
    public func requestVoid(
        _ method: String,
        path: String,
        body: (any Encodable & Sendable)? = nil,
        headers: [String: String] = [:]
    ) async -> PalbaseResponse<EmptyResponse> {
        await request(method, path: path, body: body, headers: headers, decoding: EmptyResponse.self)
    }

    // MARK: - Private

    private func getBaseUrl() throws -> URL {
        if let url = options.url, let parsed = URL(string: url) {
            return parsed
        }

        guard let ref = Self.parseProjectRef(from: apiKey) else {
            throw PalbaseError(
                code: "invalid_api_key",
                message: "Invalid API key format. Expected: pb_{ref}_{random}. Provide an explicit url option for custom endpoints."
            )
        }

        guard let url = URL(string: "https://\(ref).\(palbaseDomain)") else {
            throw PalbaseError(code: "invalid_api_key", message: "Could not construct base URL from API key")
        }
        return url
    }

    private func buildHeaders(extra: [String: String]) async -> [String: String] {
        var headers: [String: String] = [
            "apikey": apiKey,
            "Content-Type": "application/json"
        ]

        if let tm = tokenManager, let token = await tm.accessToken {
            headers["Authorization"] = "Bearer \(token)"
        }

        if let serviceRole = options.serviceRoleKey {
            headers["Authorization"] = "Bearer \(serviceRole)"
        }

        for (k, v) in options.headers {
            headers[k] = v
        }
        for (k, v) in extra {
            headers[k] = v
        }
        return headers
    }

    private func executeWithRetry<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        extraHeaders: [String: String],
        attempt: Int
    ) async -> PalbaseResponse<T> {
        let url: URL
        do {
            url = try getBaseUrl().appendingPathComponent(path)
        } catch let err as PalbaseError {
            return PalbaseResponse(data: nil, error: err, status: 0)
        } catch {
            return PalbaseResponse(data: nil, error: PalbaseError(code: "url_error", message: error.localizedDescription), status: 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method

        let headers = await buildHeaders(extra: extraHeaders)
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        if let body = body {
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                return PalbaseResponse(
                    data: nil,
                    error: PalbaseError(code: "encoding_error", message: "Failed to encode request body: \(error.localizedDescription)"),
                    status: 0
                )
            }
        }

        for interceptor in interceptors {
            do {
                try await interceptor(&request)
            } catch let err as PalbaseError {
                return PalbaseResponse(data: nil, error: err, status: 0)
            } catch {
                return PalbaseResponse(
                    data: nil,
                    error: PalbaseError(code: "interceptor_error", message: error.localizedDescription),
                    status: 0
                )
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            if attempt < maxRetries - 1 {
                try? await Task.sleep(nanoseconds: initialBackoffMs * 1_000_000 * UInt64(pow(2.0, Double(attempt))))
                return await executeWithRetry(method: method, path: path, body: body, extraHeaders: extraHeaders, attempt: attempt + 1)
            }
            return PalbaseResponse(
                data: nil,
                error: PalbaseError(code: "network_error", message: error.localizedDescription),
                status: 0
            )
        }

        guard let http = response as? HTTPURLResponse else {
            return PalbaseResponse(data: nil, error: .invalidResponse, status: 0)
        }

        // 429 retry with Retry-After
        if http.statusCode == 429, attempt < maxRetries - 1 {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) }
            let delayMs = retryAfter.map { UInt64($0 * 1000) }
                ?? initialBackoffMs * UInt64(pow(2.0, Double(attempt)))
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            return await executeWithRetry(method: method, path: path, body: body, extraHeaders: extraHeaders, attempt: attempt + 1)
        }

        return decode(data: data, statusCode: http.statusCode)
    }

    private func decode<T: Decodable & Sendable>(data: Data, statusCode: Int) -> PalbaseResponse<T> {
        let isSuccess = (200..<300).contains(statusCode)

        if !isSuccess {
            let errorBody = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            return PalbaseResponse(
                data: nil,
                error: PalbaseError(
                    code: errorBody?.error ?? "unknown_error",
                    message: errorBody?.errorDescription ?? HTTPURLResponse.localizedString(forStatusCode: statusCode),
                    status: statusCode,
                    requestId: errorBody?.requestId
                ),
                status: statusCode
            )
        }

        if T.self == EmptyResponse.self {
            return PalbaseResponse(data: EmptyResponse() as? T, error: nil, status: statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            return PalbaseResponse(data: decoded, error: nil, status: statusCode)
        } catch {
            return PalbaseResponse(
                data: nil,
                error: PalbaseError(code: "decoding_error", message: "Failed to decode response: \(error.localizedDescription)", status: statusCode),
                status: statusCode
            )
        }
    }

    static func parseProjectRef(from apiKey: String) -> String? {
        let parts = apiKey.split(separator: "_")
        // Format: pb_{ref}_{random}
        guard parts.count >= 3, parts[0] == "pb" else { return nil }
        return String(parts[1])
    }
}

public struct HttpClientOptions: Sendable {
    public let url: String?
    public let serviceRoleKey: String?
    public let headers: [String: String]

    public init(url: String? = nil, serviceRoleKey: String? = nil, headers: [String: String] = [:]) {
        self.url = url
        self.serviceRoleKey = serviceRoleKey
        self.headers = headers
    }
}

public struct EmptyResponse: Decodable, Sendable {
    public init() {}
}

private struct ErrorEnvelope: Decodable {
    let error: String?
    let errorDescription: String?
    let status: Int?
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case status
        case requestId = "request_id"
    }
}
