import Foundation
import Testing
@testable import PalbaseFlags

// MARK: - Mock HTTP

private actor RecordedFlagsCall {
    var count: Int = 0
    var lastMethod: String = ""
    var lastPath: String = ""

    func record(method: String, path: String) {
        count += 1
        lastMethod = method
        lastPath = path
    }

    func snapshot() -> (count: Int, method: String, path: String) {
        (count, lastMethod, lastPath)
    }
}

private struct MockFlagsHTTP: HTTPRequesting {
    let recorder: RecordedFlagsCall
    let response: @Sendable () -> Result<Data, PalbaseCoreError>

    init(
        recorder: RecordedFlagsCall,
        response: @escaping @Sendable () -> Result<Data, PalbaseCoreError>
    ) {
        self.recorder = recorder
        self.response = response
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
        await recorder.record(method: method, path: path)
        switch response() {
        case .success(let data): return (data, 200)
        case .failure(let err): throw err
        }
    }
}

// MARK: - Mock realtime subscriber

private actor MockRealtimeSubscriber: FlagsRealtimeSubscribing {
    var subscribed: Bool = false
    var unsubscribed: Bool = false
    var lastProjectRef: String?
    var lastUserId: String?
    private var onEvent: (@Sendable (FlagsRealtimeEvent) -> Void)?
    private var onReconnect: (@Sendable () -> Void)?

    func subscribe(
        projectRef: String,
        userId: String,
        onEvent: @escaping @Sendable (FlagsRealtimeEvent) -> Void,
        onReconnect: @escaping @Sendable () -> Void
    ) async throws(FlagsError) {
        self.subscribed = true
        self.lastProjectRef = projectRef
        self.lastUserId = userId
        self.onEvent = onEvent
        self.onReconnect = onReconnect
    }

    func unsubscribe() async {
        unsubscribed = true
        onEvent = nil
        onReconnect = nil
    }

    func emit(_ event: FlagsRealtimeEvent) {
        onEvent?(event)
    }

    func reconnect() {
        onReconnect?()
    }
}

// MARK: - Fixtures

private let apiKey = "pb_abc123_xxxxxxxxxxxxxxxx"
private let userId = "user_42"

private func snapshotJSON(values: [String: Any], fetchedAt: String = "2026-04-14T10:30:00Z") -> Data {
    let body: [String: Any] = ["values": values, "fetched_at": fetchedAt]
    return try! JSONSerialization.data(withJSONObject: body)
}

private func makeClient(
    http: HTTPRequesting,
    storage: FlagsStorage = InMemoryFlagsStorage(),
    realtime: MockRealtimeSubscriber = MockRealtimeSubscriber(),
    userId: String? = userId
) -> PalbaseFlags {
    let tokens = TokenManager()
    let rt = realtime
    return PalbaseFlags(
        http: http,
        tokens: tokens,
        apiKey: apiKey,
        storage: storage,
        realtimeFactory: { rt },
        clock: { Date(timeIntervalSince1970: 1_700_000_000) },
        userIdProvider: { _ in userId }
    )
}

// MARK: - Fetch

@Suite("PalbaseFlags — fetch")
struct FlagsFetchTests {
    @Test func fetchHitsUserFlagsEndpointAndUpdatesCache() async throws {
        let recorder = RecordedFlagsCall()
        let data = snapshotJSON(values: ["ai_features": true, "max_upload_mb": 100])
        let http = MockFlagsHTTP(recorder: recorder, response: { .success(data) })
        let client = makeClient(http: http)

        let snap = try await client.fetch()

        let rec = await recorder.snapshot()
        #expect(rec.method == "GET")
        #expect(rec.path == "/v1/user-flags")
        #expect(rec.count == 1)
        #expect(snap.values["ai_features"] == .bool(true))
        #expect(await client.value(for: "ai_features") == .bool(true))
        #expect(await client.value(for: "max_upload_mb") == .int(100))
    }

