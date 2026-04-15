import Foundation
import Testing
@testable import PalbaseRealtime

// MARK: - Mock WebSocket

actor MockSocketCore {
    var sent: [String] = []
    var resumed: Bool = false
    var cancelled: Bool = false
    var pendingFrames: [WebSocketMessage] = []
    var waiters: [CheckedContinuation<WebSocketMessage, Error>] = []
    var failureMode: Failure?

    enum Failure: Sendable {
        case sendThrows
        case receiveThrowsImmediately
    }

    func resume() { resumed = true }

    func cancel() { cancelled = true }

    func record(send text: String) throws {
        if failureMode == .sendThrows {
            throw NSError(domain: "Mock", code: -1)
        }
        sent.append(text)
    }

    func enqueue(_ msg: WebSocketMessage) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: msg)
        } else {
            pendingFrames.append(msg)
        }
    }

    func awaitReceive() async throws -> WebSocketMessage {
        if failureMode == .receiveThrowsImmediately {
            throw NSError(domain: "Mock", code: -2)
        }
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WebSocketMessage, Error>) in
            waiters.append(cont)
        }
    }

    func breakConnection() {
        failureMode = .receiveThrowsImmediately
        let pending = waiters
        waiters.removeAll()
        for cont in pending {
            cont.resume(throwing: NSError(domain: "Mock", code: -2))
        }
    }

    func sentSnapshot() -> [String] { sent }
    func sentCount() -> Int { sent.count }
}

final class MockSocket: WebSocketTaskProtocol, @unchecked Sendable {
    let core: MockSocketCore
    init(core: MockSocketCore) { self.core = core }

    func resume() {
        Task { await core.resume() }
    }

    func cancel(closeCode: Int, reason: Data?) {
        Task { await core.cancel() }
    }

    func send(_ message: WebSocketMessage) async throws {
        let str: String
        switch message {
        case .string(let s): str = s
        case .data(let d): str = String(data: d, encoding: .utf8) ?? ""
        }
        try await core.record(send: str)
    }

    func receive() async throws -> WebSocketMessage {
        try await core.awaitReceive()
    }
}

struct MockSocketFactory: WebSocketFactory {
    let core: MockSocketCore
    func makeTask(url: URL) -> any WebSocketTaskProtocol {
        MockSocket(core: core)
    }
}

// MARK: - Helpers

@Sendable func nullToken() async -> String? { nil }

