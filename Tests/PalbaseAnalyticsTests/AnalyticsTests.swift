import Foundation
import Testing
@testable import PalbaseAnalytics

// MARK: - Mock HTTP

actor RecordedAnalyticsCall {
    var method: String = ""
    var path: String = ""
    var body: Data? = nil
    var count: Int = 0
    var bodies: [Data] = []

    func record(method: String, path: String, body: Data?) {
        self.method = method
        self.path = path
        self.body = body
        if let body { bodies.append(body) }
        self.count += 1
    }

    func snapshot() -> (method: String, path: String, body: Data?, count: Int, bodies: [Data]) {
        (method, path, body, count, bodies)
    }
}

/// Mock HTTPRequesting that records requests and replays a pre-baked outcome.
struct MockAnalyticsHTTP: HTTPRequesting {
    let recorder: RecordedAnalyticsCall
    let failure: @Sendable () -> PalbaseCoreError?

    init(
        recorder: RecordedAnalyticsCall,
        failure: @escaping @Sendable () -> PalbaseCoreError? = { nil }
    ) {
        self.recorder = recorder
        self.failure = failure
    }

    func request<T: Decodable & Sendable>(
        method: String, path: String, body: (any Encodable & Sendable)?, headers: [String: String]
    ) async throws(PalbaseCoreError) -> T {
        let (data, _) = try await requestRaw(method: method, path: path, body: body, headers: headers)
        do {
            return try JSONDecoder.palbaseDefault.decode(T.self, from: data)
        } catch {
            throw PalbaseCoreError.decoding(message: error.localizedDescription)
        }
    }

    func requestVoid(
        method: String, path: String, body: (any Encodable & Sendable)?, headers: [String: String]
    ) async throws(PalbaseCoreError) {
        _ = try await requestRaw(method: method, path: path, body: body, headers: headers)
    }

    func requestRaw(
        method: String, path: String, body: (any Encodable & Sendable)?, headers: [String: String]
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int) {
        let encoded: Data?
        if let body {
            do {
                encoded = try JSONEncoder.palbaseDefault.encode(body)
            } catch {
                throw PalbaseCoreError.encoding(message: error.localizedDescription)
            }
        } else {
            encoded = nil
        }
        await recorder.record(method: method, path: path, body: encoded)
        if let err = failure() { throw err }
        return (Data("{}".utf8), 202)
    }
}

// MARK: - Helpers

private func makeClient(
    http: MockAnalyticsHTTP,
    queue: EventQueue? = nil,
    storage: AnalyticsStorage? = nil,
    distinctId: String? = nil,
    now: Date = Date(timeIntervalSince1970: 1_700_000_000)
) async -> PalbaseAnalytics {
    let q = queue ?? EventQueue.inMemory()
    let s: AnalyticsStorage = storage ?? InMemoryAnalyticsStorage(distinctId: distinctId)
    let tokens = TokenManager()
    let clock: @Sendable () -> Date = { now }
    let flusher = Flusher(http: http, queue: q, clock: clock)
    return PalbaseAnalytics(
        http: http,
        tokens: tokens,
        storage: s,
        queue: q,
        session: SessionTracker(clock: clock),
        flusher: flusher,
        clock: clock,
        appVersion: "1.0.0"
    )
}

private func decodeBatch(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// MARK: - Event name validation

@Suite("Event name validation")
struct EventNameValidationTests {
    @Test func acceptsValidNames() throws {
        try EventNameValidator.validate("purchase")
        try EventNameValidator.validate("button_clicked")
        try EventNameValidator.validate("app.launched")
        try EventNameValidator.validate("order:paid")
        try EventNameValidator.validate("a-b-c")
        try EventNameValidator.validate("E1")
    }

    @Test func rejectsInvalidNames() {
        #expect(throws: AnalyticsError.self) { try EventNameValidator.validate("") }
        #expect(throws: AnalyticsError.self) { try EventNameValidator.validate("1leading_digit") }
        #expect(throws: AnalyticsError.self) { try EventNameValidator.validate("has space") }
        #expect(throws: AnalyticsError.self) { try EventNameValidator.validate("unicode🎉") }
        #expect(throws: AnalyticsError.self) {
            try EventNameValidator.validate(String(repeating: "a", count: 66))
        }
    }

    @Test func allowsSdkInternalPrefixedNames() throws {
        try EventNameValidator.validate("$identify")
        try EventNameValidator.validate("$screen")
        try EventNameValidator.validate("$pageview")
        try EventNameValidator.validate("$create_alias")
    }
}

