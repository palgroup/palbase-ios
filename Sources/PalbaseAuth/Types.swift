import Foundation
import PalbaseCore

public struct User: Sendable, Equatable, Codable {
    public let id: String
    public let email: String
    public let emailVerified: Bool
    public let createdAt: String
    public let updatedAt: String

    package init(id: String, email: String, emailVerified: Bool, createdAt: String, updatedAt: String) {
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

    package init(user: User, session: Session) {
        self.user = user
        self.session = session
    }
}

// MARK: - Internal request/response DTOs

struct SignUpCredentials: Encodable, Sendable {
    let email: String
    let password: String
}

struct SignInCredentials: Encodable, Sendable {
    let email: String
    let password: String
}

struct UserInfoDTO: Decodable, Sendable {
    let id: String
    let email: String
    let emailVerified: Bool
    let createdAt: String
}

struct UserResponseDTO: Decodable, Sendable {
    let user: UserInfoDTO

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

struct AuthResultDTO: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int
    let user: UserInfoDTO

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
