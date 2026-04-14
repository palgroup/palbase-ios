import Testing
import Foundation
@testable import PalbaseDocs

// MARK: - Recording / mock helpers

actor RecordedCall {
    struct Entry: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data?
    }
    private(set) var entries: [Entry] = []

    func record(_ e: Entry) { entries.append(e) }
    func last() -> Entry? { entries.last }
    func count() -> Int { entries.count }
    func at(_ i: Int) -> Entry? {
        guard i >= 0 && i < entries.count else { return nil }
        return entries[i]
    }
}

/// Route-based mock: looks up a pre-baked response by (method, pathFragment).
final class MockHTTP: @unchecked Sendable, SSEStreaming {
    let recorder: RecordedCall
    let lock = NSLock()
    private var routes: [(match: @Sendable (_ method: String, _ path: String) -> Bool, data: Data, status: Int)] = []
    private var sse: [(match: @Sendable (_ path: String) -> Bool, events: [SSEEvent])] = []

    init(recorder: RecordedCall) { self.recorder = recorder }

    func on(_ method: String, _ pathFragment: String, json: String, status: Int = 200) {
        let data = Data(json.utf8)
        lock.lock(); defer { lock.unlock() }
        routes.append(({ m, p in m == method && p.contains(pathFragment) }, data, status))
    }

    func onSSE(_ pathFragment: String, events: [SSEEvent]) {
        lock.lock(); defer { lock.unlock() }
        sse.append(({ p in p.contains(pathFragment) }, events))
    }

    private func lookup(method: String, path: String) -> (Data, Int)? {
        lock.lock(); defer { lock.unlock() }
        for r in routes where r.match(method, path) {
            return (r.data, r.status)
        }
        return nil
    }

    private func lookupSSE(path: String) -> [SSEEvent]? {
        lock.lock(); defer { lock.unlock() }
        for r in sse where r.match(path) {
            return r.events
        }
        return nil
    }

    // MARK: - HTTPRequesting

    func request<T: Decodable & Sendable>(
        method: String, path: String, body: (any Encodable & Sendable)?, headers: [String: String]
    ) async throws(PalbaseCoreError) -> T {
        let (data, status) = try await requestRaw(method: method, path: path, body: body, headers: headers)
        guard (200..<300).contains(status) else {
            throw PalbaseCoreError.http(status: status, code: "test_error", message: "mock \(status)")
        }
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
        if let body = body {
            do { encoded = try JSONEncoder.palbaseDefault.encode(body) }
            catch { throw PalbaseCoreError.encoding(message: error.localizedDescription) }
        } else {
            encoded = nil
        }
        await recorder.record(
            RecordedCall.Entry(method: method, path: path, headers: headers, body: encoded)
        )
        guard let (data, status) = lookup(method: method, path: path) else {
            throw PalbaseCoreError.http(status: 500, code: "no_route", message: "no mock for \(method) \(path)")
        }
        if !(200..<300).contains(status) {
            throw PalbaseCoreError.http(status: status, code: "test_error", message: "mock \(status)")
        }
        return (data, status)
    }

    // MARK: - SSEStreaming

    func streamSSE(path: String) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        let events = lookupSSE(path: path) ?? []
        return AsyncThrowingStream { cont in
            for e in events { cont.yield(e) }
            cont.finish()
        }
    }
}

struct Todo: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let done: Bool
}

func makeDocs(http: MockHTTP) -> PalbaseDocs {
    let tokens = TokenManager(storage: InMemoryTokenStorage())
    return PalbaseDocs(http: http, tokens: tokens)
}

// MARK: - Path validation

@Suite("Path validation")
struct PathValidationTests {
    @Test func acceptsValidSegment() throws {
        try DocsValidator.validateSegment("users")
        try DocsValidator.validateSegment("user_1")
        try DocsValidator.validateSegment("user-1")
    }

    @Test func rejectsEmptyOrDotSegments() {
        #expect(throws: DocsError.self) { try DocsValidator.validateSegment("") }
        #expect(throws: DocsError.self) { try DocsValidator.validateSegment("..") }
        #expect(throws: DocsError.self) { try DocsValidator.validateSegment(".") }
        #expect(throws: DocsError.self) { try DocsValidator.validateSegment("bad name") }
        #expect(throws: DocsError.self) { try DocsValidator.validateSegment("a/b") }
    }

    @Test func collectionPathMustBeOddSegments() {
        #expect(throws: DocsError.self) { try DocsValidator.validateCollectionPath("users/user1") }
        #expect(throws: DocsError.self) { try DocsValidator.validateCollectionPath("") }
    }

