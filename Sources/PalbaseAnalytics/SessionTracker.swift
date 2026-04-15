import Foundation

/// Tracks the current analytics session id. A session resets when either:
///   - No capture has occurred in `inactivityTimeout` seconds, or
///   - `maxDuration` seconds have elapsed since session start.
///
/// `SessionTracker` is an `actor` so `touch()` can be called from any task
/// without racing on the identity-setter or the expiry check.
package actor SessionTracker {
    private var currentId: String?
    private var startedAt: Date?
    private var lastActivity: Date?

    private let inactivityTimeout: TimeInterval
    private let maxDuration: TimeInterval
    private let clock: @Sendable () -> Date

    package init(
        inactivityTimeout: TimeInterval = AnalyticsLimits.sessionInactivityTimeout,
        maxDuration: TimeInterval = AnalyticsLimits.sessionMaxDuration,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inactivityTimeout = inactivityTimeout
        self.maxDuration = maxDuration
        self.clock = clock
    }

    /// Return the current session id, rotating the session if it has expired.
    /// Also updates last-activity.
    package func touch() -> String {
        let now = clock()
        if shouldRotate(now: now) {
            rotate(now: now)
        } else {
            lastActivity = now
        }
        return currentId ?? {
            rotate(now: now)
            return currentId!
        }()
    }

    /// Current session id without rotating or updating activity.
    package func peek() -> String? { currentId }

    /// Force a new session id.
    package func reset() {
        currentId = nil
        startedAt = nil
        lastActivity = nil
    }

    /// Restore a persisted session (from UserDefaults hydration). Does not
    /// rotate; the next `touch()` call handles expiry.
    package func hydrate(id: String, startedAt: Date?, lastActivity: Date?) {
        self.currentId = id
        self.startedAt = startedAt
        self.lastActivity = lastActivity
    }

    /// Internal view for persistence hooks.
    package func snapshot() -> (id: String?, startedAt: Date?, lastActivity: Date?) {
        (currentId, startedAt, lastActivity)
    }

    private func shouldRotate(now: Date) -> Bool {
        guard currentId != nil, let startedAt, let lastActivity else { return true }
        if now.timeIntervalSince(lastActivity) >= inactivityTimeout { return true }
        if now.timeIntervalSince(startedAt) >= maxDuration { return true }
        return false
    }

    private func rotate(now: Date) {
        currentId = UUIDv7.string(now: now)
        startedAt = now
        lastActivity = now
    }
}
