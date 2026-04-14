import Foundation
@_exported import PalbaseCore

public actor PalbaseFunctionsClient {
    private let http: HttpClient
    private let tokens: TokenManager

    /// Direct construction — for granular module-only usage.
    public init(apiKey: String, options: HttpClientOptions = .init()) {
        let http = HttpClient(apiKey: apiKey, options: options)
        let tokens = TokenManager()
        self.http = http
        self.tokens = tokens
        Task { await http.setTokenManager(tokens) }
    }

    /// Internal — used by `PalbaseClient` umbrella to share HttpClient/TokenManager.
    public init(sharedHttp: HttpClient, sharedTokens: TokenManager) {
        self.http = sharedHttp
        self.tokens = sharedTokens
    }

    public var httpClient: HttpClient { http }
    public var tokenManager: TokenManager { tokens }

    // TODO: Implement Functions API
}
