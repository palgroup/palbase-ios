import Foundation

/// Persistent storage for the last-seen flags snapshot keyed by
/// `(project_ref, user_id)`. Used for stale-while-revalidate hydration.
package protocol FlagsStorage: Sendable {
    func loadSnapshot(projectRef: String, userId: String) -> FlagsSnapshot?
    func saveSnapshot(_ snapshot: FlagsSnapshot, projectRef: String, userId: String)
    func deleteSnapshot(projectRef: String, userId: String)
}

/// Default implementation backed by `UserDefaults.standard`.
///
/// `UserDefaults` is thread-safe but not `Sendable`; mark as
/// `nonisolated(unsafe)` so the wrapping struct can be `Sendable`.
package struct UserDefaultsFlagsStorage: FlagsStorage {
    nonisolated(unsafe) private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(projectRef: String, userId: String) -> String {
        "palbase.flags.snapshot.\(projectRef).\(userId)"
    }

    package func loadSnapshot(projectRef: String, userId: String) -> FlagsSnapshot? {
        guard let data = defaults.data(forKey: key(projectRef: projectRef, userId: userId)) else {
            return nil
        }
        return try? JSONDecoder().decode(FlagsSnapshot.self, from: data)
    }

    package func saveSnapshot(_ snapshot: FlagsSnapshot, projectRef: String, userId: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key(projectRef: projectRef, userId: userId))
    }

    package func deleteSnapshot(projectRef: String, userId: String) {
        defaults.removeObject(forKey: key(projectRef: projectRef, userId: userId))
    }
}

/// In-memory storage for tests.
package final class InMemoryFlagsStorage: FlagsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: FlagsSnapshot] = [:]

    package init() {}

    private func key(projectRef: String, userId: String) -> String {
        "\(projectRef).\(userId)"
    }

    package func loadSnapshot(projectRef: String, userId: String) -> FlagsSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshots[key(projectRef: projectRef, userId: userId)]
    }

    package func saveSnapshot(_ snapshot: FlagsSnapshot, projectRef: String, userId: String) {
        lock.lock(); defer { lock.unlock() }
        snapshots[key(projectRef: projectRef, userId: userId)] = snapshot
    }

    package func deleteSnapshot(projectRef: String, userId: String) {
        lock.lock(); defer { lock.unlock() }
        snapshots.removeValue(forKey: key(projectRef: projectRef, userId: userId))
    }

    package func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return snapshots.count
    }
}
