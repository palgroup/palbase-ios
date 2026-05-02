import Foundation

package typealias RefreshFunction = @Sendable (String) async throws -> Session

package actor TokenManager {
    private let storage: TokenStorage
    private var cachedSession: Session?
    private var listeners: [UUID: AuthStateCallback] = [:]
    private var refreshTask: Task<Session, Error>?

    package var refreshFunction: RefreshFunction?

    // Boot is async (loadFromStorage + wireRefreshFunction run in a
    // detached Task spawned from configure()). Anything that needs
    // refresh-on-401 to actually fire must await this signal first;
    // otherwise the first request after configure() can race past the
    // hydration and find refreshFunction == nil → pre-flight skipped →
    // expired token sent → 401 with no recovery.
    private var bootContinuations: [CheckedContinuation<Void, Never>] = []
    private var isBootComplete = false

    package init(storage: TokenStorage = InMemoryTokenStorage()) {
        self.storage = storage
    }

    /// Hydrate from persistent storage. Call once at SDK startup.
    package func loadFromStorage() async {
        cachedSession = await storage.load()
    }

    /// Mark boot complete (storage hydrated + refresh function wired).
    /// Wakes everyone waiting in `waitUntilReady()`.
    package func markBootComplete() {
        guard !isBootComplete else { return }
        isBootComplete = true
        let pending = bootContinuations
        bootContinuations.removeAll()
        for cont in pending { cont.resume() }
    }

    /// Suspend until `markBootComplete` has been called. No-op if boot
    /// already finished. Used by HttpClient's pre-flight refresh check
    /// so the first request after `Palbase.configure()` blocks ~ms for
    /// keychain hydration instead of racing past with a stale token.
    package func waitUntilReady() async {
        if isBootComplete { return }
        await withCheckedContinuation { cont in
            bootContinuations.append(cont)
        }
    }

    package var accessToken: String? { cachedSession?.accessToken }
    package var refreshToken: String? { cachedSession?.refreshToken }
    package var currentSession: Session? { cachedSession }

    package var isExpired: Bool {
        guard let session = cachedSession else { return true }
        return session.isExpired
    }

    package func setSession(_ session: Session) async {
        cachedSession = session
        await storage.save(session)
        notify(.sessionSet, session)
    }

    package func clearSession(reason: SessionClearReason = .signOut) async {
        cachedSession = nil
        await storage.clear()
        notify(.sessionCleared(reason: reason), nil)
    }

    package func setRefreshFunction(_ fn: @escaping RefreshFunction) {
        self.refreshFunction = fn
    }

    /// Collapses concurrent refresh calls into a single in-flight task.
    ///
    /// On 4xx the server has decisively rejected the refresh_token (revoked,
    /// reused, expired beyond grace, account banned). The local session is
    /// then unrecoverable — clear it and emit `sessionCleared(.refreshFailed)`
    /// so the host app can route to login. Transient failures (5xx, network)
    /// leave the session intact so the next attempt can succeed.
    @discardableResult
    package func refreshSession() async throws -> Session {
        guard let refreshToken = cachedSession?.refreshToken,
              let fn = refreshFunction else {
            throw PalbaseCoreError.tokenRefreshFailed(message: "No refresh token or refresh function available")
        }

        if let existing = refreshTask {
            return try await existing.value
        }

        let task = Task<Session, Error> { [self] in
            defer { Task { await self.clearRefreshTask() } }
            do {
                let newSession = try await fn(refreshToken)
                await self.setSession(newSession)
                await self.fireRefreshed(newSession)
                return newSession
            } catch let err as PalbaseCoreError {
                if Self.isFatalRefreshError(err) {
                    await self.clearSession(reason: .refreshFailed)
                }
                throw err
            }
        }
        refreshTask = task

        return try await task.value
    }

    /// 4xx (other than 408 / 429) means the server has decisively rejected
    /// the refresh token. 5xx, network, decoding errors are transient.
    private static func isFatalRefreshError(_ err: PalbaseCoreError) -> Bool {
        switch err {
        case .http(let status, _, _, _):
            return (400..<500).contains(status) && status != 408 && status != 429
        case .rateLimited, .server, .network, .decoding, .encoding,
             .invalidConfiguration, .notConfigured, .tokenRefreshFailed:
            return false
        }
    }

    private func clearRefreshTask() {
        refreshTask = nil
    }

    private func fireRefreshed(_ session: Session) {
        notify(.tokenRefreshed, session)
    }

    /// Subscribe to auth state changes.
    /// > Warning: Capture `self` weakly in the closure to avoid retain cycles.
    @discardableResult
    package func onAuthStateChange(_ callback: @escaping AuthStateCallback) -> Unsubscribe {
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
