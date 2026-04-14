import Foundation
import PalbaseCore

/// Palbase Analytics module entry point. Use `PalbaseAnalytics.shared` after `PalbaseSDK.configure(_:)`.
public struct PalbaseAnalytics: Sendable {
    private let http: HTTPRequesting
    private let tokens: TokenManager

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared client backed by the global SDK configuration.
    public static var shared: PalbaseAnalytics {
        get throws {
            let http = try PalbaseSDK.requireHTTP()
            let tokens = try PalbaseSDK.requireTokens()
            return PalbaseAnalytics(http: http, tokens: tokens)
        }
    }

    // TODO: Implement Analytics API
}