    @Test func documentPathMustBeEvenSegments() {
        #expect(throws: DocsError.self) { try DocsValidator.validateDocumentPath("users") }
        #expect(throws: DocsError.self) { try DocsValidator.validateDocumentPath("users/user1/posts") }
    }

    @Test func rejectsDotDotInPath() {
        #expect(throws: DocsError.self) { try DocsValidator.validatePath("users/../admin") }
    }
}

// MARK: - Query builder

@Suite("Query construction")
struct QueryTests {
    @Test func buildsQueryBodyWithWhereOrderLimit() async throws {
        let rec = RecordedCall()
        let http = MockHTTP(recorder: rec)
        http.on("POST", "/v1/docs/users/query",
                json: #"{"documents":[],"count":0}"#)

        let docs = makeDocs(http: http)
        let users = try docs.collection("users", of: Todo.self)

        _ = try await users
            .where("age", .greaterThan, .int(18))
            .where("status", .equalTo, .string("active"))
            .orderBy("name", ascending: true)
            .limit(50)
            .get()

        guard let entry = await rec.last() else { Issue.record("no call"); return }
        #expect(entry.method == "POST")
        #expect(entry.path == "/v1/docs/users/query")
        let body = try #require(entry.body)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(decoded?["limit"] as? Int == 50)
        let orderBy = decoded?["order_by"] as? [[String: Any]]
        #expect(orderBy?.first?["direction"] as? String == "asc")
    }

    @Test func cursorPaginationEncodesStartAfter() async throws {
        let rec = RecordedCall()
        let http = MockHTTP(recorder: rec)
        http.on("POST", "/v1/docs/users/query",
                json: #"{"documents":[],"count":0}"#)

        let docs = makeDocs(http: http)
        let users = try docs.collection("users", of: Todo.self)

        _ = try await users
            .orderBy("created_at")
            .startAfter([.string("2024-01-01")])
            .get()

        guard let body = await rec.last()?.body else { Issue.record("no body"); return }
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let after = obj?["start_after"] as? [Any]
        #expect(after?.count == 1)
    }

    @Test func collectionGroupUsesCollectionGroupPath() async throws {
        let rec = RecordedCall()
        let http = MockHTTP(recorder: rec)
        http.on("POST", "/v1/docs/collectionGroup/reviews/query",
                json: #"{"documents":[],"count":0}"#)

        let docs = makeDocs(http: http)
        _ = try await docs.collectionGroup("reviews", of: Todo.self)
            .where("rating", .greaterThanOrEqual, .int(4))
            .get()

        guard let entry = await rec.last() else { Issue.record("no call"); return }
        #expect(entry.path == "/v1/docs/collectionGroup/reviews/query")
    }
}

// MARK: - Field transforms

@Suite("Field transforms")
struct TransformTests {
    @Test func encodesIncrementAndArrayUnion() throws {
        let inc = FieldTransform.increment(field: "count", by: 1).toDTO()
        #expect(inc.type == "increment")
        #expect(inc.field == "count")

        let au = FieldTransform.arrayUnion(field: "tags", values: [.string("new")]).toDTO()
        #expect(au.type == "arrayUnion")
        let data = try JSONEncoder.palbaseDefault.encode(au)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let values = obj?["value"] as? [String]
        #expect(values == ["new"])
    }

    @Test func transformPathUsesColonSuffix() async throws {
        let rec = RecordedCall()
        let http = MockHTTP(recorder: rec)
        http.on("POST", "/v1/docs/users/u1:transform",
                json: #"{"id":"01HK","path":"users/u1","collection":"users","documentId":"u1","data":{"count":1},"metadata":{},"version":1,"createdAt":"2025-01-01T00:00:00.000Z","updatedAt":"2025-01-01T00:00:00.000Z"}"#)

        let docs = makeDocs(http: http)
        let ref = try docs.collection("users", of: Todo.self).document("u1")
        _ = try await ref.transform([
            .increment(field: "count", by: 1),
            .serverTimestamp(field: "updated_at")
        ])

        guard let entry = await rec.last() else { Issue.record("no call"); return }
        #expect(entry.path == "/v1/docs/users/u1:transform")
        #expect(entry.method == "POST")
    }
}

// MARK: - Aggregate

@Suite("Aggregate")
struct AggregateTests {
    @Test func countAggregation() async throws {
        let rec = RecordedCall()
        let http = MockHTTP(recorder: rec)
        http.on("POST", "/v1/docs/orders/aggregate",
                json: #"{"results":{"count":42}}"#)

        let docs = makeDocs(http: http)
        let count = try await docs.collection("orders", of: Todo.self)
            .where("status", .equalTo, .string("paid"))
            .count()
        #expect(count == 42)

        guard let body = await rec.last()?.body else { Issue.record("no body"); return }
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let aggs = obj?["aggregations"] as? [[String: Any]]
        #expect(aggs?.first?["op"] as? String == "count")
    }

    @Test func mixedAggregationResults() async throws {
        let rec = RecordedCall()
        let http = MockHTTP(recorder: rec)
        http.on("POST", "/v1/docs/orders/aggregate",
                json: #"{"results":{"total":10,"sum_amount":100.5,"avg_amount":10.05}}"#)

        let docs = makeDocs(http: http)
        let result = try await docs.collection("orders", of: Todo.self)
            .aggregate([
                .count(alias: "total"),
                .sum(field: "amount"),
                .avg(field: "amount")
            ])
        #expect(result.int("total") == 10)
        #expect(result.double("sum_amount") == 100.5)
    }
}

// MARK: - Batch

@Suite("Batch")
struct BatchTests {
    @Test func rejectsTooManyOperations() async throws {
        let http = MockHTTP(recorder: RecordedCall())
        let docs = makeDocs(http: http)

        let users = try docs.collection("users", of: Todo.self)
        var ops: [BatchOperation<Todo>] = []
        for i in 0..<(maxBatchOperations + 1) {
            let ref = try users.document("u\(i)")
            ops.append(.delete(ref: ref))
        }

        await #expect(throws: DocsError.self) {
            try await docs.batch(ops)
        }
    }

    @Test func batchEncodesOperationsPayload() async throws {
        let rec = RecordedCall()
        let http = MockHTTP(recorder: rec)
        http.on("POST", "/v1/docs/batch",
                json: #"{"results":[{"path":"users/u1","op":"set","success":true}]}"#)

        let docs = makeDocs(http: http)
        let users = try docs.collection("users", of: Todo.self)
        let u1 = try users.document("u1")
        let u2 = try users.document("u2")

        try await docs.batch([
            .set(ref: u1, data: Todo(id: "u1", title: "a", done: false)),
            .update(ref: u2, data: ["title": .string("b")]),
            .delete(ref: u2)
        ])

        guard let body = await rec.last()?.body else { Issue.record("no body"); return }
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let ops = obj?["operations"] as? [[String: Any]]
        #expect(ops?.count == 3)
        #expect(ops?[0]["op"] as? String == "set")
        #expect(ops?[1]["op"] as? String == "update")
        #expect(ops?[2]["op"] as? String == "delete")
    }

    @Test func batchGetReturnsSnapshotPerRef() async throws {
        let rec = RecordedCall()
        let http = MockHTTP(recorder: rec)
        let doc1 = #"{"id":"01","path":"users/u1","collection":"users","documentId":"u1","data":{"id":"u1","title":"a","done":false},"metadata":{},"version":1,"createdAt":"2025-01-01T00:00:00.000Z","updatedAt":"2025-01-01T00:00:00.000Z"}"#
        http.on("POST", "/v1/docs/batchGet",
                json: #"{"results":[{"path":"users/u1","found":true,"document":\#(doc1)},{"path":"users/u2","found":false}]}"#)

        let docs = makeDocs(http: http)
        let users = try docs.collection("users", of: Todo.self)
        let refs = [try users.document("u1"), try users.document("u2")]
        let snaps = try await docs.batchGet(refs)

        #expect(snaps.count == 2)
        #expect(snaps[0].exists)
        #expect(!snaps[1].exists)
        #expect(snaps[0].data()?.title == "a")
    }
}

// MARK: - Transactions

@Suite("Transactions")
struct TransactionTests {
    @Test func commitSendsQueuedOperations() async throws {
        let rec = RecordedCall()
        let http = MockHTTP(recorder: rec)
        http.on("POST", "/v1/docs/transaction/begin",
                json: #"{"transactionId":"tx_123"}"#)
        http.on("POST", "/v1/docs/transaction/commit", json: #"{"success":true}"#)

        let docs = makeDocs(http: http)
        let users = try docs.collection("users", of: Todo.self)
        let ref = try users.document("u1")

        try await docs.transaction { tx in
            try tx.set(ref, data: Todo(id: "u1", title: "t", done: false))
            try tx.update(ref, data: ["title": .string("t2")])
        }

        guard let commit = await rec.last() else { Issue.record("no commit"); return }
        #expect(commit.path == "/v1/docs/transaction/commit")
        let body = try JSONSerialization.jsonObject(with: #require(commit.body)) as? [String: Any]
        #expect(body?["transaction_id"] as? String == "tx_123")
        let ops = body?["operations"] as? [[String: Any]]
        #expect(ops?.count == 2)
    }

    @Test func rollbackOnThrownError() async throws {
        let rec = RecordedCall()
        let http = MockHTTP(recorder: rec)
        http.on("POST", "/v1/docs/transaction/begin",
                json: #"{"transactionId":"tx_77"}"#)
        http.on("POST", "/v1/docs/transaction/rollback", json: "{}")

        let docs = makeDocs(http: http)

        await #expect(throws: DocsError.self) {
            try await docs.transaction { _ in
                throw DocsError.transactionFailed("boom")
            }
        }

        guard let last = await rec.last() else { Issue.record("no call"); return }
        #expect(last.path == "/v1/docs/transaction/rollback")
    }
}

// MARK: - Snapshot listener

@Suite("Snapshot listener")
struct SnapshotListenerTests {
    @Test func subscribeEmitsInitialThenStreamEvents() async throws {
        let rec = RecordedCall()
        let http = MockHTTP(recorder: rec)
        http.on("POST", "/v1/docs/users/subscribe",
                json: #"{"subscriptionId":"sub_1","documents":[],"count":0,"streamUrl":"/v1/docs/subscriptions/sub_1/stream","expiresAt":"2025-01-01T00:00:00.000Z"}"#,
                status: 201)

        let sseBody = #"{"type":"added","path":"users/u1","document":{"id":"u1","title":"a","done":false}}"#
        http.onSSE("/v1/docs/subscriptions/sub_1/stream", events: [
            SSEEvent(event: "change", data: sseBody)
        ])
        http.on("DELETE", "/v1/docs/subscriptions/sub_1", json: "{}", status: 204)

        let docs = makeDocs(http: http)

        actor Collector {
            var snapshots: [QuerySnapshot<Todo>] = []
            func add(_ s: QuerySnapshot<Todo>) { snapshots.append(s) }
            func count() -> Int { snapshots.count }
        }
        let collector = Collector()

        let unsubscribe = await (try docs.collection("users", of: Todo.self))
            .where("done", .equalTo, .bool(false))
            .onSnapshot { snap in
                Task { await collector.add(snap) }
            }

        try await Task.sleep(nanoseconds: 300_000_000)
        unsubscribe()
        try await Task.sleep(nanoseconds: 150_000_000)

        let count = await collector.count()
        #expect(count >= 1)

        let entries = await rec.entries
        let subscribeCalls = entries.filter { $0.path.contains("/users/subscribe") }
        #expect(!subscribeCalls.isEmpty)
        let deletes = entries.filter { $0.method == "DELETE" && $0.path.contains("/subscriptions/sub_1") }
        #expect(!deletes.isEmpty)
    }
}

// MARK: - Error mapping

@Suite("Error mapping")
struct ErrorMappingTests {
    @Test func networkMapped() {
        if case .network(let m) = DocsError.from(transport: .network(message: "no route")) {
            #expect(m == "no route")
        } else {
            Issue.record("wrong case")
        }
    }

    @Test func rateLimitedMapped() {
        if case .rateLimited(let r) = DocsError.from(transport: .rateLimited(retryAfter: 7)) {
            #expect(r == 7)
        } else {
            Issue.record("wrong case")
        }
    }

    @Test func http404BecomesDocumentNotFound() {
        let e = DocsError.from(transport: .http(status: 404, code: "x", message: "users/u1", requestId: nil))
        if case .documentNotFound = e {} else { Issue.record("expected documentNotFound") }
    }

    @Test func notConfiguredRoundTrips() {
        if case .notConfigured = DocsError.from(transport: .notConfigured) {} else {
            Issue.record("expected notConfigured")
        }
    }

    @Test func encodingMapped() {
        if case .encoding = DocsError.from(transport: .encoding(message: "x")) {} else {
            Issue.record("expected encoding")
        }
    }

    @Test func serverMapped() {
        if case .serverError(let s, _) = DocsError.from(transport: .server(status: 502, message: "oops")) {
            #expect(s == 502)
        } else { Issue.record("expected serverError") }
    }
}
