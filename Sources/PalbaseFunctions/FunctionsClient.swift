import Foundation
import PalbaseCore

/// Palbase Functions module entry point. Use `PalbaseFunctions.shared` after `PalbaseSDK.configure(_:)`.
public struct PalbaseFunctions: Sendable {
    private let http: HTTPRequesting
    private let tokens: TokenManager

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared client backed by the global SDK configuration.
    public static var shared: PalbaseFunctions {
        get throws {
            let http = try PalbaseSDK.requireHTTP()
            let tokens = try PalbaseSDK.requireTokens()
            return PalbaseFunctions(http: http, tokens: tokens)
        }
    }

    // TODO: Implement Functions API
}
