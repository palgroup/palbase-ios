import Foundation

public typealias RefreshFunction = @Sendable (String) async throws -> Session

package actor TokenManager {
    private let storage: TokenStorage
    private var cachedSession: Session?
    private var listeners: [UUID: AuthStateCallback] = [:]
    private var refreshTask: Task<Session, Error>?

    package var refreshFunction: RefreshFunction?

    package init(storage: TokenStorage = InMemoryTokenStorage()) {
        self.storage = storage
    }

    /// Hydrate from persistent storage. Call once at SDK startup.
    public func loadFromStorage() async {
        cachedSession = await storage.load()
    }

    public var accessToken: String? { cachedSession?.accessToken }
    public var refreshToken: String? { cachedSession?.refreshToken }
    public var currentSession: Session? { cachedSession }

    public var isExpired: Bool {
        guard let session = cachedSession else { return true }
        return session.isExpired
    }

    public func setSession(_ session: Session) async {
        cachedSession = session
        await storage.save(session)
        notify(.sessionSet, session)
    }

    public func clearSession() async {
        cachedSession = nil
        await storage.clear()
        notify(.sessionCleared, nil)
    }

    public func setRefreshFunction(_ fn: @escaping RefreshFunction) {
        self.refreshFunction = fn
    }

    /// Collapses concurrent refresh calls into a single in-flight task.
    @discardableResult
    public func refreshSession() async throws -> Session {
        guard let refreshToken = cachedSession?.refreshToken,
              let fn = refreshFunction else {
            throw PalbaseCoreError.tokenRefreshFailed(message: "No refresh token or refresh function available")
        }

        if let existing = refreshTask {
            return try await existing.value
        }

        let task = Task<Session, Error> {
            defer { refreshTask = nil }
            let newSession = try await fn(refreshToken)
            await setSession(newSession)
            notify(.tokenRefreshed, newSession)
            return newSession
        }
        refreshTask = task

        return try await task.value
    }

    /// Subscribe to auth state changes.
    /// > Warning: Capture `self` weakly in the closure to avoid retain cycles.
    @discardableResult
    public func onAuthStateChange(_ callback: @escaping AuthStateCallback) -> Unsubscribe {
        let id = UUID()
        listeners[id] = callback
        return { [weak self] in
            guard let self else { return }
            Task { await self.removeListener(id) }
        }
    }

    // MARK: - Internal (testing)

    var listenersCountForTesting: Int { listeners.count }

    private func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    private func notify(_ event: AuthStateEvent, _ session: Session?) {
        for listener in listeners.values {
            listener(event, session)
        }
    }
}