    @Test func fetchPersistsSnapshotToStorage() async throws {
        let recorder = RecordedFlagsCall()
        let data = snapshotJSON(values: ["flag": true])
        let http = MockFlagsHTTP(recorder: recorder, response: { .success(data) })
        let storage = InMemoryFlagsStorage()
        let client = makeClient(http: http, storage: storage)

        _ = try await client.fetch()
        #expect(storage.loadSnapshot(projectRef: "abc123", userId: userId)?.values["flag"] == .bool(true))
    }

    @Test func fetchWithoutSessionThrows() async {
        let recorder = RecordedFlagsCall()
        let http = MockFlagsHTTP(recorder: recorder, response: { .success(Data("{}".utf8)) })
        let client = makeClient(http: http, userId: nil)

        await #expect(throws: FlagsError.self) {
            _ = try await client.fetch()
        }
    }

    @Test func fetchMapsNetworkError() async {
        let recorder = RecordedFlagsCall()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .failure(.network(message: "offline")) }
        )
        let client = makeClient(http: http)

        do {
            _ = try await client.fetch()
            Issue.record("expected error")
        } catch {
            if case .network = error { /* ok */ } else {
                Issue.record("expected .network, got \(error)")
            }
        }
    }

    @Test func fetchMapsHTTP401() async {
        let recorder = RecordedFlagsCall()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .failure(.http(status: 401, code: "unauthorized", message: "no session", requestId: "r1")) }
        )
        let client = makeClient(http: http)

        do {
            _ = try await client.fetch()
            Issue.record("expected error")
        } catch {
            if case .http(let status, _, _, _) = error { #expect(status == 401) } else {
                Issue.record("expected .http, got \(error)")
            }
        }
    }

    @Test func fetchMapsServer5xx() async {
        let recorder = RecordedFlagsCall()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .failure(.server(status: 503, message: "down")) }
        )
        let client = makeClient(http: http)

        do {
            _ = try await client.fetch()
            Issue.record("expected error")
        } catch {
            if case .serverError(let status, _) = error { #expect(status == 503) } else {
                Issue.record("expected .serverError, got \(error)")
            }
        }
    }

    @Test func fetchMapsDecodingFailure() async {
        let recorder = RecordedFlagsCall()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .success(Data("not json".utf8)) }
        )
        let client = makeClient(http: http)

        do {
            _ = try await client.fetch()
            Issue.record("expected error")
        } catch {
            if case .decoding = error { /* ok */ } else {
                Issue.record("expected .decoding, got \(error)")
            }
        }
    }
}

// MARK: - Accessors

@Suite("PalbaseFlags — value accessors")
struct FlagsAccessorTests {
    private func seededClient() async -> PalbaseFlags {
        let recorder = RecordedFlagsCall()
        let http = MockFlagsHTTP(recorder: recorder, response: { .success(Data("{}".utf8)) })
        let client = makeClient(http: http)
        await client._setCacheForTesting([
            "is_enabled": .bool(true),
            "max_upload": .int(50),
            "ratio": .double(0.25),
            "name": .string("prod"),
            "limits": .object(["max": .int(10)]),
            "tiers": .array([.string("free"), .string("pro")])
        ])
        return client
    }

    @Test func optionalBoolReturnsValueOrNil() async {
        let client = await seededClient()
        #expect(await client.bool("is_enabled") == true)
        #expect(await client.bool("missing") == nil)
    }

    @Test func optionalStringReturnsValueOrNil() async {
        let client = await seededClient()
        #expect(await client.string("name") == "prod")
        #expect(await client.string("missing") == nil)
    }

    @Test func optionalIntReturnsValueOrNil() async {
        let client = await seededClient()
        #expect(await client.int("max_upload") == 50)
        #expect(await client.int("missing") == nil)
    }

    @Test func optionalDoubleReturnsValueOrNil() async {
        let client = await seededClient()
        #expect(await client.double("ratio") == 0.25)
        #expect(await client.double("missing") == nil)
    }

    @Test func optionalObjectAndArray() async {
        let client = await seededClient()
        #expect(await client.object("limits")?["max"] == .int(10))
        #expect(await client.array("tiers")?.count == 2)
        #expect(await client.object("missing") == nil)
        #expect(await client.array("missing") == nil)
    }

