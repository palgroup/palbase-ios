import Foundation

/// Configuration for `HttpClient` and module clients.
public struct PalbaseConfig: Sendable {
    /// API key in `pb_{ref}_{random}` format.
    public let apiKey: String

    /// Override the base URL. Defaults to `https://{ref}.palbase.studio` derived from the API key.
    public let url: String?

    /// Service role key. When set, used instead of the user's access token (server-side).
    public let serviceRoleKey: String?

    /// Custom headers added to every request.
    public let headers: [String: String]

    /// URLSession used for requests. Defaults to `.shared`. Override for testing or background uploads.
    public let urlSession: URLSession

    /// Token storage. Defaults to in-memory. Use `KeychainTokenStorage` for persistence.
    public let tokenStorage: TokenStorage

    /// Request timeout in seconds. Defaults to 30.
    public let requestTimeout: TimeInterval

    /// Number of retry attempts for network/429 errors. Defaults to 3.
    public let maxRetries: Int

    /// Initial backoff (ms) between retries. Defaults to 200ms. Doubles each attempt.
    public let initialBackoffMs: UInt64

    public init(
        apiKey: String,
        url: String? = nil,
        serviceRoleKey: String? = nil,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared,
        tokenStorage: TokenStorage = InMemoryTokenStorage(),
        requestTimeout: TimeInterval = 30,
        maxRetries: Int = 3,
        initialBackoffMs: UInt64 = 200
    ) {
        self.apiKey = apiKey
        self.url = url
        self.serviceRoleKey = serviceRoleKey
        self.headers = headers
        self.urlSession = urlSession
        self.tokenStorage = tokenStorage
        self.requestTimeout = requestTimeout
        self.maxRetries = maxRetries
        self.initialBackoffMs = initialBackoffMs
    }
}
