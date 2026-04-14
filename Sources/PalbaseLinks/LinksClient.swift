import Foundation
import PalbaseCore

/// Palbase Links module entry point. Use `PalbaseLinks.shared` after `PalbaseSDK.configure(_:)`.
public struct PalbaseLinks: Sendable {
    private let http: HTTPRequesting
    private let tokens: TokenManager

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared client backed by the global SDK configuration.
    public static var shared: PalbaseLinks {
        get throws {
            let http = try PalbaseSDK.requireHTTP()
            let tokens = try PalbaseSDK.requireTokens()
            return PalbaseLinks(http: http, tokens: tokens)
        }
    }

    // TODO: Implement Links API
}
