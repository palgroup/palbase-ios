import Foundation
@_exported import PalbaseCore

/// Palbase Realtime module entry point. Use `PalbaseRealtime.shared` after `Palbase.configure(_:)`.
public struct PalbaseRealtime: Sendable {
    private let http: HTTPRequesting
    private let tokens: TokenManager

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared client backed by the global SDK configuration.
    public static var shared: PalbaseRealtime {
        get throws {
            let http = try Palbase.requireHTTP()
            let tokens = try Palbase.requireTokens()
            return PalbaseRealtime(http: http, tokens: tokens)
        }
    }

    // TODO: Implement Realtime API
}
