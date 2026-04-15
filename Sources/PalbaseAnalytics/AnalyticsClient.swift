import Foundation
@_exported import PalbaseCore

/// Palbase Analytics module entry point. Use `PalbaseAnalytics.shared` after
/// `Palbase.configure(_:)`.
///
/// ```swift
/// await PalbaseAnalytics.shared.capture("purchase", properties: [
///     "amount": 99.99,
///     "currency": "USD"
/// ])
/// ```
///
/// Events are **queued locally** (file-backed NDJSON) and flushed in batches
/// every 10 seconds, or immediately when the queue reaches 50 events. Calling
/// `capture` never blocks the caller and never throws — failures are retried
/// with exponential backoff. Use `flush()` to observe errors explicitly.
public actor PalbaseAnalytics {
    private let http: HTTPRequesting
    private let tokens: TokenManager
    private let storage: AnalyticsStorage
    private let queue: EventQueue
    private let session: SessionTracker
    private let flusher: Flusher
    private let clock: @Sendable () -> Date
    private let appVersion: String?

    private var distinctId: String
    private var optedOut: Bool
    private var autoFlushStarted: Bool = false

    package init(
        http: HTTPRequesting,
        tokens: TokenManager,
        storage: AnalyticsStorage = UserDefaultsAnalyticsStorage(),
        queue: EventQueue = EventQueue(),
        session: SessionTracker = SessionTracker(),
        flusher: Flusher? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    ) {
        self.http = http
        self.tokens = tokens
        self.storage = storage
        self.queue = queue
        self.session = session
        self.flusher = flusher ?? Flusher(http: http, queue: queue, clock: clock)
        self.clock = clock
        self.appVersion = appVersion

        // Hydrate identity + opt-out flag from persistent storage.
        self.distinctId = storage.loadDistinctId() ?? UUIDv7.string()
        self.optedOut = storage.loadOptOut()
        storage.saveDistinctId(self.distinctId)
    }

    /// Shared Analytics client backed by the global SDK configuration.
    /// Throws `AnalyticsError.notConfigured` if `Palbase.configure(_:)` was not called.
    public static var shared: PalbaseAnalytics {
        get throws(AnalyticsError) {
            guard let http = Palbase.http, let tokens = Palbase.tokens else {
                throw AnalyticsError.notConfigured
            }
            return AnalyticsClientCache.getOrCreate(http: http, tokens: tokens)
        }
    }

    // MARK: - Capture

    /// Queue a custom event for delivery. Fire-and-forget — invalid events
    /// are silently dropped (logged to stderr) so analytics failures can't
    /// crash user flows.
    public func capture(_ event: String, properties: [String: AnalyticsValue]? = nil) async {
        guard !optedOut else { return }
        do {
            try EventNameValidator.validate(event)
        } catch {
            logDrop("invalid event name: \(event)")
            return
        }
        let sid = await session.touch()
        let queued = QueuedEvent(
            eventId: UUIDv7.string(now: clock()),
            event: event,
            endpoint: .capture,
            distinctId: distinctId,
            properties: properties,
            traits: nil,
            alias: nil,
            screenName: nil,
            pageURL: nil,
            pageTitle: nil,
            timestampMs: Int64(clock().timeIntervalSince1970 * 1000),
            sessionId: sid,
            appVersion: appVersion
        )
        guard validateSize(queued) else { return }
        await queue.append(queued)
        ensureAutoFlushRunning()
        await triggerIfThresholdCrossed()
    }

    /// Capture a mobile screen view. Equivalent to `capture("$screen", ...)`
    /// with `$screen_name` in properties.
    public func screen(_ name: String, properties: [String: AnalyticsValue]? = nil) async {
        guard !optedOut else { return }
        let sid = await session.touch()
        let queued = QueuedEvent(
            eventId: UUIDv7.string(now: clock()),
            event: "$screen",
            endpoint: .screen,
            distinctId: distinctId,
            properties: properties,
            traits: nil,
            alias: nil,
            screenName: name,
            pageURL: nil,
            pageTitle: nil,
            timestampMs: Int64(clock().timeIntervalSince1970 * 1000),
            sessionId: sid,
            appVersion: appVersion
        )
        guard validateSize(queued) else { return }
        await queue.append(queued)
        ensureAutoFlushRunning()
        await triggerIfThresholdCrossed()
    }

    /// Capture a web page view. Equivalent to `capture("$pageview", ...)`.
    public func page(url: String, title: String? = nil, properties: [String: AnalyticsValue]? = nil) async {
        guard !optedOut else { return }
        let sid = await session.touch()
        let queued = QueuedEvent(
            eventId: UUIDv7.string(now: clock()),
            event: "$pageview",
            endpoint: .page,
            distinctId: distinctId,
            properties: properties,
            traits: nil,
            alias: nil,
            screenName: nil,
            pageURL: url,
            pageTitle: title,
            timestampMs: Int64(clock().timeIntervalSince1970 * 1000),
            sessionId: sid,
            appVersion: appVersion
        )
        guard validateSize(queued) else { return }
        await queue.append(queued)
        ensureAutoFlushRunning()
        await triggerIfThresholdCrossed()
    }

    // MARK: - Identity

    /// Associate subsequent events with a specific user. Updates the current
    /// `distinct_id` and enqueues a `$identify` event carrying the traits.
    public func identify(distinctId: String, traits: [String: AnalyticsValue]? = nil) async {
        guard !optedOut else { return }
        self.distinctId = distinctId
        storage.saveDistinctId(distinctId)
        let queued = QueuedEvent(
            eventId: UUIDv7.string(now: clock()),
            event: "$identify",
            endpoint: .identify,
            distinctId: distinctId,
            properties: nil,
            traits: traits,
            alias: nil,
            screenName: nil,
            pageURL: nil,
            pageTitle: nil,
            timestampMs: Int64(clock().timeIntervalSince1970 * 1000),
            sessionId: await session.peek(),
            appVersion: appVersion
        )
        guard validateSize(queued) else { return }
        await queue.append(queued)
        ensureAutoFlushRunning()
        await triggerIfThresholdCrossed()
    }

    /// Link two distinct_ids. Useful when a user signs in from an anonymous
    /// session — subsequent queries merge the two histories.
    public func alias(from: String, to: String) async {
        guard !optedOut else { return }
        let queued = QueuedEvent(
            eventId: UUIDv7.string(now: clock()),
            event: "$create_alias",
            endpoint: .alias,
            distinctId: to,
            properties: nil,
            traits: nil,
            alias: QueuedEvent.AliasFields(from: from, to: to),
            screenName: nil,
            pageURL: nil,
            pageTitle: nil,
            timestampMs: Int64(clock().timeIntervalSince1970 * 1000),
            sessionId: await session.peek(),
            appVersion: appVersion
        )
        guard validateSize(queued) else { return }
        await queue.append(queued)
        ensureAutoFlushRunning()
        await triggerIfThresholdCrossed()
    }

    // MARK: - Session

    /// Current session id. Rotates on first access if the SDK has no active
    /// session (post-`reset()` or fresh install).
    public var sessionId: String {
        get async { await session.touch() }
    }

    /// Force a new session id immediately.
    public func resetSession() async {
        await session.reset()
    }

    /// Clear identity and session. Call on sign-out. Does **not** clear the
    /// queued events pending flush — in-flight analytics for the signed-out
    /// session still deliver under the previous distinct_id.
    public func reset() async {
        await session.reset()
        self.distinctId = UUIDv7.string()
        storage.saveDistinctId(self.distinctId)
    }

    // MARK: - Queue control

    /// Force an immediate flush of the local queue. Throws if any batch fails.
    public func flush() async throws(AnalyticsError) {
        _ = try await flusher.flushOnce()
    }

    /// Ensure the auto-flush timer is running. Idempotent; called by every
    /// capture. Public for documentation / manual restart after `stopAutoFlush()`.
    public func startAutoFlush() {
        ensureAutoFlushRunning()
    }

    /// Stop the auto-flush timer. Pending events remain on disk until
    /// `startAutoFlush()` or `flush()` is called again.
    public func stopAutoFlush() async {
        await flusher.stop()
        autoFlushStarted = false
    }

    // MARK: - GDPR opt-out

    /// Stop capturing events and clear any pending queue. Persists across
    /// launches.
    public func optOut() async {
        optedOut = true
        storage.saveOptOut(true)
        await queue.clear()
        await flusher.stop()
        autoFlushStarted = false
    }

    /// Resume capture for a previously opted-out user. Auto-flush restarts on
    /// the next capture.
    public func optIn() async {
        optedOut = false
        storage.saveOptOut(false)
    }

    /// Current opt-out state.
    public var isOptedOut: Bool {
        get async { optedOut }
    }

    // MARK: - Internal helpers

    private func ensureAutoFlushRunning() {
        guard !optedOut, !autoFlushStarted else { return }
        autoFlushStarted = true
        let flusherRef = flusher
        Task { await flusherRef.start() }
    }

    private func clearAutoFlushFlag() {
        autoFlushStarted = false
    }

    private func triggerIfThresholdCrossed() async {
        let count = await queue.count()
        if count >= AnalyticsLimits.autoFlushThreshold {
            let flusherRef = flusher
            Task { _ = try? await flusherRef.flushOnce() }
        }
    }

    private func validateSize(_ event: QueuedEvent) -> Bool {
        guard let data = try? JSONEncoder.palbaseDefault.encode(event) else {
            logDrop("event encoding failed: \(event.event)")
            return false
        }
        if data.count > AnalyticsLimits.maxEventBytes {
            logDrop("event \(event.event) exceeds \(AnalyticsLimits.maxEventBytes) bytes")
            return false
        }
        return true
    }

    private func logDrop(_ reason: String) {
        FileHandle.standardError.write(Data("[PalbaseAnalytics] dropped: \(reason)\n".utf8))
    }

    // MARK: - Test inspection

    package func _currentDistinctId() -> String { distinctId }
    package func _autoFlushEnabled() -> Bool { autoFlushStarted }
}

// MARK: - Singleton cache

/// Caches a single `PalbaseAnalytics` per (apiKey) pair — important so that
/// the auto-flush timer, queue, and session tracker are shared across
/// `.shared` calls rather than recreated.
final class AnalyticsClientCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: PalbaseAnalytics?

    private static let instance = AnalyticsClientCache()

    static func getOrCreate(http: HTTPRequesting, tokens: TokenManager) -> PalbaseAnalytics {
        instance.getOrCreate(http: http, tokens: tokens)
    }

    /// Test-only: drop the cached client.
    package static func _resetForTesting() {
        instance.lock.lock(); defer { instance.lock.unlock() }
        instance.cached = nil
    }

    private func getOrCreate(http: HTTPRequesting, tokens: TokenManager) -> PalbaseAnalytics {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let client = PalbaseAnalytics(http: http, tokens: tokens)
        cached = client
        return client
    }
}