    @Test func defaultAccessorsFallBack() async {
        let client = await seededClient()
        #expect(await client.bool("missing", default: false) == false)
        #expect(await client.string("missing", default: "x") == "x")
        #expect(await client.int("missing", default: 7) == 7)
        #expect(await client.double("missing", default: 1.5) == 1.5)
    }

    @Test func typeMismatchReturnsNil() async {
        let client = await seededClient()
        // is_enabled is bool — reading as int returns nil
        #expect(await client.int("is_enabled") == nil)
        // name is string — reading as bool returns nil
        #expect(await client.bool("name") == nil)
    }

    @Test func allReturnsWholeCache() async {
        let client = await seededClient()
        let all = await client.all()
        #expect(all.count == 6)
        #expect(all["name"] == .string("prod"))
    }
}

// MARK: - Listeners

@Suite("PalbaseFlags — listeners")
struct FlagsListenerTests {
    @Test func onChangeFiresOnFetchUpdate() async throws {
        let recorder = RecordedFlagsCall()
        let data = snapshotJSON(values: ["f": true])
        let http = MockFlagsHTTP(recorder: recorder, response: { .success(data) })
        let client = makeClient(http: http)

        let received = ReceivedEvents()
        let unsub = await client.onChange { key, value in
            Task { await received.append(key, value) }
        }
        _ = try await client.fetch()
        try await Task.sleep(nanoseconds: 50_000_000)

        let events = await received.all()
        #expect(events.contains { $0.0 == "f" && $0.1 == .bool(true) })
        unsub()
    }

    @Test func keyedListenerFiresOnlyForMatchingKey() async throws {
        let recorder = RecordedFlagsCall()
        let data = snapshotJSON(values: ["a": 1, "b": 2])
        let http = MockFlagsHTTP(recorder: recorder, response: { .success(data) })
        let client = makeClient(http: http)

        let received = ReceivedEvents()
        let unsub = await client.onChange(key: "a") { value in
            Task { await received.append("a", value) }
        }
        _ = try await client.fetch()
        try await Task.sleep(nanoseconds: 50_000_000)

        let events = await received.all()
        #expect(events.count == 1)
        #expect(events.first?.1 == .int(1))
        unsub()
    }

    @Test func unsubscribeStopsDelivery() async throws {
        let recorder = RecordedFlagsCall()
        let mock = MockRealtimeSubscriber()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .success(snapshotJSON(values: [:])) }
        )
        let client = makeClient(http: http, realtime: mock)

        let received = ReceivedEvents()
        let unsub = await client.onChange { key, value in
            Task { await received.append(key, value) }
        }

        try await client.start()
        await mock.emit(.userFlagChanged(key: "x", value: .int(1)))
        try await Task.sleep(nanoseconds: 50_000_000)
        let beforeUnsub = await received.all().count

        unsub()
        try await Task.sleep(nanoseconds: 50_000_000)
        await mock.emit(.userFlagChanged(key: "y", value: .int(2)))
        try await Task.sleep(nanoseconds: 50_000_000)

        let afterUnsub = await received.all().count
        #expect(afterUnsub == beforeUnsub)
    }
}

// MARK: - start / stop / clear

@Suite("PalbaseFlags — lifecycle")
struct FlagsLifecycleTests {
    @Test func startHydratesFromPersistenceThenFetches() async throws {
        let recorder = RecordedFlagsCall()
        let storage = InMemoryFlagsStorage()
        // seed stale snapshot
        let stale = FlagsSnapshot(
            values: ["cached": .string("v1")],
            fetchedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        storage.saveSnapshot(stale, projectRef: "abc123", userId: userId)

        let data = snapshotJSON(values: ["cached": "v2", "new": 1])
        let http = MockFlagsHTTP(recorder: recorder, response: { .success(data) })
        let client = makeClient(http: http, storage: storage)

        try await client.start()

        #expect(await client.value(for: "cached") == .string("v2"))
        #expect(await client.value(for: "new") == .int(1))
        #expect(await client.isStarted == true)
    }

    @Test func startSubscribesToRealtime() async throws {
        let recorder = RecordedFlagsCall()
        let mock = MockRealtimeSubscriber()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .success(snapshotJSON(values: [:])) }
        )
        let client = makeClient(http: http, realtime: mock)

