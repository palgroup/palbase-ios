import Foundation
@_exported import PalbaseCore

// MARK: - PalbaseStorage Client (placeholder — implementation coming)
public final class PalbaseStorageClient: Sendable {
    public let http: HttpClient

    public init(http: HttpClient) {
        self.http = http
    }
}