// MARK: - AnalyticsValue

@Suite("AnalyticsValue literal + codable")
struct AnalyticsValueTests {
    @Test func literalConformances() {
        let s: AnalyticsValue = "hello"
        let i: AnalyticsValue = 42
        let d: AnalyticsValue = 9.99
        let b: AnalyticsValue = true
        let n: AnalyticsValue = nil
        let a: AnalyticsValue = ["a", 1, true]
        let o: AnalyticsValue = ["x": 1, "y": "z"]
        #expect(s == .string("hello"))
        #expect(i == .int(42))
        #expect(d == .double(9.99))
        #expect(b == .bool(true))
        #expect(n == .null)
        if case .array(let arr) = a {
            #expect(arr.count == 3)
        } else { Issue.record("expected array") }
        if case .object(let obj) = o {
            #expect(obj["x"] == .int(1))
            #expect(obj["y"] == .string("z"))
        } else { Issue.record("expected object") }
    }

    @Test func roundTripsThroughJSON() throws {
        let value: AnalyticsValue = [
            "amount": 99.99,
            "items": ["a", "b"],
            "premium": true,
            "count": 3,
            "note": nil,
        ]
        let data = try JSONEncoder.palbaseDefault.encode(value)
        let decoded = try JSONDecoder.palbaseDefault.decode(AnalyticsValue.self, from: data)
        #expect(decoded == value)
    }
}

// MARK: - Capture + flush

@Suite("Capture + flush")
struct CaptureFlushTests {
    @Test func captureAddsEventToQueue() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder)
        let queue = EventQueue.inMemory()
        let client = await makeClient(http: http, queue: queue)

        await client.capture("purchase", properties: ["amount": 99.99])

        let events = await queue.snapshot()
        #expect(events.count == 1)
        #expect(events.first?.event == "purchase")
        #expect(events.first?.properties?["amount"] == .double(99.99))
        #expect(events.first?.sessionId != nil)
    }

    @Test func flushSendsBatchToBatchEndpoint() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder)
        let queue = EventQueue.inMemory()
        let client = await makeClient(http: http, queue: queue)

        await client.capture("a")
        await client.capture("b")

        try await client.flush()

        let snap = await recorder.snapshot()
        #expect(snap.method == "POST")
        #expect(snap.path == "/v1/analytics/batch")
        let body = decodeBatch(snap.body ?? Data())
        let events = body?["events"] as? [[String: Any]]
        #expect(events?.count == 2)
        #expect(events?.first?["event"] as? String == "a")

        let remaining = await queue.count()
        #expect(remaining == 0)
    }

    @Test func invalidEventNameIsDropped() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder)
        let queue = EventQueue.inMemory()
        let client = await makeClient(http: http, queue: queue)

        await client.capture("bad name")

        let events = await queue.snapshot()
        #expect(events.isEmpty)
    }

    @Test func oversizedEventIsDropped() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder)
        let queue = EventQueue.inMemory()
        let client = await makeClient(http: http, queue: queue)

        let huge = String(repeating: "x", count: 40_000)
        await client.capture("purchase", properties: ["note": .string(huge)])

        let events = await queue.snapshot()
        #expect(events.isEmpty)
    }

    @Test func batchSplitByMaxEvents() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder)
        let queue = EventQueue.inMemory()
        // Prepopulate the queue directly so auto-flush can't interleave with
        // the batching assertion.
        for i in 0..<150 {
            await queue.append(QueuedEvent(
                eventId: "e\(i)",
                event: "event_\(i)",
                endpoint: .capture,
                distinctId: "u",
                properties: nil,
                traits: nil,
                alias: nil,
                screenName: nil,
                pageURL: nil,
                pageTitle: nil,
                timestampMs: Int64(i),
                sessionId: nil,
                appVersion: nil
            ))
        }

        let flusher = Flusher(http: http, queue: queue)
        let sent = try await flusher.flushOnce()

        let snap = await recorder.snapshot()
        // Two batches — 100 + 50.
        #expect(snap.count == 2)
        #expect(sent == 150)
        let remaining = await queue.count()
        #expect(remaining == 0)
    }

    @Test func flushSurfacesNetworkErrors() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder) {
            .network(message: "boom")
        }
        let queue = EventQueue.inMemory()
        let client = await makeClient(http: http, queue: queue)
        await client.capture("x")

        await #expect(throws: AnalyticsError.self) {
            try await client.flush()
        }
        // Events remain queued on failure.
        let remaining = await queue.count()
        #expect(remaining == 1)
    }

    @Test func flushMapsRateLimitError() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder) {
            .rateLimited(retryAfter: 5)
        }
        let queue = EventQueue.inMemory()
        let client = await makeClient(http: http, queue: queue)
        await client.capture("x")

        do {
            try await client.flush()
            Issue.record("expected rate-limit error")
        } catch {
            if case .rateLimited(let retry) = error {
                #expect(retry == 5)
            } else {
                Issue.record("expected rateLimited, got \(error)")
            }
        }
    }
}

