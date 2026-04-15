import Foundation
@_exported import PalbaseCore
import PalbaseRealtime

/// Palbase Flags module entry point. Use `PalbaseFlags.shared` after
/// `Palbase.configure(_:)`.
///
/// ```swift
/// try await PalbaseFlags.shared.start()
///
/// if await PalbaseFlags.shared.bool("ai_features", default: false) {
///     // ...
/// }
///
/// let unsub = await PalbaseFlags.shared.onChange(key: "max_upload_mb") { value in
///     print("new limit: \(value?.intValue ?? 0)")
/// }
/// ```
///
/// Flags are fetched as a merged snapshot from `GET /v1/user-flags` and kept
/// in sync via two realtime channels (user override + project-wide system
/// flags). A previously persisted snapshot is loaded from `UserDefaults`
/// before the network fetch (stale-while-revalidate) so the first read after
/// launch never blocks on the network.
public actor PalbaseFlags {
    private let http: HTTPRequesting
    private let tokens: TokenManager
    private let storage: FlagsStorage
    private let realtimeFactory: @Sendable () async throws(FlagsError) -> FlagsRealtimeSubscribing
    private let apiKey: String
    private let clock: @Sendable () -> Date
    private let userIdProvider: @Sendable (TokenManager) async -> String?

    private var cache: [String: FlagValue] = [:]
    private var _lastFetchedAt: Date?
    private var listeners: [UUID: Listener] = [:]
    private var keyedListeners: [UUID: KeyedListener] = [:]
    private var realtime: FlagsRealtimeSubscribing?
    private var _isStarted: Bool = false
    private var hydratedProjectRef: String?
    private var hydratedUserId: String?

    private struct Listener: Sendable {
        let handler: @Sendable (String, FlagValue?) -> Void
    }

    private struct KeyedListener: Sendable {
        let key: String
        let handler: @Sendable (FlagValue?) -> Void
    }

    package init(
        http: HTTPRequesting,
        tokens: TokenManager,
        apiKey: String,
        storage: FlagsStorage = UserDefaultsFlagsStorage(),
        realtimeFactory: @escaping @Sendable () async throws(FlagsError) -> FlagsRealtimeSubscribing,
        clock: @escaping @Sendable () -> Date = { Date() },
        userIdProvider: @escaping @Sendable (TokenManager) async -> String? = { await defaultUserIdProvider($0) }
    ) {
        self.http = http
        self.tokens = tokens
        self.apiKey = apiKey
        self.storage = storage
        self.realtimeFactory = realtimeFactory
        self.clock = clock
        self.userIdProvider = userIdProvider
    }

    /// Shared Flags client backed by the global SDK configuration.
    public static var shared: PalbaseFlags {
        get throws(FlagsError) {
            guard let http = Palbase.http,
                  let tokens = Palbase.tokens,
                  let cfg = Palbase.config else {
                throw FlagsError.notConfigured
            }
            return FlagsClientCache.getOrCreate(http: http, tokens: tokens, apiKey: cfg.apiKey)
        }
    }

    // MARK: - Lifecycle

    /// Load the persisted snapshot, fetch the latest values from the server,
    /// and subscribe to realtime updates. Safe to call multiple times —
    /// already-subscribed channels are reused.
    public func start() async throws(FlagsError) {
        let userId = await userIdProvider(tokens)
        guard let userId else { throw .noActiveSession }
        guard let projectRef = parseProjectRef(apiKey) else {
            throw .network("Invalid API key format. Expected: pb_{ref}_{random}.")
        }

        // Hydrate from persisted snapshot first (stale-while-revalidate).
        if hydratedProjectRef != projectRef || hydratedUserId != userId {
            if let cached = storage.loadSnapshot(projectRef: projectRef, userId: userId) {
                cache = cached.values
                _lastFetchedAt = cached.fetchedAt
            }
            hydratedProjectRef = projectRef
            hydratedUserId = userId
        }

        // Initial fetch — treat failure as soft (cache still usable), but
        // propagate so the caller can decide.
        _ = try await fetchInternal(projectRef: projectRef, userId: userId)

        if realtime == nil {
            let subscriber = try await realtimeFactory()
            do {
                try await subscriber.subscribe(
                    projectRef: projectRef,
                    userId: userId,
                    onEvent: { [weak self] event in
                        guard let self else { return }
                        Task { await self.handle(event) }
                    },
                    onReconnect: { [weak self] in
                        guard let self else { return }
                        Task {
                            _ = try? await self.fetchInternal(projectRef: projectRef, userId: userId)
                        }
                    }
                )
            } catch {
                throw error
            }
            realtime = subscriber
        }

        _isStarted = true
    }

    /// Unsubscribe from realtime but keep the cache intact. Call when putting
    /// the SDK in the background for an extended period.
    public func stop() async {
        if let realtime { await realtime.unsubscribe() }
        realtime = nil
        _isStarted = false
    }

    /// Wipe the in-memory cache and persisted snapshot. Call this on sign-out
    /// so a new user doesn't see the previous user's overrides.
    public func clear() async {
        cache.removeAll()
        _lastFetchedAt = nil
        if let ref = hydratedProjectRef, let uid = hydratedUserId {
            storage.deleteSnapshot(projectRef: ref, userId: uid)
        }
        hydratedProjectRef = nil
        hydratedUserId = nil
        if let realtime { await realtime.unsubscribe() }
        realtime = nil
        _isStarted = false
    }

    public var isStarted: Bool { _isStarted }
    public var lastFetchedAt: Date? { _lastFetchedAt }

    // MARK: - Fetch

    /// Fetch the latest merged snapshot from the server, update the cache,
    /// persist it, and notify listeners about any changed keys. Can be called
    /// without `start()` — used standalone for one-off reads.
    @discardableResult
    public func fetch() async throws(FlagsError) -> FlagsSnapshot {
        let userId = await userIdProvider(tokens)
        guard let userId else { throw .noActiveSession }
        guard let projectRef = parseProjectRef(apiKey) else {
            throw .network("Invalid API key format. Expected: pb_{ref}_{random}.")
        }
        return try await fetchInternal(projectRef: projectRef, userId: userId)
    }

    private func fetchInternal(projectRef: String, userId: String) async throws(FlagsError) -> FlagsSnapshot {
        let (data, _): (Data, Int)
        do {
            (data, _) = try await http.requestRaw(method: "GET", path: "/v1/user-flags", body: nil, headers: [:])
        } catch {
            throw FlagsError.from(transport: error)
        }

        let snapshot: FlagsSnapshot
        do {
            snapshot = try JSONDecoder().decode(FlagsSnapshot.self, from: data)
        } catch {
            throw .decoding(error.localizedDescription)
        }

        applySnapshot(snapshot)
        storage.saveSnapshot(snapshot, projectRef: projectRef, userId: userId)
        return snapshot
    }

    private func applySnapshot(_ snapshot: FlagsSnapshot) {
        var changed: [(String, FlagValue?)] = []
        // Detect additions/changes.
        for (key, value) in snapshot.values {
            if cache[key] != value {
                changed.append((key, value))
            }
        }
        // Detect deletions.
        for key in cache.keys where snapshot.values[key] == nil {
            changed.append((key, nil))
        }
        cache = snapshot.values
        _lastFetchedAt = snapshot.fetchedAt
        for (key, value) in changed {
            notifyChange(key: key, value: value)
        }
    }

    // MARK: - Read

    /// Read a flag value from the local cache. Returns `nil` if the key has
    /// never been fetched.
    public func value(for key: String) -> FlagValue? {
        cache[key]
    }

    /// Snapshot of every cached flag.
    public func all() -> [String: FlagValue] {
        cache
    }

    // MARK: - Typed accessors (optional)

    public func bool(_ key: String) -> Bool? { cache[key]?.boolValue }
    public func string(_ key: String) -> String? { cache[key]?.stringValue }
    public func int(_ key: String) -> Int? { cache[key]?.intValue }
    public func double(_ key: String) -> Double? { cache[key]?.doubleValue }
    public func object(_ key: String) -> [String: FlagValue]? { cache[key]?.objectValue }
    public func array(_ key: String) -> [FlagValue]? { cache[key]?.arrayValue }

    // MARK: - Typed accessors (with defaults)

    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        cache[key]?.boolValue ?? defaultValue
    }

    public func string(_ key: String, default defaultValue: String) -> String {
        cache[key]?.stringValue ?? defaultValue
    }

    public func int(_ key: String, default defaultValue: Int) -> Int {
        cache[key]?.intValue ?? defaultValue
    }

    public func double(_ key: String, default defaultValue: Double) -> Double {
        cache[key]?.doubleValue ?? defaultValue
    }

    // MARK: - Listeners

    /// Subscribe to every flag change. Fires with `(key, value)` for
    /// additions/updates and `(key, nil)` for deletions.
    @discardableResult
    public func onChange(_ handler: @escaping @Sendable (String, FlagValue?) -> Void) -> Unsubscribe {
        let id = UUID()
        listeners[id] = Listener(handler: handler)
        return { [weak self] in
            guard let self else { return }
            Task { await self.removeListener(id) }
        }
    }

    /// Subscribe to changes for a single key. Fires whenever that key is
    /// added, updated, or deleted.
    @discardableResult
    public func onChange(
        key: String,
        handler: @escaping @Sendable (FlagValue?) -> Void
    ) -> Unsubscribe {
        let id = UUID()
        keyedListeners[id] = KeyedListener(key: key, handler: handler)
        return { [weak self] in
            guard let self else { return }
            Task { await self.removeKeyedListener(id) }
        }
    }

    private func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    private func removeKeyedListener(_ id: UUID) {
        keyedListeners.removeValue(forKey: id)
    }

    // MARK: - Realtime event handling

    private func handle(_ event: FlagsRealtimeEvent) async {
        switch event {
        case .userFlagChanged(let key, let value):
            setValue(key: key, value: value)
        case .userFlagDeleted(let key, let systemValue):
            if let systemValue {
                setValue(key: key, value: systemValue)
            } else {
                removeValue(key: key)
            }
        case .systemFlagChanged(let key, let value):
            // Client can't locally distinguish override vs default; applying
            // the new value is documented as safe.
            setValue(key: key, value: value)
        case .systemFlagDeleted(let key):
            removeValue(key: key)
        }
        persistCurrentCache()
    }

    private func setValue(key: String, value: FlagValue) {
        let previous = cache[key]
        cache[key] = value
        if previous != value {
            notifyChange(key: key, value: value)
        }
    }

    private func removeValue(key: String) {
        guard cache.removeValue(forKey: key) != nil else { return }
        notifyChange(key: key, value: nil)
    }

    private func notifyChange(key: String, value: FlagValue?) {
        for l in listeners.values { l.handler(key, value) }
        for l in keyedListeners.values where l.key == key { l.handler(value) }
    }

    private func persistCurrentCache() {
        guard let ref = hydratedProjectRef, let uid = hydratedUserId else { return }
        let snapshot = FlagsSnapshot(values: cache, fetchedAt: _lastFetchedAt ?? clock())
        storage.saveSnapshot(snapshot, projectRef: ref, userId: uid)
    }

    // MARK: - Test inspection

    package func _listenerCount() -> Int { listeners.count + keyedListeners.count }
    package func _setCacheForTesting(_ values: [String: FlagValue]) { self.cache = values }
}

