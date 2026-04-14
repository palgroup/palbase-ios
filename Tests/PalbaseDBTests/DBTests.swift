import Testing
import Foundation
@testable import PalbaseDB

// MARK: - Helpers

/// Records the most recent HTTP call so we can make assertions about what the
/// builder constructed.
actor RecordedCall {
    var method: String = ""
    var path: String = ""
    var headers: [String: String] = [:]
    var body: Data? = nil
    var count: Int = 0

    func record(method: String, path: String, headers: [String: String], body: Data?) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.count += 1
    }

    func snapshot() -> (method: String, path: String, headers: [String: String], body: Data?, count: Int) {
        (method, path, headers, body, count)
    }
}

/// Mock HTTPRequesting that records requests and replays a pre-baked response.
struct MockHTTP: HTTPRequesting {
    let recorder: RecordedCall
    let response: @Sendable () -> (Data, Int)

    init(recorder: RecordedCall, response: @escaping @Sendable () -> (Data, Int) = { (Data("[]".utf8), 200) }) {
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
        let encoded: Data?
        if let body = body {
            do {
                encoded = try JSONEncoder.palbaseDefault.encode(body)
            } catch {
                throw PalbaseCoreError.encoding(message: error.localizedDescription)
            }
        } else {
            encoded = nil
        }
        await recorder.record(method: method, path: path, headers: headers, body: encoded)
        let (data, status) = response()
        if !(200..<300).contains(status) {
            throw PalbaseCoreError.http(status: status, code: "test_error", message: "mock \(status)")
        }
        return (data, status)
    }
}

struct Todo: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let done: Bool
}

// MARK: - Tests

@Suite("Validation")
struct ValidationTests {
    @Test func tableName_rejectsInvalid() {
        #expect(throws: DBError.self) {
            try DBValidator.validateTable("1bad")
        }
        #expect(throws: DBError.self) {
            try DBValidator.validateTable("bad name")
        }
    }

    @Test func tableName_acceptsValid() throws {
        try DBValidator.validateTable("todos")
        try DBValidator.validateTable("public.todos")
        try DBValidator.validateTable("_private")
    }

    @Test func column_rejectsInvalid() {
        #expect(throws: DBError.self) { try DBValidator.validateColumn("drop table") }
        #expect(throws: DBError.self) { try DBValidator.validateColumn("col'--") }
    }

    @Test func column_acceptsValid() throws {
        try DBValidator.validateColumn("created_at")
        try DBValidator.validateColumn("meta->#tags")
    }

    @Test func fnName_rejectsInvalid() {
        #expect(throws: DBError.self) { try DBValidator.validateFunctionName("1abc") }
        #expect(throws: DBError.self) { try DBValidator.validateFunctionName("bad name") }
    }

    @Test func txId_rejectsInvalid() {
        #expect(throws: DBError.self) { try DBValidator.validateTransactionId("../secret") }
    }

    @Test func txId_acceptsValid() throws {
        try DBValidator.validateTransactionId("tx_abc123")
        try DBValidator.validateTransactionId("abc-def_1")
    }
}

@Suite("QueryBuilder URL & headers")
struct QueryBuilderTests {
    @Test func selectFilterOrderLimit() async throws {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder)
        let qb = QueryBuilder<Todo>(http: http, table: "todos", basePath: "/v1/db/todos")

        _ = try await qb
            .select()
            .eq("done", false)
            .order("created_at", ascending: false)
            .limit(10)
            .execute()