// MARK: - Queue persistence

@Suite("Queue persistence")
struct QueuePersistenceTests {
    @Test func persistsAndHydratesFromDisk() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("palbase-analytics-test-\(UUID().uuidString)", isDirectory: true)
        let queue = EventQueue(directory: tmp)

        let event = QueuedEvent(
            eventId: "evt-1",
            event: "purchase",
            endpoint: .capture,
            distinctId: "u1",
            properties: ["amount": .double(9.99)],
            traits: nil,
            alias: nil,
            screenName: nil,
            pageURL: nil,
            pageTitle: nil,
            timestampMs: 1_700_000_000_000,
            sessionId: "s1",
            appVersion: "1.0.0"
        )
        await queue.append(event)

        // Reopen the queue and verify events hydrate.
        let reopened = EventQueue(directory: tmp)
        let restored = await reopened.snapshot()
        #expect(restored.count == 1)
        #expect(restored.first?.eventId == "evt-1")

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test func overflowDropsOldest() async throws {
        let queue = EventQueue.inMemory(maxSize: 3)
        for i in 0..<5 {
            await queue.append(QueuedEvent(
                eventId: "e\(i)",
                event: "x",
                endpoint: .capture,
                distinctId: "u",
                properties: nil,
                traits: nil,
                alias: nil,
                screenName: nil,
                pageURL: nil,
                pageTitle: nil,
                timestampMs: Int64(i),
                sessionId: nil,
                appVersion: nil
            ))
        }
        let snap = await queue.snapshot()
        #expect(snap.count == 3)
        #expect(snap.first?.eventId == "e2")
        #expect(snap.last?.eventId == "e4")
    }
}

// MARK: - Session

@Suite("Session tracking")
struct SessionTrackingTests {
    @Test func sessionIdStableWithinWindow() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clockRef = Clock(now: now)
        let tracker = SessionTracker(clock: clockRef.get)

        let id1 = await tracker.touch()
        clockRef.advance(by: 60)  // 1 minute
        let id2 = await tracker.touch()
        #expect(id1 == id2)
    }

    @Test func newSessionAfterInactivity() async {
        let clockRef = Clock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let tracker = SessionTracker(clock: clockRef.get)
        let id1 = await tracker.touch()
        clockRef.advance(by: 31 * 60)  // 31 minutes
        let id2 = await tracker.touch()
        #expect(id1 != id2)
    }

    @Test func newSessionAfter24Hours() async {
        let clockRef = Clock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let tracker = SessionTracker(clock: clockRef.get)
        let id1 = await tracker.touch()
        // Keep activity fresh every 5 minutes for 25h.
        for _ in 0..<(25 * 12) {
            clockRef.advance(by: 5 * 60)
            _ = await tracker.touch()
        }
        let finalId = await tracker.peek()
        #expect(id1 != finalId)
    }

    @Test func resetClearsSession() async {
        let tracker = SessionTracker()
        let id1 = await tracker.touch()
        await tracker.reset()
        let id2 = await tracker.touch()
        #expect(id1 != id2)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date
    init(now: Date) { self.now = now }
    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        now = now.addingTimeInterval(interval)
    }
    var get: @Sendable () -> Date {
        { [weak self] in self?.snapshot() ?? Date() }
    }
    func snapshot() -> Date {
        lock.lock(); defer { lock.unlock() }
        return now
    }
}

// MARK: - Identity + alias + screen + page

