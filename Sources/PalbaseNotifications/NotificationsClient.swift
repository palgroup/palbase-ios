import Foundation
import PalbaseCore

/// Palbase Notifications module entry point. Use `PalbaseNotifications.shared` after `PalbaseSDK.configure(_:)`.
public struct PalbaseNotifications: Sendable {
    private let http: HTTPRequesting
    private let tokens: TokenManager

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared client backed by the global SDK configuration.
    public static var shared: PalbaseNotifications {
        get throws {
            let http = try PalbaseSDK.requireHTTP()
            let tokens = try PalbaseSDK.requireTokens()
            return PalbaseNotifications(http: http, tokens: tokens)
        }
    }

    // TODO: Implement Notifications API
}
