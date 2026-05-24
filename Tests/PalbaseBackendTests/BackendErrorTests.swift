import Testing
import Foundation
@testable import PalbaseBackend

// MARK: - Mock transport

/// Records the last request and replays a pre-baked raw response. Mirrors
/// the established MockHTTP pattern in PalbaseDBTests, but implements the
/// non-throwing `requestRawBodyResult` the backend module relies on so we
/// can assert error-envelope mapping on non-2xx responses.
actor RecordedCall {
    private(set) var method = ""
    private(set) var path = ""
    private(set) var headers: [String: String] = [:]
    private(set) var body: Data?
    private(set) var count = 0
    private(set) var idempotencyKeys: [String] = []

    func record(method: String, path: String, headers: [String: String], body: Data?) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.count += 1
        if let key = headers["Idempotency-Key"] { idempotencyKeys.append(key) }
    }

    func snapshot() -> (method: String, path: String, headers: [String: String], body: Data?, count: Int, idempotencyKeys: [String]) {
        (method, path, headers, body, count, idempotencyKeys)
    }
}

/// A scripted response: status + body + headers.
struct StubResponse: Sendable {
    let status: Int
    let body: Data
    let headers: [String: String]
    init(status: Int = 200, body: Data = Data("{}".utf8), headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }
}

struct MockBackendHTTP: HTTPRequesting {
    let recorder: RecordedCall
    let responder: @Sendable (Int) -> StubResponse

    init(recorder: RecordedCall, responder: @escaping @Sendable (Int) -> StubResponse = { _ in StubResponse() }) {
        self.recorder = recorder
        self.responder = responder
    }

    func request<T: Decodable & Sendable>(
        method: String, path: String, body: (any Encodable & Sendable)?, headers: [String: String]
    ) async throws(PalbaseCoreError) -> T {
        let (data, _, _) = try await requestRawBodyResult(method: method, path: path, body: nil, headers: headers)
        do { return try JSONDecoder.palbaseDefault.decode(T.self, from: data) }
        catch { throw PalbaseCoreError.decoding(message: error.localizedDescription) }
    }

    func requestVoid(
        method: String, path: String, body: (any Encodable & Sendable)?, headers: [String: String]
    ) async throws(PalbaseCoreError) {
        _ = try await requestRawBodyResult(method: method, path: path, body: nil, headers: headers)
    }

    func requestRaw(
        method: String, path: String, body: (any Encodable & Sendable)?, headers: [String: String]
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int) {
        let (data, status, _) = try await requestRawBodyResult(method: method, path: path, body: nil, headers: headers)
        return (data, status)
    }

    func requestRawBodyResult(
        method: String, path: String, body: Data?, headers: [String: String]
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int, headers: [String: String]) {
        let count = await recorder.count
        await recorder.record(method: method, path: path, headers: headers, body: body)
        let stub = responder(count + 1)
        return (stub.body, stub.status, stub.headers)
    }

    func uploadRawBodyResult(
        method: String, path: String, body: Data, headers: [String: String],
        onProgress: (@Sendable (_ sent: Int64, _ total: Int64) -> Void)?
    ) async throws(PalbaseCoreError) -> (data: Data, status: Int, headers: [String: String]) {
        // Simulate two progress ticks so callers can assert wiring.
        let total = Int64(body.count)
        onProgress?(total / 2, total)
        onProgress?(total, total)
        let count = await recorder.count
        await recorder.record(method: method, path: path, headers: headers, body: body)
        let stub = responder(count + 1)
        return (stub.body, stub.status, stub.headers)
    }
}

// MARK: - Fixtures

struct CheckoutInput: Encodable, Sendable { let items: [String] }
struct CheckoutOutput: Decodable, Sendable, Equatable { let orderId: String }

private func makeBackend(
    recorder: RecordedCall,
    responder: @escaping @Sendable (Int) -> StubResponse,
    attestor: AppAttesting? = nil
) -> PalbaseBackend {
    PalbaseBackend(http: MockBackendHTTP(recorder: recorder, responder: responder),
                   tokens: TokenManager(),
                   attestor: attestor)
}

// MARK: - Happy path

