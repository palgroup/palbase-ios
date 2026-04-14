import Foundation
import PalbaseCore

/// Palbase Flags module entry point. Use `PalbaseFlags.shared` after `PalbaseSDK.configure(_:)`.
public struct PalbaseFlags: Sendable {
    private let http: HTTPRequesting
    private let tokens: TokenManager

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared client backed by the global SDK configuration.
    public static var shared: PalbaseFlags {
        get throws {
            let http = try PalbaseSDK.requireHTTP()
            let tokens = try PalbaseSDK.requireTokens()
            return PalbaseFlags(http: http, tokens: tokens)
        }
    }

    // TODO: Implement Flags API
}
