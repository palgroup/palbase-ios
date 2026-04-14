import Foundation
@_exported import PalbaseCore

// MARK: - PalbaseRealtime Client (placeholder — implementation coming)
public final class PalbaseRealtimeClient: Sendable {
    public let http: HttpClient

    public init(http: HttpClient) {
        self.http = http
    }
}