        try await client.start()
        #expect(await mock.subscribed == true)
        #expect(await mock.lastProjectRef == "abc123")
        #expect(await mock.lastUserId == userId)
    }

    @Test func stopUnsubscribesButKeepsCache() async throws {
        let recorder = RecordedFlagsCall()
        let mock = MockRealtimeSubscriber()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .success(snapshotJSON(values: ["k": 1])) }
        )
        let client = makeClient(http: http, realtime: mock)

        try await client.start()
        await client.stop()
        #expect(await mock.unsubscribed == true)
        #expect(await client.isStarted == false)
        #expect(await client.value(for: "k") == .int(1))
    }

    @Test func clearWipesCacheAndPersistence() async throws {
        let recorder = RecordedFlagsCall()
        let storage = InMemoryFlagsStorage()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .success(snapshotJSON(values: ["k": 1])) }
        )
        let mock = MockRealtimeSubscriber()
        let client = makeClient(http: http, storage: storage, realtime: mock)

        try await client.start()
        #expect(await client.value(for: "k") == .int(1))
        #expect(storage.loadSnapshot(projectRef: "abc123", userId: userId) != nil)

        await client.clear()

        #expect(await client.value(for: "k") == nil)
        #expect(await client.all().isEmpty)
        #expect(storage.loadSnapshot(projectRef: "abc123", userId: userId) == nil)
        #expect(await client.isStarted == false)
    }

    @Test func startWithoutSessionThrowsNoActiveSession() async {
        let recorder = RecordedFlagsCall()
        let http = MockFlagsHTTP(recorder: recorder, response: { .success(Data("{}".utf8)) })
        let client = makeClient(http: http, userId: nil)

        do {
            try await client.start()
            Issue.record("expected error")
        } catch {
            if case .noActiveSession = error { /* ok */ } else {
                Issue.record("expected .noActiveSession, got \(error)")
            }
        }
    }
}

// MARK: - Realtime event handling

@Suite("PalbaseFlags — realtime dispatch")
struct FlagsRealtimeDispatchTests {
    @Test func userFlagChangedUpdatesCache() async throws {
        let recorder = RecordedFlagsCall()
        let mock = MockRealtimeSubscriber()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .success(snapshotJSON(values: [:])) }
        )
        let client = makeClient(http: http, realtime: mock)

        try await client.start()
        await mock.emit(.userFlagChanged(key: "dark_mode", value: .bool(true)))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await client.value(for: "dark_mode") == .bool(true))
    }

    @Test func userFlagDeletedWithSystemValueFallsBack() async throws {
        let recorder = RecordedFlagsCall()
        let mock = MockRealtimeSubscriber()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .success(snapshotJSON(values: ["dark_mode": true])) }
        )
        let client = makeClient(http: http, realtime: mock)

        try await client.start()
        await mock.emit(.userFlagDeleted(key: "dark_mode", systemValue: .bool(false)))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await client.value(for: "dark_mode") == .bool(false))
    }

    @Test func userFlagDeletedWithoutSystemValueRemovesKey() async throws {
        let recorder = RecordedFlagsCall()
        let mock = MockRealtimeSubscriber()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .success(snapshotJSON(values: ["dark_mode": true])) }
        )
        let client = makeClient(http: http, realtime: mock)

        try await client.start()
        await mock.emit(.userFlagDeleted(key: "dark_mode", systemValue: nil))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await client.value(for: "dark_mode") == nil)
    }

    @Test func systemFlagChangedUpdatesCache() async throws {
        let recorder = RecordedFlagsCall()
        let mock = MockRealtimeSubscriber()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .success(snapshotJSON(values: [:])) }
        )
        let client = makeClient(http: http, realtime: mock)

        try await client.start()
        await mock.emit(.systemFlagChanged(key: "new_feature", value: .int(42)))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await client.value(for: "new_feature") == .int(42))
    }

    @Test func systemFlagDeletedRemovesKey() async throws {
        let recorder = RecordedFlagsCall()
        let mock = MockRealtimeSubscriber()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .success(snapshotJSON(values: ["old": 1])) }
        )
        let client = makeClient(http: http, realtime: mock)

        try await client.start()
        await mock.emit(.systemFlagDeleted(key: "old"))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await client.value(for: "old") == nil)
    }

    @Test func reconnectTriggersResync() async throws {
        let recorder = RecordedFlagsCall()
        let mock = MockRealtimeSubscriber()
        let http = MockFlagsHTTP(
            recorder: recorder,
            response: { .success(snapshotJSON(values: ["k": 1])) }
        )
        let client = makeClient(http: http, realtime: mock)

        try await client.start()
        let countBefore = await recorder.snapshot().count
        await mock.reconnect()
        try await Task.sleep(nanoseconds: 100_000_000)
        let countAfter = await recorder.snapshot().count
        #expect(countAfter > countBefore)
    }
}

