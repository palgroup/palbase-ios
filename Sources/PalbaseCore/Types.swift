import Foundation

public struct PalbaseResponse<T: Sendable>: Sendable {
    public let data: T?
    public let error: PalbaseError?
    public let status: Int
    public let count: Int?

    public init(data: T? = nil, error: PalbaseError? = nil, status: Int = 0, count: Int? = nil) {
        self.data = data
        self.error = error
        self.status = status
        self.count = count
    }
}

public struct PalbaseConfig: Sendable {
    public let apiKey: String
    public let url: String?
    public let headers: [String: String]

    public init(apiKey: String, url: String? = nil, headers: [String: String] = [:]) {
        self.apiKey = apiKey
        self.url = url
        self.headers = headers
    }
}

public struct Session: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Int64

    public init(accessToken: String, refreshToken: String, expiresAt: Int64) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        let now = Int64(Date().timeIntervalSince1970)
        return now >= expiresAt
    }
}

public enum AuthStateEvent: Sendable {
    case sessionSet
    case sessionCleared
    case tokenRefreshed
}

public typealias AuthStateCallback = @Sendable (AuthStateEvent, Session?) -> Void
public typealias Unsubscribe = @Sendable () -> Void