// MARK: - Singleton cache

final class FlagsClientCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: PalbaseFlags?

    private static let instance = FlagsClientCache()

    static func getOrCreate(http: HTTPRequesting, tokens: TokenManager, apiKey: String) -> PalbaseFlags {
        instance.getOrCreate(http: http, tokens: tokens, apiKey: apiKey)
    }

    /// Test-only: drop the cached client.
    package static func _resetForTesting() {
        instance.lock.lock(); defer { instance.lock.unlock() }
        instance.cached = nil
    }

    private func getOrCreate(http: HTTPRequesting, tokens: TokenManager, apiKey: String) -> PalbaseFlags {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let client = PalbaseFlags(
            http: http,
            tokens: tokens,
            apiKey: apiKey,
            realtimeFactory: sharedRealtimeFactory
        )
        cached = client
        return client
    }
}

@Sendable
private func sharedRealtimeFactory() async throws(FlagsError) -> FlagsRealtimeSubscribing {
    guard let realtime = try? PalbaseRealtime.shared else {
        throw FlagsError.notConfigured
    }
    return DefaultFlagsRealtimeSubscriber(realtime: realtime)
}

// MARK: - API key parsing

package func parseProjectRef(_ apiKey: String) -> String? {
    let parts = apiKey.split(separator: "_")
    guard parts.count >= 3, parts[0] == "pb" else { return nil }
    return String(parts[1])
}

// MARK: - JWT user id extraction

/// Default provider pulls the user id from the `sub` claim of the current
/// access token.
package func defaultUserIdProvider(_ tokens: TokenManager) async -> String? {
    guard let token = await tokens.accessToken else { return nil }
    return JWTSubjectExtractor.subject(from: token)
}

package enum JWTSubjectExtractor {
    /// Return the `sub` claim from a JWT, or `nil` if parsing fails.
    package static func subject(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payload = String(parts[1])
        guard let data = base64URLDecode(payload) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["sub"] as? String
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var normalized = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: normalized)
    }
}
