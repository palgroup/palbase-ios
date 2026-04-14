import Foundation
import PalbaseCore

/// Palbase Storage module entry point. Use `PalbaseStorage.shared` after `Palbase.configure(_:)`.
public struct PalbaseStorage: Sendable {
    private let http: HTTPRequesting
    private let tokens: TokenManager

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    /// Shared client backed by the global SDK configuration.
    public static var shared: PalbaseStorage {
        get throws {
            let http = try Palbase.requireHTTP()
            let tokens = try Palbase.requireTokens()
            return PalbaseStorage(http: http, tokens: tokens)
        }
    }

    // TODO: Implement Storage API
}
