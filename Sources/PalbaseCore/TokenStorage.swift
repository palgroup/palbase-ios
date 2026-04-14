import Foundation

/// Persists `Session` across app launches. Implementations: `InMemoryTokenStorage`,
/// `KeychainTokenStorage` (production).
public protocol TokenStorage: Sendable {
    func load() async -> Session?
    func save(_ session: Session) async
    func clear() async
}

/// In-memory storage. Sessions lost on app termination. Use for tests.
public actor InMemoryTokenStorage: TokenStorage {
    private var session: Session?

    public init() {}

    public func load() async -> Session? { session }
    public func save(_ session: Session) async { self.session = session }
    public func clear() async { self.session = nil }
}
