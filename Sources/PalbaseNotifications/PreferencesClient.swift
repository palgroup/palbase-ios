import Foundation
@_exported import PalbaseCore

/// Per-user notifications preferences (channel × category opt-in map).
///
/// Marketing-class messages on opted-out channels are skipped server-side
/// before any provider call — palnotify returns a `Skipped=true` outcome
/// so callers can still log the no-op.
public struct PreferencesClient: Sendable {
    private let http: HTTPRequesting
    private let pathPrefix: String

    package init(http: HTTPRequesting, pathPrefix: String) {
        self.http = http
        self.pathPrefix = pathPrefix
    }

    /// Fetch the authenticated user's preferences.
    public func get() async throws(NotificationsError) -> NotificationPreferences {
        do {
            return try await http.request(
                method: "GET",
                path: "\(pathPrefix)/preferences",
                body: nil,
                headers: [:]
            )
        } catch let err {
            throw NotificationsError.from(transport: err)
        }
    }

    /// Replace the authenticated user's preferences. The server stores
    /// the map as the new source of truth; merge semantics are the
    /// caller's responsibility (read → mutate → write).
    public func update(
        _ prefs: NotificationPreferences
    ) async throws(NotificationsError) -> NotificationPreferences {
        do {
            return try await http.request(
                method: "PUT",
                path: "\(pathPrefix)/preferences",
                body: prefs,
                headers: [:]
            )
        } catch let err {
            throw NotificationsError.from(transport: err)
        }
    }
}
