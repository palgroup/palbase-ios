import Foundation
import PalbaseCore

/// Palbase Docs module entry point. Use `PalbaseDocs.shared` after `PalbaseSDK.configure(_:)`.
public struct PalbaseDocs: Sendable {
    private let http: HTTPRequesting
    private let tokens: TokenManager

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared client backed by the global SDK configuration.
    public static var shared: PalbaseDocs {
        get throws {
            let http = try PalbaseSDK.requireHTTP()
            let tokens = try PalbaseSDK.requireTokens()
            return PalbaseDocs(http: http, tokens: tokens)
        }
    }

    // TODO: Implement Docs API
}
