import Foundation
import Testing
@testable import PalbaseFlags

@Suite("FlagsStorage — InMemory")
struct InMemoryFlagsStorageTests {
    private func makeSnapshot(_ values: [String: FlagValue] = ["k": .int(1)]) -> FlagsSnapshot {
        FlagsSnapshot(values: values, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func saveAndLoadRoundTrip() {
        let store = InMemoryFlagsStorage()
        let snap = makeSnapshot()
        store.saveSnapshot(snap, projectRef: "abc", userId: "u1")
        let loaded = store.loadSnapshot(projectRef: "abc", userId: "u1")
        #expect(loaded?.values["k"] == .int(1))
        #expect(loaded?.fetchedAt == snap.fetchedAt)
    }

    @Test func deleteRemovesEntry() {
        let store = InMemoryFlagsStorage()
        store.saveSnapshot(makeSnapshot(), projectRef: "abc", userId: "u1")
        store.deleteSnapshot(projectRef: "abc", userId: "u1")
        #expect(store.loadSnapshot(projectRef: "abc", userId: "u1") == nil)
    }

    @Test func perUserIsolation() {
        let store = InMemoryFlagsStorage()
        store.saveSnapshot(makeSnapshot(["k": .int(1)]), projectRef: "abc", userId: "u1")
        store.saveSnapshot(makeSnapshot(["k": .int(2)]), projectRef: "abc", userId: "u2")
        #expect(store.loadSnapshot(projectRef: "abc", userId: "u1")?.values["k"] == .int(1))
        #expect(store.loadSnapshot(projectRef: "abc", userId: "u2")?.values["k"] == .int(2))
        #expect(store.count() == 2)
    }

    @Test func perProjectIsolation() {
        let store = InMemoryFlagsStorage()
        store.saveSnapshot(makeSnapshot(["k": .int(1)]), projectRef: "aaa", userId: "u")
        store.saveSnapshot(makeSnapshot(["k": .int(2)]), projectRef: "bbb", userId: "u")
        #expect(store.loadSnapshot(projectRef: "aaa", userId: "u")?.values["k"] == .int(1))
        #expect(store.loadSnapshot(projectRef: "bbb", userId: "u")?.values["k"] == .int(2))
    }
}

@Suite("FlagsStorage — UserDefaults")
struct UserDefaultsFlagsStorageTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "palbase.flags.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return defaults
    }

    @Test func saveAndLoadRoundTrip() {
        let defaults = makeDefaults()
        let store = UserDefaultsFlagsStorage(defaults: defaults)
        let snap = FlagsSnapshot(
            values: ["ai_features": .bool(true), "max_upload_mb": .int(100)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.saveSnapshot(snap, projectRef: "abc", userId: "u1")
        let loaded = store.loadSnapshot(projectRef: "abc", userId: "u1")
        #expect(loaded?.values["ai_features"] == .bool(true))
        #expect(loaded?.values["max_upload_mb"] == .int(100))
    }

    @Test func deleteRemovesEntry() {
        let defaults = makeDefaults()
        let store = UserDefaultsFlagsStorage(defaults: defaults)
        let snap = FlagsSnapshot(values: ["k": .int(1)], fetchedAt: Date())
        store.saveSnapshot(snap, projectRef: "abc", userId: "u1")
        store.deleteSnapshot(projectRef: "abc", userId: "u1")
        #expect(store.loadSnapshot(projectRef: "abc", userId: "u1") == nil)
    }
}
