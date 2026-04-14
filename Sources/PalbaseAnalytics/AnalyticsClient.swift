import Foundation
@_exported import PalbaseCore

// MARK: - PalbaseAnalytics Client (placeholder — implementation coming)
public final class PalbaseAnalyticsClient: Sendable {
    public let http: HttpClient

    public init(http: HttpClient) {
        self.http = http
    }
}
