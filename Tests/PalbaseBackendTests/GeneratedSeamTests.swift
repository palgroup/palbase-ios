import Testing
import Foundation
@testable import PalbaseBackend

// MARK: - "As-if-generated" code
//
// This mirrors exactly what `palbase backend types` (CLI) emits for a
// project with `endpoints/rooms/create.ts` and `endpoints/rooms/[id]/get.ts`.
// It is hand-written here to (1) lock the runtime seam generated code
// depends on, and (2) act as the canonical template + golden example. The
// generator produces this shape from the project's OpenAPI document.
//
// Design: each path segment becomes a namespace value hanging off
// `PalbaseBackend`; leaf operations are async throwing methods that lower
// to `call(_:_:)` / `upload(...)`. Input/Output are plain Codable structs.

enum Rooms {
    struct CreateInput: Encodable, Sendable {
        let name: String
        let capacity: Int?
    }
    struct CreateOutput: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let capacity: Int?
    }
    struct GetOutput: Decodable, Sendable, Equatable {
        let id: String
        let name: String
    }
}

/// Generated namespace, bound to a backend client instance.
struct RoomsNamespace: Sendable {
    let client: PalbaseBackend

    func create(_ input: Rooms.CreateInput) async throws(BackendError) -> Rooms.CreateOutput {
        try await client.call("rooms.create", input)
    }

    func get(id: String) async throws(BackendError) -> Rooms.GetOutput {
        struct Args: Encodable, Sendable { let id: String }
        return try await client.call("rooms.id.get", Args(id: id))
    }
}

extension PalbaseBackend {
    /// Generated accessor — `pb.backend.rooms.create(...)`.
    var rooms: RoomsNamespace { RoomsNamespace(client: self) }
}

// MARK: - Tests

@Suite("Generated namespaced seam")
struct GeneratedSeamTests {
    @Test func namespacedCreateLowersToRpc() async throws {
        let recorder = RecordedCall()
        let backend = PalbaseBackend(
            http: MockBackendHTTP(recorder: recorder, responder: { _ in
                StubResponse(status: 201, body: Data(#"{"id":"r1","name":"lobby","capacity":50}"#.utf8))
            }),
            tokens: TokenManager()
        )

        let room = try await backend.rooms.create(.init(name: "lobby", capacity: 50))
        #expect(room == Rooms.CreateOutput(id: "r1", name: "lobby", capacity: 50))

        let snap = await recorder.snapshot()
        #expect(snap.path == "/rpc/rooms.create")
        let bodyStr = snap.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(bodyStr.contains("\"name\":\"lobby\""))
        #expect(bodyStr.contains("\"capacity\":50"))
    }

    @Test func namespacedGetWithPathArg() async throws {
        let recorder = RecordedCall()
        let backend = PalbaseBackend(
            http: MockBackendHTTP(recorder: recorder, responder: { _ in
                StubResponse(status: 200, body: Data(#"{"id":"r9","name":"x"}"#.utf8))
            }),
            tokens: TokenManager()
        )
        let room = try await backend.rooms.get(id: "r9")
        #expect(room == Rooms.GetOutput(id: "r9", name: "x"))
        let snap = await recorder.snapshot()
        #expect(snap.path == "/rpc/rooms.id.get")
    }

    @Test func namespacedErrorIsTyped() async {
        let recorder = RecordedCall()
        let backend = PalbaseBackend(
            http: MockBackendHTTP(recorder: recorder, responder: { _ in
                StubResponse(status: 404, body: Data(#"{"error":"room_not_found","error_description":"no","status":404}"#.utf8))
            }),
            tokens: TokenManager()
        )
        do {
            _ = try await backend.rooms.get(id: "missing")
            Issue.record("expected throw")
        } catch let error {
            guard case .server(let code, _, _, _) = error else {
                Issue.record("expected .server, got \(error)"); return
            }
            #expect(code == "room_not_found")
        }
    }
}
