import Foundation

// Wire types mirroring the palnotify Go API. Keep field names matching
// the JSON payload exactly — the snake_case decoder configured in
// PalbaseCore (`JSONDecoder.palbaseDefault`) handles the Swift naming.

/// Platform of a registered device.
public enum DevicePlatform: String, Codable, Sendable {
    case ios
    case android
    case web
}

/// Body for POST /v1/notifications/devices.
public struct RegisterDeviceParams: Codable, Sendable {
    public let deviceId: String
    public let token: String
    public let platform: DevicePlatform
    public let appVersion: String?
    public let locale: String?

    public init(
        deviceId: String,
        token: String,
        platform: DevicePlatform,
        appVersion: String? = nil,
        locale: String? = nil
    ) {
        self.deviceId = deviceId
        self.token = token
        self.platform = platform
        self.appVersion = appVersion
        self.locale = locale
    }
}

/// Subset of palnotify's DeviceToken returned to the SDK.
public struct DeviceTokenView: Codable, Sendable {
    public let id: String
    public let deviceId: String
    public let platform: DevicePlatform
    public let status: String
    public let createdAt: Date
    public let updatedAt: Date

    package init(
        id: String,
        deviceId: String,
        platform: DevicePlatform,
        status: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.deviceId = deviceId
        self.platform = platform
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Inbox

/// One inbox row as returned by GET /v1/notifications/inbox.
public struct InboxMessage: Codable, Sendable, Identifiable {
    public let id: String
    public let userId: String?
    public let title: String?
    public let body: String
    public let actionUrl: String?
    public let category: String?
    public let isRead: Bool
    public let readAt: Date?
    public let createdAt: Date

    package init(
        id: String,
        userId: String? = nil,
        title: String? = nil,
        body: String,
        actionUrl: String? = nil,
        category: String? = nil,
        isRead: Bool,
        readAt: Date? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.body = body
        self.actionUrl = actionUrl
        self.category = category
        self.isRead = isRead
        self.readAt = readAt
        self.createdAt = createdAt
    }
}

/// Filter + pagination options for listing the inbox.
public struct InboxListOptions: Sendable {
    public var cursor: String?
    public var limit: Int?
    public var isRead: Bool?
    public var category: String?
    public var includeArchived: Bool

    public init(
        cursor: String? = nil,
        limit: Int? = nil,
        isRead: Bool? = nil,
        category: String? = nil,
        includeArchived: Bool = false
    ) {
        self.cursor = cursor
        self.limit = limit
        self.isRead = isRead
        self.category = category
        self.includeArchived = includeArchived
    }
}

/// Response of GET /v1/notifications/inbox.
public struct InboxListResult: Codable, Sendable {
    public let messages: [InboxMessage]
    public let nextCursor: String?

    package init(messages: [InboxMessage], nextCursor: String? = nil) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

/// Response of GET /v1/notifications/inbox/unread-count.
public struct InboxUnreadCount: Codable, Sendable {
    public let count: Int

    package init(count: Int) {
        self.count = count
    }
}

// MARK: - Preferences

/// Per-channel category opt-in/out map.
///
/// Keys are channel names ("push", "email", "sms", "inbox"), values are
/// `category -> allowed` booleans. Missing entries default to opt-in.
public struct NotificationPreferences: Codable, Sendable {
    public var preferences: [String: [String: Bool]]

    public init(preferences: [String: [String: Bool]] = [:]) {
        self.preferences = preferences
    }
}
