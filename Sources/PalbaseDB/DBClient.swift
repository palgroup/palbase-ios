import Foundation
import PalbaseCore

/// Palbase DB module entry point. Use `PalbaseDB.shared` after `PalbaseSDK.configure(_:)`.
public struct PalbaseDB: Sendable {
    private let http: HTTPRequesting
    private let tokens: TokenManager

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared client backed by the global SDK configuration.
    public static var shared: PalbaseDB {
        get throws {
            let http = try PalbaseSDK.requireHTTP()
            let tokens = try PalbaseSDK.requireTokens()
            return PalbaseDB(http: http, tokens: tokens)
        }
    }

    // TODO: Implement DB API
}