@Suite("Identity + shorthand events")
struct IdentityTests {
    @Test func identifySetsDistinctIdAndQueuesEvent() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder)
        let queue = EventQueue.inMemory()
        let client = await makeClient(http: http, queue: queue)

        await client.identify(distinctId: "user_42", traits: ["plan": "pro"])

        let distinctId = await client._currentDistinctId()
        #expect(distinctId == "user_42")
        let events = await queue.snapshot()
        #expect(events.first?.event == "$identify")
        #expect(events.first?.distinctId == "user_42")
        #expect(events.first?.traits?["plan"] == .string("pro"))
    }

    @Test func aliasQueuesCreateAlias() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder)
        let queue = EventQueue.inMemory()
        let client = await makeClient(http: http, queue: queue)

        await client.alias(from: "anon_a", to: "user_1")
        let events = await queue.snapshot()
        #expect(events.first?.event == "$create_alias")
        #expect(events.first?.alias?.from == "anon_a")
        #expect(events.first?.alias?.to == "user_1")
    }

    @Test func screenQueuesScreenEvent() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder)
        let queue = EventQueue.inMemory()
        let client = await makeClient(http: http, queue: queue)

        await client.screen("Home", properties: ["source": "push"])
        let events = await queue.snapshot()
        #expect(events.first?.event == "$screen")
        #expect(events.first?.screenName == "Home")
    }

    @Test func pageQueuesPageviewEvent() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder)
        let queue = EventQueue.inMemory()
        let client = await makeClient(http: http, queue: queue)

        await client.page(url: "https://example.com/", title: "Home")
        let events = await queue.snapshot()
        #expect(events.first?.event == "$pageview")
        #expect(events.first?.pageURL == "https://example.com/")
        #expect(events.first?.pageTitle == "Home")
    }

    @Test func resetAssignsNewDistinctId() async {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder)
        let queue = EventQueue.inMemory()
        let storage = InMemoryAnalyticsStorage(distinctId: "user_1")
        let client = await makeClient(http: http, queue: queue, storage: storage)

        await client.reset()
        let newId = await client._currentDistinctId()
        #expect(newId != "user_1")
    }
}

// MARK: - Opt-out

@Suite("Opt-out")
struct OptOutTests {
    @Test func optOutPreventsCapture() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder)
        let queue = EventQueue.inMemory()
        let client = await makeClient(http: http, queue: queue)

        await client.optOut()
        await client.capture("purchase")
        let events = await queue.snapshot()
        #expect(events.isEmpty)
    }

    @Test func optInResumesCapture() async throws {
        let recorder = RecordedAnalyticsCall()
        let http = MockAnalyticsHTTP(recorder: recorder)
        let queue = EventQueue.inMemory()
        let client = await makeClient(http: http, queue: queue)

        await client.optOut()
        await client.capture("a")  // should be ignored
        await client.optIn()
        await client.capture("b")
        let events = await queue.snapshot()
        #expect(events.count == 1)
        #expect(events.first?.event == "b")
    }
}

// MARK: - Error mapping

@Suite("Error mapping")
struct ErrorMappingTests {
    @Test func mapsCoreErrorsOneToOne() {
        let cases: [(PalbaseCoreError, String)] = [
            (.network(message: "n"), "network_error"),
            (.decoding(message: "d"), "decoding_error"),
            (.encoding(message: "e"), "network_error"),
            (.rateLimited(retryAfter: 1), "rate_limited"),
            (.server(status: 500, message: "oops"), "server_error"),
            (.http(status: 400, code: "bad", message: "m", requestId: "r"), "bad"),
            (.invalidConfiguration(message: "x"), "network_error"),
            (.notConfigured, "not_configured"),
            (.tokenRefreshFailed(message: "t"), "network_error"),
        ]
        for (core, expected) in cases {
            #expect(AnalyticsError.from(transport: core).code == expected)
        }
    }

    @Test func envelopeMapsKnownCodes() throws {
        // The envelope uses explicit CodingKeys, so it must be decoded with a
        // non-snake-case-converting decoder.
        let json = """
        {
            "error": "invalid_event_name",
            "error_description": "bad",
            "status": 400,
            "request_id": "r1",
            "details": {"event": "bad name"}
        }
        """
        let env = try JSONDecoder().decode(
            PalbaseErrorEnvelope.self,
            from: Data(json.utf8)
        )
        if case .invalidEventName(let n) = AnalyticsError.from(envelope: env) {
            #expect(n == "bad name")
        } else {
            Issue.record("expected invalidEventName")
        }
    }
}
