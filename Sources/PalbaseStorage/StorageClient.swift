import Foundation
@_exported import PalbaseCore

/// Palbase Storage module entry point. Use `PalbaseStorage.shared` after
/// `Palbase.configure(_:)`.
///
/// ```swift
/// let avatars = try PalbaseStorage.shared.bucket("avatars")
/// _ = try await avatars.upload(path: "me.png", data: pngData)
/// let url = try await avatars.createSignedURL(path: "me.png", expiresIn: 3600)
/// ```
public struct PalbaseStorage: Sendable {
    let http: HTTPRequesting
    let tokens: TokenManager
    let pathPrefix: String

    package init(
        http: HTTPRequesting,
        tokens: TokenManager,
        pathPrefix: String = "/storage/v1"
    ) {
        self.http = http
        self.tokens = tokens
        self.pathPrefix = pathPrefix
    }

    /// Shared storage client backed by the global SDK configuration. Throws
    /// `StorageError.notConfigured` if `Palbase.configure(_:)` was not called.
    public static var shared: PalbaseStorage {
        get throws(StorageError) {
            guard let http = Palbase.http, let tokens = Palbase.tokens else {
                throw StorageError.notConfigured
            }
            return PalbaseStorage(http: http, tokens: tokens)
        }
    }

    /// Reference a bucket by name. Validates the name before returning.
    public func bucket(_ name: String) throws(StorageError) -> BucketRef {
        try PathValidator.validateBucket(name)
        return BucketRef(name: name, http: http, pathPrefix: pathPrefix)
    }
}