@Suite("Typed call")
struct TypedCallTests {
    @Test func postsToRpcPathWithBody() async throws {
        let recorder = RecordedCall()
        let backend = makeBackend(recorder: recorder, responder: { _ in
            StubResponse(status: 200, body: Data(#"{"order_id":"ord_1"}"#.utf8))
        })

        let out: CheckoutOutput = try await backend.call("checkout", CheckoutInput(items: ["a", "b"]))
        #expect(out == CheckoutOutput(orderId: "ord_1"))

        let snap = await recorder.snapshot()
        #expect(snap.method == "POST")
        #expect(snap.path == "/rpc/checkout")
        let bodyStr = snap.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(bodyStr.contains("\"items\""))
        #expect(snap.headers["Content-Type"] == "application/json")
    }

    @Test func decodesSnakeToCamel() async throws {
        let recorder = RecordedCall()
        let backend = makeBackend(recorder: recorder, responder: { _ in
            StubResponse(status: 201, body: Data(#"{"order_id":"ord_42"}"#.utf8))
        })
        let out: CheckoutOutput = try await backend.call("checkout", CheckoutInput(items: ["x"]))
        #expect(out.orderId == "ord_42")
    }

    @Test func decodeFailureSurfacesTyped() async {
        let recorder = RecordedCall()
        let backend = makeBackend(recorder: recorder, responder: { _ in
            StubResponse(status: 200, body: Data(#"{"unexpected":true}"#.utf8))
        })
        await #expect(throws: BackendError.self) {
            let _: CheckoutOutput = try await backend.call("checkout", CheckoutInput(items: []))
        }
    }
}

// MARK: - Error envelope mapping

@Suite("Error envelope mapping")
struct ErrorEnvelopeTests {
    @Test func serverErrorMapsToServerCase() async {
        let recorder = RecordedCall()
        let envelope = #"{"error":"room_not_found","error_description":"Room does not exist","status":404,"request_id":"req_9"}"#
        let backend = makeBackend(recorder: recorder, responder: { _ in
            StubResponse(status: 404, body: Data(envelope.utf8))
        })

        do {
            let _: CheckoutOutput = try await backend.call("rooms.get", CheckoutInput(items: []))
            Issue.record("expected throw")
        } catch let error as BackendError {
            guard case .server(let code, let status, let message, let rid) = error else {
                Issue.record("expected .server, got \(error)"); return
            }
            #expect(code == "room_not_found")
            #expect(status == 404)
            #expect(message == "Room does not exist")
            #expect(rid == "req_9")
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test func validationErrorCarriesFields() async {
        let recorder = RecordedCall()
        let envelope = #"""
        {"error":"validation_error","error_description":"Input validation failed","status":400,"request_id":"req_1","details":[{"field":"name","message":"String must be at least 3 characters"},{"field":"email","message":"Invalid email"}]}
        """#
        let backend = makeBackend(recorder: recorder, responder: { _ in
            StubResponse(status: 400, body: Data(envelope.utf8))
        })

        do {
            let _: CheckoutOutput = try await backend.call("rooms.create", CheckoutInput(items: []))
            Issue.record("expected throw")
        } catch let error as BackendError {
            guard case .validation(let fields, let rid) = error else {
                Issue.record("expected .validation, got \(error)"); return
            }
            #expect(fields.count == 2)
            #expect(fields[0] == FieldError(field: "name", message: "String must be at least 3 characters"))
            #expect(fields[1].field == "email")
            #expect(rid == "req_1")
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test func rateLimitedReadsRetryAfter() async {
        let recorder = RecordedCall()
        let backend = makeBackend(recorder: recorder, responder: { _ in
            StubResponse(status: 429, body: Data("{}".utf8), headers: ["Retry-After": "12"])
        })
        do {
            let _: CheckoutOutput = try await backend.call("checkout", CheckoutInput(items: []))
            Issue.record("expected throw")
        } catch let error as BackendError {
            guard case .rateLimited(let retryAfter) = error else {
                Issue.record("expected .rateLimited, got \(error)"); return
            }
            #expect(retryAfter == 12)
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test func unauthorizedMapsToUnauthorized() async {
        let recorder = RecordedCall()
        let envelope = #"{"error":"unauthorized","error_description":"no","status":401,"request_id":"req_u"}"#
        let backend = makeBackend(recorder: recorder, responder: { _ in
            StubResponse(status: 401, body: Data(envelope.utf8))
        })
        do {
            let _: CheckoutOutput = try await backend.call("me", CheckoutInput(items: []))
            Issue.record("expected throw")
        } catch let error as BackendError {
            guard case .unauthorized(let rid) = error else {
                Issue.record("expected .unauthorized, got \(error)"); return
            }
            #expect(rid == "req_u")
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test func codesAreStable() {
        #expect(BackendError.notConfigured.code == "not_configured")
        #expect(BackendError.validation(fields: [], requestId: nil).code == "validation_error")
        #expect(BackendError.rateLimited(retryAfter: nil).code == "rate_limited")
        #expect(BackendError.server(code: "x", status: 500, message: "m", requestId: nil).code == "x")
    }
}

// MARK: - Idempotency (Task #3)

@Suite("Idempotency")
struct IdempotencyTests {
    @Test func mutationGetsIdempotencyKey() async throws {
        let recorder = RecordedCall()
        let backend = makeBackend(recorder: recorder, responder: { _ in
            StubResponse(status: 200, body: Data(#"{"order_id":"o"}"#.utf8))
        })
        let _: CheckoutOutput = try await backend.call("checkout", CheckoutInput(items: ["a"]))
        let snap = await recorder.snapshot()
        #expect(snap.headers["Idempotency-Key"] != nil)
        #expect(snap.headers["Idempotency-Key"]?.hasPrefix("idmp_") == true)
    }

    @Test func callerKeyIsNotOverridden() async throws {
        let recorder = RecordedCall()
        let backend = makeBackend(recorder: recorder, responder: { _ in
            StubResponse(status: 200, body: Data(#"{"order_id":"o"}"#.utf8))
        })
        let _: CheckoutOutput = try await backend.call(
            "checkout", CheckoutInput(items: ["a"]),
            headers: ["Idempotency-Key": "my-key"]
        )
        let snap = await recorder.snapshot()
        #expect(snap.headers["Idempotency-Key"] == "my-key")
    }

    @Test func keysAreUniquePerCall() {
        let k1 = PalbaseBackend.newIdempotencyKey()
        let k2 = PalbaseBackend.newIdempotencyKey()
        #expect(k1 != k2)
        #expect(k1.hasPrefix("idmp_"))
    }
}