        let snap = await recorder.snapshot()
        #expect(snap.method == "GET")
        #expect(snap.path.hasPrefix("/v1/db/todos?"))
        #expect(snap.path.contains("select=*"))
        #expect(snap.path.contains("done=eq.false"))
        #expect(snap.path.contains("order=created_at.desc"))
        #expect(snap.path.contains("limit=10"))
    }

    @Test func rangeHeader() async throws {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder)
        let qb = QueryBuilder<Todo>(http: http, table: "todos", basePath: "/v1/db/todos")

        _ = try await qb.range(from: 0, to: 24).execute()
        let snap = await recorder.snapshot()
        #expect(snap.headers["Range"] == "0-24")
    }

    @Test func insertSetsMethodAndPreferHeader() async throws {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder, response: { (Data("[]".utf8), 201) })
        let qb = QueryBuilder<Todo>(http: http, table: "todos", basePath: "/v1/db/todos")

        _ = try await qb
            .insert(Todo(id: "t1", title: "buy milk", done: false))
            .execute()

        let snap = await recorder.snapshot()
        #expect(snap.method == "POST")
        #expect(snap.headers["Prefer"] == "return=representation")
        // body should contain snake_case conversion of the struct
        let bodyStr = snap.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(bodyStr.contains("\"title\":\"buy milk\""))
    }

    @Test func upsertPreferHeader() async throws {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder, response: { (Data("[]".utf8), 200) })
        let qb = QueryBuilder<Todo>(http: http, table: "todos", basePath: "/v1/db/todos")
        _ = try await qb.upsert(Todo(id: "t1", title: "x", done: false)).execute()
        let snap = await recorder.snapshot()
        #expect(snap.method == "POST")
        #expect(snap.headers["Prefer"] == "resolution=merge-duplicates,return=representation")
    }

    @Test func updateSetsPatch() async throws {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder, response: { (Data("[]".utf8), 200) })
        let qb = QueryBuilder<Todo>(http: http, table: "todos", basePath: "/v1/db/todos")
        struct Patch: Encodable, Sendable { let done: Bool }
        _ = try await qb.update(Patch(done: true)).eq("id", "t1").execute()
        let snap = await recorder.snapshot()
        #expect(snap.method == "PATCH")
        #expect(snap.path.contains("id=eq.t1"))
        #expect(snap.headers["Prefer"] == "return=representation")
    }

    @Test func deleteSetsMethod() async throws {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder, response: { (Data("[]".utf8), 200) })
        let qb = QueryBuilder<Todo>(http: http, table: "todos", basePath: "/v1/db/todos")
        _ = try await qb.delete().eq("id", "t1").execute()
        let snap = await recorder.snapshot()
        #expect(snap.method == "DELETE")
        #expect(snap.path.contains("id=eq.t1"))
    }

    @Test func single_setsAcceptHeader() async throws {
        let recorder = RecordedCall()
        let payload = Data(#"{"id":"t1","title":"x","done":false}"#.utf8)
        let http = MockHTTP(recorder: recorder, response: { (payload, 200) })
        let qb = QueryBuilder<Todo>(http: http, table: "todos", basePath: "/v1/db/todos")
        let one = try await qb.eq("id", "t1").single().execute()
        #expect(one.id == "t1")
        let snap = await recorder.snapshot()
        #expect(snap.headers["Accept"] == "application/vnd.pgrst.object+json")
    }

    @Test func maybeSingle_returnsNilOn406() async throws {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder, response: { (Data(), 406) })
        let qb = QueryBuilder<Todo>(http: http, table: "todos", basePath: "/v1/db/todos")
        let result = try await qb.eq("id", "missing").maybeSingle().execute()
        #expect(result == nil)
    }

    @Test func in_encodesListWithParens() async throws {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder)
        let qb = QueryBuilder<Todo>(http: http, table: "todos", basePath: "/v1/db/todos")
        _ = try await qb.in_("id", values: ["a", "b", "c"]).execute()
        let snap = await recorder.snapshot()
        #expect(snap.path.contains("id=in.(a,b,c)"))
    }

    @Test func filterEncodesReserved() async throws {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder)
        let qb = QueryBuilder<Todo>(http: http, table: "todos", basePath: "/v1/db/todos")
        _ = try await qb.eq("title", "a&b").execute()
        let snap = await recorder.snapshot()
        #expect(snap.path.contains("title=eq.a%26b"))
    }

    @Test func invalidTable_fromRoot() async {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder)
        let tokens = TokenManager()
        let db = PalbaseDB(http: http, tokens: tokens)
        #expect(throws: DBError.self) {
            let _: QueryBuilder<Todo> = try db.from("1bad")
        }
    }
}

@Suite("RPC")
struct RPCTests {
    @Test func rpcCallsCorrectPath() async throws {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder, response: { (Data("42".utf8), 200) })
        let tokens = TokenManager()
        let db = PalbaseDB(http: http, tokens: tokens)