// MARK: - Error protocol conformance

@Suite("FlagsError — protocol conformance")
struct FlagsErrorTests {
    @Test func codeMapsCorrectly() {
        #expect(FlagsError.notConfigured.code == "not_configured")
        #expect(FlagsError.notStarted.code == "not_started")
        #expect(FlagsError.noActiveSession.code == "no_active_session")
        #expect(FlagsError.network("x").code == "network_error")
        #expect(FlagsError.decoding("x").code == "decoding_error")
        #expect(FlagsError.rateLimited(retryAfter: nil).code == "rate_limited")
        #expect(FlagsError.serverError(status: 500, message: "x").code == "server_error")
        #expect(FlagsError.http(status: 400, code: "bad", message: "x", requestId: nil).code == "bad")
        #expect(FlagsError.server(code: "conflict", message: "x", requestId: nil).code == "conflict")
    }

    @Test func statusCodeMapsCorrectly() {
        #expect(FlagsError.rateLimited(retryAfter: 5).statusCode == 429)
        #expect(FlagsError.serverError(status: 503, message: "x").statusCode == 503)
        #expect(FlagsError.http(status: 404, code: "nope", message: "x", requestId: nil).statusCode == 404)
        #expect(FlagsError.notConfigured.statusCode == nil)
    }

    @Test func requestIdFlowsThrough() {
        #expect(FlagsError.http(status: 400, code: "x", message: "y", requestId: "r1").requestId == "r1")
        #expect(FlagsError.server(code: "c", message: "m", requestId: "r2").requestId == "r2")
        #expect(FlagsError.notConfigured.requestId == nil)
    }

    @Test func conformsToPalbaseError() {
        let e: any PalbaseError = FlagsError.notConfigured
        #expect(e.code == "not_configured")
    }

    @Test func transportMappingDoesNotLeakCoreError() {
        let mapped = FlagsError.from(transport: .rateLimited(retryAfter: 3))
        if case .rateLimited(let r) = mapped { #expect(r == 3) } else {
            Issue.record("expected rateLimited, got \(mapped)")
        }
    }
}

// MARK: - JWT subject extraction

@Suite("PalbaseFlags — JWT subject")
struct JWTExtractorTests {
    @Test func extractsSubjectFromValidJWT() {
        // header.payload.signature — payload base64url-encodes {"sub":"user_42"}
        let payload = Data(#"{"sub":"user_42","iat":123}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
        #expect(JWTSubjectExtractor.subject(from: token) == "user_42")
    }

    @Test func returnsNilForMalformedJWT() {
        #expect(JWTSubjectExtractor.subject(from: "not-a-jwt") == nil)
        #expect(JWTSubjectExtractor.subject(from: "a.b") != nil ? false : true)
    }
}

// MARK: - Helpers

private actor ReceivedEvents {
    private var events: [(String, FlagValue?)] = []

    func append(_ key: String, _ value: FlagValue?) {
        events.append((key, value))
    }

    func all() -> [(String, FlagValue?)] { events }
}
