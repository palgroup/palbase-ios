import Foundation
import PalbaseCore

/// Palbase Cms module entry point. Use `PalbaseCms.shared` after `Palbase.configure(_:)`.
public struct PalbaseCms: Sendable {
    private let http: HTTPRequesting
    private let tokens: TokenManager

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared client backed by the global SDK configuration.
    public static var shared: PalbaseCms {
        get throws {
            let http = try Palbase.requireHTTP()
            let tokens = try Palbase.requireTokens()
            return PalbaseCms(http: http, tokens: tokens)
        }
    }

    // TODO: Implement Cms API
}
