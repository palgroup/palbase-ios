import Foundation
@_exported import PalbaseCore

// MARK: - PalbaseDB Client (placeholder — implementation coming)
public final class PalbaseDBClient: Sendable {
    public let http: HttpClient

    public init(http: HttpClient) {
        self.http = http
    }
}
