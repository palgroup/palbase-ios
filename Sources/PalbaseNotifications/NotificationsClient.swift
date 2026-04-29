import Foundation
@_exported import PalbaseCore

/// Palbase Notifications module entry point. Use
/// `PalbaseNotifications.shared` after `Palbase.configure(_:)`.
///
/// Capabilities exposed to apps:
///   - Register / unregister the platform push token (APNs / FCM).
///   - Read the authenticated user's in-app inbox (list / unread-count /
///     mark-read / archive).
///   - Read / update notification preferences (per-channel × category
///     opt-in map).
///
/// Server-only senders (push.send, email.send, sms.send, inbox.send) are
/// intentionally **not** part of this surface — those need a service-role
/// apikey and live on the backend SDKs (`@palbase/server`'s
/// ServerClient.notifications, or `ctx.palbase.notifications` inside a
/// palbase-backend handler).
public struct PalbaseNotifications: Sendable {
    private let http: HTTPRequesting
    private let tokens: TokenManager
    private let pathPrefix: String

    public let inbox: InboxClient
    public let preferences: PreferencesClient

    package init(
        http: HTTPRequesting,
        tokens: TokenManager,
        pathPrefix: String = "/v1/notifications"
    ) {
        self.http = http
        self.tokens = tokens
        self.pathPrefix = pathPrefix
        self.inbox = InboxClient(http: http, pathPrefix: pathPrefix)
        self.preferences = PreferencesClient(http: http, pathPrefix: pathPrefix)
    }

    /// Shared notifications client backed by the global SDK
    /// configuration. Throws `notConfigured` if `Palbase.configure(_:)`
    /// has not been called.
    public static var shared: PalbaseNotifications {
        get throws(NotificationsError) {
            guard let http = Palbase.http, let tokens = Palbase.tokens else {
                throw NotificationsError.notConfigured
            }
            return PalbaseNotifications(http: http, tokens: tokens)
        }
    }

    // MARK: - Devices

    /// Register or refresh the device's push token. Call this once on
    /// app launch after the user accepts the notifications permission.
    ///
    /// - Important: On iOS, hex-encode the raw `Data` token from
    ///   `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
    ///   before calling — the server expects a hex string per APNs
    ///   convention.
    public func registerDevice(
        _ params: RegisterDeviceParams
    ) async throws(NotificationsError) -> DeviceTokenView {
        guard !params.token.isEmpty else { throw .emptyDeviceToken }
        guard !params.deviceId.isEmpty else { throw .emptyDeviceId }
        do {
            return try await http.request(
                method: "POST",
                path: "\(pathPrefix)/devices",
                body: params,
                headers: [:]
            )
        } catch let coreErr {
            throw NotificationsError.from(transport: coreErr)
        }
    }

    /// Remove a device token. Call on signOut so future pushes don't
    /// land on a stale device.
    public func unregisterDevice(
        deviceId: String
    ) async throws(NotificationsError) {
        guard !deviceId.isEmpty else { throw .emptyDeviceId }
        let encoded = deviceId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? deviceId
        do {
            try await http.requestVoid(
                method: "DELETE",
                path: "\(pathPrefix)/devices/\(encoded)",
                body: nil,
                headers: [:]
            )
        } catch let coreErr {
            throw NotificationsError.from(transport: coreErr)
        }
    }
}
