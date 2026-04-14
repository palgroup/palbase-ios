import Foundation
import PalbaseCore

/// Palbase Storage module entry point. Use `PalbaseStorage.shared` after `PalbaseSDK.configure(_:)`.
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
            let http = try PalbaseSDK.requireHTTP()
            let tokens = try PalbaseSDK.requireTokens()
            return PalbaseStorage(http: http, tokens: tokens)
        }
    }

    // TODO: Implement Storage API
}
