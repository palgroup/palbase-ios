import Foundation
@_exported import PalbaseCore

// MARK: - PalbaseLinks Client (placeholder — implementation coming)
public final class PalbaseLinksClient: Sendable {
    public let http: HttpClient

    public init(http: HttpClient) {
        self.http = http
    }
}
