import Foundation
@_exported import PalbaseCore

// MARK: - Public domain types

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

/// Pending verification challenge after sign-up. Server may return a token (link)
/// and/or a code (for code-based verification).
public struct VerificationChallenge: Sendable {
    public let token: String?
    public let code: String?

    package init(token: String?, code: String?) {
        self.token = token
        self.code = code
    }
}

/// Common OAuth providers supported by Palbase. Use `.custom("name")` for others.
public enum OAuthProvider: Sendable, Equatable {
    case google
    case apple
    case github
    case microsoft
    case facebook
    case twitter
    case discord
    case slack
    case custom(String)

    public var name: String {
        switch self {
        case .google: return "google"
        case .apple: return "apple"
        case .github: return "github"
        case .microsoft: return "microsoft"
        case .facebook: return "facebook"
        case .twitter: return "twitter"
        case .discord: return "discord"
        case .slack: return "slack"
        case .custom(let s): return s
        }
    }
}

/// Linked identity for a user (Google, Apple, etc. account they signed in with).
public struct Identity: Sendable, Equatable, Codable {
    public let id: String
    public let provider: String
    public let providerUserId: String
    public let createdAt: String

    package init(id: String, provider: String, providerUserId: String, createdAt: String) {
        self.id = id
        self.provider = provider
        self.providerUserId = providerUserId
        self.createdAt = createdAt
    }
}

/// One active session for the current user.
public struct AuthSession: Sendable, Equatable, Codable {
    public let id: String
    public let ip: String?
    public let userAgent: String?
    public let lastActivity: String
    public let createdAt: String
    public let current: Bool

    package init(id: String, ip: String?, userAgent: String?, lastActivity: String, createdAt: String, current: Bool) {
        self.id = id
        self.ip = ip
        self.userAgent = userAgent
        self.lastActivity = lastActivity
        self.createdAt = createdAt
        self.current = current
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
    let verificationToken: String?
    let verificationCode: String?

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

    func toVerification() -> VerificationChallenge? {
        if verificationToken == nil && verificationCode == nil { return nil }
        return VerificationChallenge(token: verificationToken, code: verificationCode)
    }
}

struct TokenResponseDTO: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int

    func toSession() -> Session {
        let expiresAt = Int64(Date().timeIntervalSince1970) + Int64(expiresIn)
        return Session(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
    }
}

struct VerifyEmailBody: Encodable, Sendable {
    let token: String?
    let code: String?
    let email: String?
}

struct ResendVerificationBody: Encodable, Sendable {
    let email: String
}

struct VerificationResponseDTO: Decodable, Sendable {
    let verificationToken: String?
    let verificationCode: String?

    func toChallenge() -> VerificationChallenge {
        VerificationChallenge(token: verificationToken, code: verificationCode)
    }
}

struct PasswordResetBody: Encodable, Sendable {
    let email: String
}

struct PasswordResetConfirmBody: Encodable, Sendable {
    let token: String
    let newPassword: String
}

struct PasswordChangeBody: Encodable, Sendable {
    let currentPassword: String
    let newPassword: String
}

struct SuccessResponseDTO: Decodable, Sendable {
    let success: Bool
}

struct StatusResponseDTO: Decodable, Sendable {
    let status: String
}

struct MagicLinkBody: Encodable, Sendable {
    let email: String
    let redirectUrl: String?
}

struct MagicLinkVerifyBody: Encodable, Sendable {
    let token: String
}

struct AuthSessionListDTO: Decodable, Sendable {
    let sessions: [AuthSessionDTO]
}

struct OAuthURLResponseDTO: Decodable, Sendable {
    let url: String
}

struct CredentialExchangeBody: Encodable, Sendable {
    let provider: String
    let credential: String
    let nonce: String?
}

struct IdentityListDTO: Decodable, Sendable {
    let identities: [IdentityDTO]
}

struct IdentityDTO: Decodable, Sendable {
    let id: String
    let provider: String
    let providerUserId: String
    let createdAt: String

    func toIdentity() -> Identity {
        Identity(id: id, provider: provider, providerUserId: providerUserId, createdAt: createdAt)
    }
}

struct LinkIdentityBody: Encodable, Sendable {
    let provider: String
    let credential: String
}

struct AuthSessionDTO: Decodable, Sendable {
    let id: String
    let ip: String?
    let userAgent: String?
    let lastActivity: String
    let createdAt: String
    let current: Bool

    func toAuthSession() -> AuthSession {
        AuthSession(
            id: id,
            ip: ip,
            userAgent: userAgent,
            lastActivity: lastActivity,
            createdAt: createdAt,
            current: current
        )
    }
}
