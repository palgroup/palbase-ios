import Foundation

/// Persistent state for the Analytics module: distinct_id + opt-out flag.
/// Session state lives in memory only — it needs to rotate on launch anyway.
package protocol AnalyticsStorage: Sendable {
    func loadDistinctId() -> String?
    func saveDistinctId(_ id: String)
    func loadOptOut() -> Bool
    func saveOptOut(_ optedOut: Bool)
}

/// Default implementation backed by `UserDefaults.standard`.
///
/// `UserDefaults` is thread-safe but not `Sendable`; mark as
/// `nonisolated(unsafe)` so the wrapping struct can be `Sendable`.
package struct UserDefaultsAnalyticsStorage: AnalyticsStorage {
    nonisolated(unsafe) private let defaults: UserDefaults
    private let distinctIdKey = "com.palbase.analytics.distinct_id"
    private let optOutKey = "com.palbase.analytics.opted_out"

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package func loadDistinctId() -> String? {
        defaults.string(forKey: distinctIdKey)
    }

    package func saveDistinctId(_ id: String) {
        defaults.set(id, forKey: distinctIdKey)
    }

    package func loadOptOut() -> Bool {
        defaults.bool(forKey: optOutKey)
    }

    package func saveOptOut(_ optedOut: Bool) {
        defaults.set(optedOut, forKey: optOutKey)
    }
}

/// In-memory storage for tests.
package final class InMemoryAnalyticsStorage: AnalyticsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var distinctId: String?
    private var optedOut: Bool = false

    package init(distinctId: String? = nil, optedOut: Bool = false) {
        self.distinctId = distinctId
        self.optedOut = optedOut
    }

    package func loadDistinctId() -> String? {
        lock.lock(); defer { lock.unlock() }
        return distinctId
    }

    package func saveDistinctId(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        distinctId = id
    }

    package func loadOptOut() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return optedOut
    }

    package func saveOptOut(_ optedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.optedOut = optedOut
    }
}
