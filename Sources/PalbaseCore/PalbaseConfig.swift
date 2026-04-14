import Foundation

/// Configuration for the SDK. Apps usually call `Palbase.configure(apiKey:)` —
/// only use this struct when you need to override transport behavior (custom URL,
/// timeouts, custom URLSession for testing).
public struct PalbaseConfig: Sendable {
    /// API key in `pb_{ref}_{random}` format.
    public let apiKey: String

    /// Override the base URL. Defaults to `https://{ref}.palbase.studio` derived from the API key.
    public let url: String?

    /// Service role key (server-only). When set, used instead of the user's access token.
    public let serviceRoleKey: String?

    /// Custom headers added to every request.
    public let headers: [String: String]

    /// URLSession for HTTP. Override for testing or background uploads.
    public let urlSession: URLSession

    /// Request timeout in seconds. Default 30.
    public let requestTimeout: TimeInterval

    /// Number of retry attempts for network/429 errors. Default 3.
    public let maxRetries: Int

    /// Initial backoff (ms) between retries. Doubles each attempt. Default 200.
    public let initialBackoffMs: UInt64

    public init(
        apiKey: String,
        url: String? = nil,
        serviceRoleKey: String? = nil,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared,
        requestTimeout: TimeInterval = 30,
        maxRetries: Int = 3,
        initialBackoffMs: UInt64 = 200
    ) {
        self.apiKey = apiKey
        self.url = url
        self.serviceRoleKey = serviceRoleKey
        self.headers = headers
        self.urlSession = urlSession
        self.requestTimeout = requestTimeout
        self.maxRetries = maxRetries
        self.initialBackoffMs = initialBackoffMs
    }
}
