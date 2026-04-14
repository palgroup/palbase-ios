import Foundation
@_exported import PalbaseCore

// MARK: - PalbaseDocs Client (placeholder — implementation coming)
public final class PalbaseDocsClient: Sendable {
    public let http: HttpClient

    public init(http: HttpClient) {
        self.http = http
    }
}
