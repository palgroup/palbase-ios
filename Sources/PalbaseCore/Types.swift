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

/// Why the SDK cleared the local session. Surfaced to host apps so
/// they can distinguish "user pressed Sign Out" from "server says
/// you're no longer authenticated, take me to login."
public enum SessionClearReason: Sendable, Equatable {
    /// Caller invoked `signOut()`.
    case signOut
    /// Refresh token was rejected by the server (revoked, reused,
    /// expired beyond grace, account deleted/banned). The keychain
    /// is now empty; the host app should route to login.
    case refreshFailed
}

/// Auth state events emitted by `TokenManager`.
public enum AuthStateEvent: Sendable, Equatable {
    case sessionSet
    case sessionCleared(reason: SessionClearReason)
    case tokenRefreshed
}

public typealias AuthStateCallback = @Sendable (AuthStateEvent, Session?) -> Void

/// Returned by listener registration. Call to stop receiving events.
public typealias Unsubscribe = @Sendable () -> Void
