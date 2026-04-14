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
