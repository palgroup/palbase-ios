import Testing
import Foundation
@testable import PalbaseCore

@Suite("PalbaseCore basics")
struct CoreTests {

    @Test("parseProjectRef extracts ref from valid key")
    func parseValidKey() {
        #expect(HttpClient.parseProjectRef(from: "pb_abc123_xxxxxxxxxxx") == "abc123")
    }

    @Test("parseProjectRef returns nil for invalid keys")
    func parseInvalidKey() {
        #expect(HttpClient.parseProjectRef(from: "invalid") == nil)
        #expect(HttpClient.parseProjectRef(from: "pb_") == nil)
        #expect(HttpClient.parseProjectRef(from: "pk_abc_xxx") == nil)
    }

    @Test("Session.isExpired correctly checks timestamp")
    func sessionExpiry() {
        let expired = Session(accessToken: "a", refreshToken: "b", expiresAt: 0)
        #expect(expired.isExpired == true)

        let valid = Session(
            accessToken: "a",
            refreshToken: "b",
            expiresAt: Int64(Date().timeIntervalSince1970) + 3600
        )
        #expect(valid.isExpired == false)
    }

    @Test("PalbaseCoreError exposes status code and code")
    func errorCodes() {
        let unauth = PalbaseCoreError.http(status: 401, code: "unauthorized", message: "x")
        #expect(unauth.statusCode == 401)
        #expect(unauth.code == "unauthorized")

        let rate = PalbaseCoreError.rateLimited(retryAfter: 30)
        #expect(rate.statusCode == 429)
    }
}

@Suite("TokenManager lifecycle")
struct TokenManagerTests {

    @Test("setSession then accessToken returns the value")
    func setAndGet() async {
        let tm = TokenManager()
        let s = Session(accessToken: "a", refreshToken: "r", expiresAt: Int64(Date().timeIntervalSince1970) + 3600)

        await tm.setSession(s)
        let token = await tm.accessToken
        #expect(token == "a")

        await tm.clearSession()
        let cleared = await tm.accessToken
        #expect(cleared == nil)
    }

    @Test("waitUntilReady suspends until markBootComplete and is no-op after")
    func bootSignal() async throws {
        let tm = TokenManager()

        // Two waiters parked before boot completes; both must resume.
        async let w1: Void = tm.waitUntilReady()
        async let w2: Void = tm.waitUntilReady()
        try await Task.sleep(nanoseconds: 20_000_000)
        await tm.markBootComplete()
        _ = await (w1, w2)

        // After boot, waitUntilReady returns immediately (no continuation
        // bookkeeping to leak).
        let start = ContinuousClock().now
        await tm.waitUntilReady()
        let elapsed = ContinuousClock().now - start
        #expect(elapsed < .milliseconds(5))
    }

    @Test("refreshSession 4xx clears session and emits sessionCleared(.refreshFailed)")
    func refreshFatalClears() async throws {
        let tm = TokenManager()
        let s = Session(accessToken: "old", refreshToken: "rt", expiresAt: 0)
        await tm.setSession(s)

        // Server says: this refresh_token is dead. (revoked / reused / banned.)
        await tm.setRefreshFunction { _ in
            throw PalbaseCoreError.http(status: 401, code: "invalid_token", message: "revoked")
        }

        let received = ReceivedEvents()
        let unsubscribe = await tm.onAuthStateChange { event, _ in
            Task { await received.append(event) }
        }
        defer { unsubscribe() }

        // refresh propagates the fatal error.
        await #expect(throws: PalbaseCoreError.self) {
            try await tm.refreshSession()
        }

        // Local state was cleared.
        let token = await tm.accessToken
        #expect(token == nil)

        // sessionCleared(.refreshFailed) event fired.
        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await received.events
        #expect(events.contains(.sessionCleared(reason: .refreshFailed)))
    }

    @Test("refreshSession 5xx keeps session intact (transient)")
    func refreshTransientKeepsSession() async throws {
        let tm = TokenManager()
        let s = Session(accessToken: "old", refreshToken: "rt", expiresAt: 0)
        await tm.setSession(s)

        await tm.setRefreshFunction { _ in
            throw PalbaseCoreError.server(status: 503, message: "upstream down")
        }

        await #expect(throws: PalbaseCoreError.self) {
            try await tm.refreshSession()
        }

        // Session NOT cleared — caller can retry later.
        let token = await tm.refreshToken
        #expect(token == "rt")
    }

    @Test("refreshSession 429 keeps session intact (transient)")
    func refreshRateLimitedKeepsSession() async throws {
        let tm = TokenManager()
        let s = Session(accessToken: "old", refreshToken: "rt", expiresAt: 0)
        await tm.setSession(s)

        await tm.setRefreshFunction { _ in
            throw PalbaseCoreError.http(status: 429, code: "rate_limited", message: "slow down")
        }

        await #expect(throws: PalbaseCoreError.self) {
            try await tm.refreshSession()
        }

        let token = await tm.refreshToken
        #expect(token == "rt")
    }

    @Test("refreshSession success rotates session and emits tokenRefreshed")
    func refreshSuccessRotates() async throws {
        let tm = TokenManager()
        let old = Session(accessToken: "old", refreshToken: "rt0", expiresAt: 0)
        await tm.setSession(old)

        await tm.setRefreshFunction { rt in
            #expect(rt == "rt0")
            return Session(accessToken: "new", refreshToken: "rt1", expiresAt: Int64(Date().timeIntervalSince1970) + 3600)
        }

        let received = ReceivedEvents()
        let unsubscribe = await tm.onAuthStateChange { event, _ in
            Task { await received.append(event) }
        }
        defer { unsubscribe() }

        let result = try await tm.refreshSession()
        #expect(result.accessToken == "new")
        #expect(result.refreshToken == "rt1")

        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await received.events
        #expect(events.contains(.tokenRefreshed))
        #expect(events.contains(.sessionSet))
    }

    @Test("Listener receives sessionSet then is removed on unsubscribe")
    func listenerLifecycle() async throws {
        let tm = TokenManager()
        let received = ReceivedEvents()

        let unsubscribe = await tm.onAuthStateChange { event, _ in
            Task { await received.append(event) }
        }

        let count1 = await tm.listenersCountForTesting
        #expect(count1 == 1)

        let s = Session(accessToken: "a", refreshToken: "r", expiresAt: Int64(Date().timeIntervalSince1970) + 3600)
        await tm.setSession(s)
        try await Task.sleep(nanoseconds: 50_000_000)

        unsubscribe()

        // Unsubscribe internally schedules removal — poll briefly
        var count = 1
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 25_000_000)
            count = await tm.listenersCountForTesting
            if count == 0 { break }
        }
        #expect(count == 0)

        await tm.clearSession()
        try await Task.sleep(nanoseconds: 50_000_000)

        let events = await received.events
        #expect(events == [.sessionSet])
    }
}

// MARK: - Test helpers

actor ReceivedEvents {
    var events: [AuthStateEvent] = []
    func append(_ event: AuthStateEvent) {
        events.append(event)
    }
}