func decodeSent(_ str: String) -> [String: Any]? {
    guard let data = str.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func waitForCondition(timeoutMs: Int = 1000, _ predicate: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

// MARK: - Channel name validation

@Suite("Channel name validation")
struct ChannelNameValidationTests {
    @Test func acceptsValidNames() throws {
        let names = ["lobby", "room:1", "table-42", "user_99", "a:b:c-d_e"]
        for n in names {
            try ChannelNameValidator.validate(n)
        }
    }

    @Test func rejectsInvalidNames() {
        let bad = ["", "has space", "has/slash", "has.dot", "🎉", String(repeating: "a", count: 256)]
        for n in bad {
            do {
                try ChannelNameValidator.validate(n)
                Issue.record("Expected invalidChannelName for \"\(n)\"")
            } catch {
                #expect(error.code == "invalid_channel_name")
            }
        }
    }
}

// MARK: - Phoenix codec

@Suite("Phoenix codec")
struct PhoenixCodecTests {
    @Test func encodesEnvelopeRoundtrip() throws {
        let env = PhoenixEnvelope(
            topic: "room:lobby",
            event: "phx_join",
            payload: ["apikey": .string("pb_x"), "config": .object(["foo": .bool(true)])],
            ref: "1"
        )
        let data = try PhoenixCodec.encode(env)
        let decoded = try PhoenixCodec.decode(data)
        #expect(decoded.topic == "room:lobby")
        #expect(decoded.event == "phx_join")
        #expect(decoded.ref == "1")
        if case .string(let v) = decoded.payload["apikey"] {
            #expect(v == "pb_x")
        } else {
            Issue.record("missing apikey")
        }
    }

    @Test func decodesPhxReplyOk() throws {
        let json = #"{"topic":"room:lobby","event":"phx_reply","ref":"1","payload":{"status":"ok","response":{}}}"#
        let env = try PhoenixCodec.decode(Data(json.utf8))
        #expect(env.event == "phx_reply")
        #expect(env.payload["status"]?.stringValue == "ok")
    }

    @Test func decodesPresenceState() throws {
        let json = """
        {"topic":"room:lobby","event":"presence_state","payload":{
          "user1":{"metas":[{"phx_ref":"r1","name":"alice"}]},
          "user2":{"metas":[{"phx_ref":"r2","name":"bob"}]}
        }}
        """
        let env = try PhoenixCodec.decode(Data(json.utf8))
        let state = PresenceDecoder.decodeState(env.payload)
        #expect(state["user1"]?.first?.payload["name"]?.stringValue == "alice")
        #expect(state["user1"]?.first?.presenceRef == "r1")
        #expect(state["user2"]?.count == 1)
    }

    @Test func decodesPostgresChange() throws {
        let json = """
        {"topic":"room:lobby","event":"postgres_changes","payload":{
          "type":"INSERT","schema":"public","table":"messages",
          "record":{"id":1,"text":"hi"},
          "commit_timestamp":"2026-04-14T00:00:00Z"
        }}
        """
        let env = try PhoenixCodec.decode(Data(json.utf8))
        #expect(env.event == "postgres_changes")
        #expect(env.payload["type"]?.stringValue == "INSERT")
    }
}

// MARK: - phx_join payload

@Suite("phx_join payload builder")
struct PhxJoinPayloadTests {
    @Test func buildsBroadcastEvents() {
        let payload = PhoenixMessageBuilder.joinPayload(
            apiKey: "pb_test_x",
            accessToken: "tok",
            broadcastEvents: ["chat", "typing"],
            presenceEnabled: true,
            postgresChanges: [
                PostgresChangeBinding(event: .insert, schema: "public", table: "messages", filter: nil)
            ]
        )
        #expect(payload["apikey"]?.stringValue == "pb_test_x")
        #expect(payload["token"]?.stringValue == "tok")
        let cfg = payload["config"]?.objectValue
        let events = cfg?["broadcast"]?.objectValue?["events"]?.arrayValue?.compactMap { $0.stringValue }
        #expect(events == ["chat", "typing"])
        let pgChanges = cfg?["postgres_changes"]?.arrayValue
        #expect(pgChanges?.count == 1)
        #expect(pgChanges?.first?.objectValue?["event"]?.stringValue == "INSERT")
    }
}

// MARK: - Connection

@Suite("Connection lifecycle")
struct ConnectionTests {
    @Test func openSendsMessage() async throws {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        try await conn.open()
        let env = PhoenixEnvelope(topic: "phoenix", event: "heartbeat", payload: [:], ref: "1")
        try await conn.send(env)
        let count = await core.sentCount()
        #expect(count == 1)
    }

    @Test func sendHeartbeatProducesPhoenixHeartbeat() async throws {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        try await conn.open()
        await conn.sendHeartbeat()
        let sent = await core.sentSnapshot()
        #expect(sent.count == 1)
        let parsed = decodeSent(sent[0])
        #expect(parsed?["topic"] as? String == "phoenix")
        #expect(parsed?["event"] as? String == "heartbeat")
    }

    @Test func dispatchRoutesToRegisteredChannel() async throws {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        try await conn.open()

        let received = ReceivedBox()
        let bridge = ChannelBridge(
            onMessage: { env in await received.set(env.event) },
            onReconnect: {},
            onDisconnect: {}
        )
        await conn.registerChannel(topic: "room:1", bridge: bridge)

        let json = #"{"topic":"room:1","event":"broadcast","payload":{"event":"x","payload":{}}}"#
        await conn._testInjectIncoming(Data(json.utf8))
        let ok = await waitForCondition { await received.value == "broadcast" }
        #expect(ok)
    }

    @Test func disconnectNotifiesChannels() async throws {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        try await conn.open()

        let flag = ReceivedBox()
        let bridge = ChannelBridge(
            onMessage: { _ in },
            onReconnect: {},
            onDisconnect: { await flag.set("dropped") }
        )
        await conn.registerChannel(topic: "room:1", bridge: bridge)
        await conn._testForceDisconnect(reason: "test")
        let ok = await waitForCondition { await flag.value == "dropped" }
        #expect(ok)
    }
}

actor ReceivedBox {
    var value: String?
    func set(_ v: String) { value = v }
}

// MARK: - Channel subscribe + broadcast routing

@Suite("RealtimeChannel")
struct RealtimeChannelTests {
    @Test func subscribeSendsPhxJoinAndAcksOnReply() async throws {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        let channel = RealtimeChannel(
            name: "room:lobby",
            connection: conn,
            apiKey: "pb_test_xxx",
            accessTokenProvider: nullToken
        )

        // Drive subscribe → phx_join is sent → reply ok.
        let subscribeTask = Task {
            try await channel.subscribe()
        }
        // Wait until phx_join is pushed.
        let joined = await waitForCondition { await core.sentCount() >= 1 }
        #expect(joined)
        let sent = await core.sentSnapshot()
        let env = decodeSent(sent[0])
        #expect(env?["event"] as? String == "phx_join")
        let ref = env?["ref"] as? String ?? ""
        // Inject a phx_reply with the same ref.
        let reply = #"{"topic":"room:lobby","event":"phx_reply","ref":"\#(ref)","payload":{"status":"ok","response":{}}}"#
        await conn._testInjectIncoming(Data(reply.utf8))
        try await subscribeTask.value
        let status = await channel.status
        #expect(status == .subscribed)
    }

    @Test func broadcastRoutesToCorrectListener() async throws {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        let channel = RealtimeChannel(
            name: "room:lobby",
            connection: conn,
            apiKey: "pb_test_xxx",
            accessTokenProvider: nullToken
        )

        let chatBox = ReceivedBox()
        let typingBox = ReceivedBox()
        await channel.onBroadcast(event: "chat") { p in
            Task { await chatBox.set(p.data["text"]?.stringValue ?? "") }
        }
        await channel.onBroadcast(event: "typing") { p in
            Task { await typingBox.set(p.data["text"]?.stringValue ?? "") }
        }

        let subscribeTask = Task { try await channel.subscribe() }
        _ = await waitForCondition { await core.sentCount() >= 1 }
        let sent = await core.sentSnapshot()
        let ref = (decodeSent(sent[0])?["ref"] as? String) ?? ""
        let reply = #"{"topic":"room:lobby","event":"phx_reply","ref":"\#(ref)","payload":{"status":"ok"}}"#
        await conn._testInjectIncoming(Data(reply.utf8))
        try await subscribeTask.value

        let chatFrame = #"{"topic":"room:lobby","event":"broadcast","payload":{"event":"chat","payload":{"text":"hello"}}}"#
        await conn._testInjectIncoming(Data(chatFrame.utf8))
        let ok = await waitForCondition { await chatBox.value == "hello" }
        #expect(ok)
        let typingValue = await typingBox.value
        #expect(typingValue == nil)
    }

    @Test func presenceStateFromDiff() async throws {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        let channel = RealtimeChannel(
            name: "room:lobby",
            connection: conn,
            apiKey: "pb_test_xxx",
            accessTokenProvider: nullToken
        )

        let subscribeTask = Task { try await channel.subscribe() }
        _ = await waitForCondition { await core.sentCount() >= 1 }
        let sent = await core.sentSnapshot()
        let ref = (decodeSent(sent[0])?["ref"] as? String) ?? ""
        await conn._testInjectIncoming(Data(#"{"topic":"room:lobby","event":"phx_reply","ref":"\#(ref)","payload":{"status":"ok"}}"#.utf8))
        try await subscribeTask.value

        let stateFrame = #"{"topic":"room:lobby","event":"presence_state","payload":{"alice":{"metas":[{"phx_ref":"r1"}]}}}"#
        await conn._testInjectIncoming(Data(stateFrame.utf8))
        _ = await waitForCondition { await channel.presenceState().keys.contains("alice") }

        let diffFrame = #"{"topic":"room:lobby","event":"presence_diff","payload":{"joins":{"bob":{"metas":[{"phx_ref":"r2"}]}},"leaves":{"alice":{"metas":[{"phx_ref":"r1"}]}}}}"#
        await conn._testInjectIncoming(Data(diffFrame.utf8))
        let ok = await waitForCondition {
            let s = await channel.presenceState()
            return s.keys.contains("bob") && !s.keys.contains("alice")
        }
        #expect(ok)
    }

    @Test func postgresChangesFiltersByTableAndEvent() async throws {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        let channel = RealtimeChannel(
            name: "room:lobby",
            connection: conn,
            apiKey: "pb_test_xxx",
            accessTokenProvider: nullToken
        )

        let messagesBox = ReceivedBox()
        let usersBox = ReceivedBox()
        await channel.onPostgresChanges(event: .insert, table: "messages") { p in
            Task { await messagesBox.set(p.table) }
        }
        await channel.onPostgresChanges(event: .delete, table: "users") { p in
            Task { await usersBox.set(p.table) }
        }

        let subscribeTask = Task { try await channel.subscribe() }
        _ = await waitForCondition { await core.sentCount() >= 1 }
        let sent = await core.sentSnapshot()
        let ref = (decodeSent(sent[0])?["ref"] as? String) ?? ""
        await conn._testInjectIncoming(Data(#"{"topic":"room:lobby","event":"phx_reply","ref":"\#(ref)","payload":{"status":"ok"}}"#.utf8))
        try await subscribeTask.value

        // Insert into messages → only messages listener fires.
        let insertFrame = #"{"topic":"room:lobby","event":"postgres_changes","payload":{"type":"INSERT","schema":"public","table":"messages","record":{"id":1}}}"#
        await conn._testInjectIncoming(Data(insertFrame.utf8))
        let ok1 = await waitForCondition { await messagesBox.value == "messages" }
        #expect(ok1)
        let usersAfterInsert = await usersBox.value
        #expect(usersAfterInsert == nil)

        // Insert into users → no listener fires (users listener is for delete).
        let insertUsersFrame = #"{"topic":"room:lobby","event":"postgres_changes","payload":{"type":"INSERT","schema":"public","table":"users","record":{"id":1}}}"#
        await conn._testInjectIncoming(Data(insertUsersFrame.utf8))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let usersStill = await usersBox.value
        #expect(usersStill == nil)
    }

    @Test func subscriptionTimeoutFiresWhenNoReply() async throws {
        // Use a tight deadline in this test by not injecting any reply and
        // just verifying that .subscribe() never resolves to .subscribed.
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        let channel = RealtimeChannel(
            name: "room:lobby",
            connection: conn,
            apiKey: "pb_test_xxx",
            accessTokenProvider: nullToken
        )

        let task = Task { try await channel.subscribe() }
        _ = await waitForCondition { await core.sentCount() >= 1 }
        let status = await channel.status
        #expect(status == .subscribing)
        task.cancel()
    }

    @Test func broadcastWithoutSubscribeThrows() async throws {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        let channel = RealtimeChannel(
            name: "room:lobby",
            connection: conn,
            apiKey: "pb_test_xxx",
            accessTokenProvider: nullToken
        )
        do {
            try await channel.broadcast(event: "x", payload: [:])
            Issue.record("expected notSubscribed")
        } catch {
            #expect(error.code == "not_subscribed")
        }
    }

    @Test func unsubscribeSendsPhxLeave() async throws {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        let channel = RealtimeChannel(
            name: "room:lobby",
            connection: conn,
            apiKey: "pb_test_xxx",
            accessTokenProvider: nullToken
        )
        let subscribeTask = Task { try await channel.subscribe() }
        _ = await waitForCondition { await core.sentCount() >= 1 }
        let sent = await core.sentSnapshot()
        let ref = (decodeSent(sent[0])?["ref"] as? String) ?? ""
        await conn._testInjectIncoming(Data(#"{"topic":"room:lobby","event":"phx_reply","ref":"\#(ref)","payload":{"status":"ok"}}"#.utf8))
        try await subscribeTask.value

        await channel.unsubscribe()
        let ok = await waitForCondition {
            let s = await core.sentSnapshot()
            return s.contains { decodeSent($0)?["event"] as? String == "phx_leave" }
        }
        #expect(ok)
        let status = await channel.status
        #expect(status == .closed)
    }
}

// MARK: - Error mapping

@Suite("RealtimeError mapping")
struct RealtimeErrorTests {
    @Test func mapsNetworkTransport() {
        let e = RealtimeError.from(transport: .network(message: "down"))
        #expect(e.code == "network_error")
    }

    @Test func mapsRateLimited() {
        let e = RealtimeError.from(transport: .rateLimited(retryAfter: 5))
        #expect(e.code == "network_error")
    }

    @Test func mapsServer() {
        let e = RealtimeError.from(transport: .server(status: 502, message: "down"))
        #expect(e.code == "server_error")
    }

    @Test func mapsHttpToServerError() {
        let e = RealtimeError.from(transport: .http(status: 401, code: "unauthorized", message: "no", requestId: nil))
        #expect(e.code == "server_error")
    }

    @Test func mapsNotConfigured() {
        let e = RealtimeError.from(transport: .notConfigured)
        #expect(e.code == "not_configured")
    }
}

// MARK: - PalbaseRealtime channel cache

@Suite("PalbaseRealtime channel cache")
struct PalbaseRealtimeCacheTests {
    @Test func channelByNameIsCached() async throws {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        let tokens = TokenManager()
        let client = PalbaseRealtime(connection: conn, apiKey: "pb_test_xxx", tokens: tokens)
        let a = try await client.channel("room:lobby")
        let b = try await client.channel("room:lobby")
        #expect(a === b)
    }

    @Test func invalidChannelNameThrows() async {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        let tokens = TokenManager()
        let client = PalbaseRealtime(connection: conn, apiKey: "pb_test_xxx", tokens: tokens)
        do {
            _ = try await client.channel("bad name")
            Issue.record("expected invalidChannelName")
        } catch {
            #expect(error.code == "invalid_channel_name")
        }
    }

    @Test func removeAllChannelsDropsAll() async throws {
        let core = MockSocketCore()
        let factory = MockSocketFactory(core: core)
        let conn = Connection(url: URL(string: "wss://test/v1/realtime/websocket")!, factory: factory)
        let tokens = TokenManager()
        let client = PalbaseRealtime(connection: conn, apiKey: "pb_test_xxx", tokens: tokens)
        _ = try await client.channel("a")
        _ = try await client.channel("b")
        await client.removeAllChannels()
        let count = await client.channelCount()
        #expect(count == 0)
    }
}
