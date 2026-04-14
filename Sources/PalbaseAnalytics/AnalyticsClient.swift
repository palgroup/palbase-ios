import Foundation
@_exported import PalbaseCore

/// Palbase Analytics module entry point. Use `PalbaseAnalytics.shared` after `Palbase.configure(_:)`.
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
            let http = try Palbase.requireHTTP()
            let tokens = try Palbase.requireTokens()
            return PalbaseAnalytics(http: http, tokens: tokens)
        }
    }

    // TODO: Implement Analytics API
}
