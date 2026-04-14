import XCTest
@testable import PalbaseCore

final class TokenManagerRetainCycleTests: XCTestCase {

    /// Verifies that calling Unsubscribe removes the listener.
    func testCallback_unsubscribeRemovesListener() async throws {
        let tm = TokenManager()
        let received = ReceivedBox()

        let unsubscribe = await tm.onAuthStateChange { event, _ in
            Task { await received.append(event) }
        }

        let listenerCount = await tm.listenersCountForTesting
        XCTAssertEqual(listenerCount, 1)

        let session = Session(accessToken: "a", refreshToken: "r", expiresAt: Int64(Date().timeIntervalSince1970) + 3600)
        await tm.setSession(session)
        try await Task.sleep(nanoseconds: 50_000_000)

        unsubscribe()

        // Unsubscribe uses Task { ... } internally — poll briefly
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 25_000_000)
            let count = await tm.listenersCountForTesting
            if count == 0 { break }
        }

        let finalCount = await tm.listenersCountForTesting
        XCTAssertEqual(finalCount, 0, "Listener should be removed after unsubscribe")

        await tm.clearSession()
        try await Task.sleep(nanoseconds: 50_000_000)

        let events = await received.events
        XCTAssertEqual(events, [.sessionSet], "After unsubscribe, no more events should be received")
    }
}

// Test helper — thread-safe event collector
actor ReceivedBox {
    var events: [AuthStateEvent] = []
    func append(_ event: AuthStateEvent) {
        events.append(event)
    }
}
