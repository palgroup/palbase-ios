import Foundation
import PalbaseCore

public struct User: Sendable, Equatable, Codable {
    public let id: String
    public let email: String
    public let emailVerified: Bool
    public let createdAt: String
    public let updatedAt: String

    public init(id: String, email: String, emailVerified: Bool, createdAt: String, updatedAt: String) {
        self.id = id
        self.email = email
        self.emailVerified = emailVerified
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AuthSuccess: Sendable {
    public let user: User
    public let session: Session
}

public struct SignUpCredentials: Sendable, Codable {
    public let email: String
    public let password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

public struct SignInCredentials: Sendable, Codable {
    public let email: String
    public let password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

// MARK: - Internal wire format

struct UserInfoDTO: Decodable {
    let id: String
    let email: String
    let emailVerified: Bool
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, email
        case emailVerified = "email_verified"
        case createdAt = "created_at"
    }
}

struct AuthResultDTO: Decodable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int
    let user: UserInfoDTO

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case user
    }

    func toSession() -> Session {
        let expiresAt = Int64(Date().timeIntervalSince1970) + Int64(expiresIn)
        return Session(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
    }

    func toUser() -> User {
        User(
            id: user.id,
            email: user.email,
            emailVerified: user.emailVerified,
            createdAt: user.createdAt,
            updatedAt: user.createdAt
        )
    }
}