        struct P: Encodable, Sendable { let a: Int }
        let r: Int = try await db.rpc("compute_answer", params: P(a: 1))
        #expect(r == 42)

        let snap = await recorder.snapshot()
        #expect(snap.method == "POST")
        #expect(snap.path == "/v1/db/rpc/compute_answer")
    }

    @Test func rpcRejectsBadName() async {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder)
        let tokens = TokenManager()
        let db = PalbaseDB(http: http, tokens: tokens)
        await #expect(throws: DBError.self) {
            let _: Int = try await db.rpc("bad name")
        }
    }
}

@Suite("Error mapping")
struct ErrorMappingTests {
    @Test func from_transport_http() {
        let err = PalbaseCoreError.http(status: 401, code: "unauthorized", message: "no", requestId: "r1")
        let mapped = DBError.from(transport: err)
        guard case .http(let status, let code, _, let rid) = mapped else {
            Issue.record("expected .http"); return
        }
        #expect(status == 401)
        #expect(code == "unauthorized")
        #expect(rid == "r1")
    }

    @Test func from_transport_rateLimited() {
        let err = PalbaseCoreError.rateLimited(retryAfter: 5)
        let mapped = DBError.from(transport: err)
        if case .rateLimited(let r) = mapped { #expect(r == 5) } else { Issue.record("expected .rateLimited") }
    }

    @Test func from_transport_notConfigured() {
        let mapped = DBError.from(transport: .notConfigured)
        if case .notConfigured = mapped {} else { Issue.record("expected .notConfigured") }
    }

    @Test func codes_areStable() {
        #expect(DBError.notConfigured.code == "not_configured")
        #expect(DBError.invalidTable("x").code == "invalid_table")
        #expect(DBError.transactionTimeout.code == "transaction_timeout")
    }
}

@Suite("Transaction")
struct TransactionTests {
    @Test func beginCommit_flow() async throws {
        struct Resp: Sendable {
            let counter: AtomicCounter
            init() { self.counter = AtomicCounter() }
        }

        let recorder = RecordedCall()
        let counter = AtomicCounter()
        let http = MockHTTP(recorder: recorder, response: { @Sendable in
            let n = counter.increment()
            if n == 1 {
                return (Data(#"{"tx_id":"tx_abc"}"#.utf8), 200)  // begin
            }
            // Subsequent calls: either queries or commit — return empty success
            return (Data("[]".utf8), 200)
        })
        let tokens = TokenManager()
        let db = PalbaseDB(http: http, tokens: tokens)

        try await db.transaction { tx in
            let qb: QueryBuilder<Todo> = try tx.from("todos")
            _ = try await qb.select().execute()
        }

        let snap = await recorder.snapshot()
        // Expect: begin, select, commit → 3 calls
        #expect(snap.count == 3)
    }

    @Test func rollbackOnThrow() async {
        let recorder = RecordedCall()
        let counter = AtomicCounter()
        let http = MockHTTP(recorder: recorder, response: { @Sendable in
            let n = counter.increment()
            if n == 1 { return (Data(#"{"tx_id":"tx_xyz"}"#.utf8), 200) }
            return (Data("[]".utf8), 200)
        })
        let tokens = TokenManager()
        let db = PalbaseDB(http: http, tokens: tokens)

        do {
            try await db.transaction { _ in
                throw DBError.transactionFailed("boom")
            }
            Issue.record("expected throw")
        } catch {
            // ok
        }

        let snap = await recorder.snapshot()
        // begin + rollback → 2 calls
        #expect(snap.count == 2)
        #expect(snap.path.contains("/rollback"))
    }

    @Test func rejectInvalidTxIdFromServer() async {
        let recorder = RecordedCall()
        let http = MockHTTP(recorder: recorder, response: { (Data(#"{"tx_id":"../evil"}"#.utf8), 200) })
        let tokens = TokenManager()
        let db = PalbaseDB(http: http, tokens: tokens)

        await #expect(throws: DBError.self) {
            try await db.transaction { _ in }
        }
    }
}

/// Tiny thread-safe counter for deterministic sequencing in mocks.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
