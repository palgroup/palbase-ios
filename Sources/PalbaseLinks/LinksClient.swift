import Foundation
@_exported import PalbaseCore

/// Palbase Links module entry point. Use `PalbaseLinks.shared` after `Palbase.configure(_:)`.
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
            let http = try Palbase.requireHTTP()
            let tokens = try Palbase.requireTokens()
            return PalbaseLinks(http: http, tokens: tokens)
        }
    }

    // TODO: Implement Links API
}
