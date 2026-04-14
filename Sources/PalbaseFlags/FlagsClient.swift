import Foundation
@_exported import PalbaseCore

// MARK: - PalbaseFlags Client (placeholder — implementation coming)
public final class PalbaseFlagsClient: Sendable {
    public let http: HttpClient

    public init(http: HttpClient) {
        self.http = http
    }
}
