import Foundation

public typealias RefreshFunction = @Sendable (String) async throws -> Session

public actor TokenManager {
    private var session: Session?
    private var listeners: [UUID: AuthStateCallback] = [:]
    private var refreshTask: Task<Session, Error>?

    public var refreshFunction: RefreshFunction?

    public init() {}

    public var accessToken: String? { session?.accessToken }
    public var refreshToken: String? { session?.refreshToken }
    public var currentSession: Session? { session }

    public var isExpired: Bool {
        guard let session = session else { return true }
        return session.isExpired
    }

    public func setSession(_ session: Session) {
        self.session = session
        notify(.sessionSet, session)
    }

    public func clearSession() {
        session = nil
        notify(.sessionCleared, nil)
    }

    public func setRefreshFunction(_ fn: @escaping RefreshFunction) {
        self.refreshFunction = fn
    }

    /// Collapses concurrent refresh calls into one in-flight task.
    @discardableResult
    public func refreshSession() async throws -> Session {
        guard let refreshToken = session?.refreshToken,
              let fn = refreshFunction else {
            throw PalbaseError(code: "no_refresh_token", message: "No refresh token or refresh function available")
        }

        if let existing = refreshTask {
            return try await existing.value
        }

        let task = Task<Session, Error> {
            defer { refreshTask = nil }
            let newSession = try await fn(refreshToken)
            setSession(newSession)
            notify(.tokenRefreshed, newSession)
            return newSession
        }
        refreshTask = task

        return try await task.value
    }

    /// Subscribe to auth state changes. Returns an `Unsubscribe` closure that
    /// you must call to stop receiving events.
    ///
    /// > Warning: When referencing `self` inside the closure, capture weakly
    /// > to avoid retain cycles:
    /// > ```swift
    /// > await client.tokens.onAuthStateChange { [weak self] event, session in
    /// >     self?.handleAuth(event, session)
    /// > }
    /// > ```
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

    internal var listenersCountForTesting: Int {
        listeners.count
    }

    // MARK: - Private

    private func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    private func notify(_ event: AuthStateEvent, _ session: Session?) {
        for listener in listeners.values {
            listener(event, session)
        }
    }
}
