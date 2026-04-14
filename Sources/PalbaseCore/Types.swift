import Foundation

/// User authentication session — access + refresh tokens with expiry.
public struct Session: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String
    /// Unix timestamp (seconds) when the access token expires.
    public let expiresAt: Int64

    package init(accessToken: String, refreshToken: String, expiresAt: Int64) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        let now = Int64(Date().timeIntervalSince1970)
        return now >= expiresAt
    }
}

/// Auth state events emitted by `TokenManager`.
public enum AuthStateEvent: Sendable {
    case sessionSet
    case sessionCleared
    case tokenRefreshed
}

public typealias AuthStateCallback = @Sendable (AuthStateEvent, Session?) -> Void

/// Returned by listener registration. Call to stop receiving events.
public typealias Unsubscribe = @Sendable () -> Void
