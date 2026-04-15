import Foundation

// MARK: - Listener storage

private struct BroadcastListener: Sendable {
    let id: UUID
    let event: String
    let callback: @Sendable (BroadcastPayload) -> Void
}

private struct PresenceListener: Sendable {
    let id: UUID
    let event: PresenceEvent
    let callback: @Sendable (PresencePayload) -> Void
}

private struct PostgresListener: Sendable {
    let id: UUID
    let event: PostgresEvent
    let schema: String
    let table: String
    let filter: String?
    let callback: @Sendable (PostgresChangePayload) -> Void
}

/// A single subscription on the realtime connection.
public actor RealtimeChannel {
    public let name: String

    private let connection: Connection
    private let apiKey: String
    private let accessTokenProvider: @Sendable () async -> String?

    private var _status: ChannelStatus = .idle
    public var status: ChannelStatus { _status }

    private var broadcastListeners: [BroadcastListener] = []
    private var presenceListeners: [PresenceListener] = []
    private var postgresListeners: [PostgresListener] = []

    private var presence: [String: [PresenceMember]] = [:]
    private var pendingJoinRef: String?
    private var joinContinuations: [CheckedContinuation<Void, Error>] = []
    private let joinTimeoutNs: UInt64 = 10 * 1_000_000_000

    package init(
        name: String,
        connection: Connection,
        apiKey: String,
        accessTokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.name = name
        self.connection = connection
        self.apiKey = apiKey
        self.accessTokenProvider = accessTokenProvider
    }

    // MARK: - Listener registration

    @discardableResult
    public func onBroadcast(
        event: String,
        _ callback: @escaping @Sendable (BroadcastPayload) -> Void
    ) -> Unsubscribe {
        let id = UUID()
        broadcastListeners.append(BroadcastListener(id: id, event: event, callback: callback))
        return { [weak self] in
            guard let self else { return }
            Task { await self.removeBroadcast(id) }
        }
    }

    @discardableResult
    public func onPresence(
        event: PresenceEvent,
        _ callback: @escaping @Sendable (PresencePayload) -> Void
    ) -> Unsubscribe {
        let id = UUID()
        presenceListeners.append(PresenceListener(id: id, event: event, callback: callback))
        return { [weak self] in
            guard let self else { return }
            Task { await self.removePresence(id) }
        }
    }

    @discardableResult
    public func onPostgresChanges(
        event: PostgresEvent,
        table: String,
        schema: String = "public",
        filter: String? = nil,
        _ callback: @escaping @Sendable (PostgresChangePayload) -> Void
    ) -> Unsubscribe {
        let id = UUID()
        postgresListeners.append(
            PostgresListener(id: id, event: event, schema: schema, table: table, filter: filter, callback: callback)
        )
        return { [weak self] in
            guard let self else { return }
            Task { await self.removePostgres(id) }
        }
    }

    private func removeBroadcast(_ id: UUID) {
        broadcastListeners.removeAll { $0.id == id }
    }
    private func removePresence(_ id: UUID) {
        presenceListeners.removeAll { $0.id == id }
    }
    private func removePostgres(_ id: UUID) {
        postgresListeners.removeAll { $0.id == id }
    }

    package func listenerCounts() -> (broadcast: Int, presence: Int, postgres: Int) {
        (broadcastListeners.count, presenceListeners.count, postgresListeners.count)
    }

    // MARK: - Lifecycle

    /// Open the connection (if needed) and send `phx_join`. Suspends until the
    /// server replies `ok` or the join times out.
    public func subscribe() async throws(RealtimeError) {
        if _status == .subscribed || _status == .subscribing {
            return
        }
        _status = .subscribing

        // Make sure the connection knows about us BEFORE we open the socket —
        // otherwise the dispatch table may miss our incoming `phx_reply`.
        let bridge = makeBridge()
        await connection.registerChannel(topic: name, bridge: bridge)

        do {
            try await connection.open()
        } catch {
            _status = .idle
            await connection.unregisterChannel(topic: name)
            throw error
        }

        try await sendJoin()
    }

    /// Send `phx_leave` and remove all listeners on this channel. Always
    /// transitions to `.closed`.
    public func unsubscribe() async {
        guard _status != .closed else { return }
        _status = .unsubscribing
        let leave = PhoenixEnvelope(
            topic: name,
            event: "phx_leave",
            payload: [:],
            ref: await connection.nextRef()
        )
        try? await connection.send(leave)
        await connection.unregisterChannel(topic: name)
        broadcastListeners.removeAll()
        presenceListeners.removeAll()
        postgresListeners.removeAll()
        presence.removeAll()
        _status = .closed
    }

    // MARK: - Send broadcast

    public func broadcast(event: String, payload: [String: any Sendable]) async throws(RealtimeError) {
        guard _status == .subscribed else {
            throw RealtimeError.notSubscribed(channel: name)
        }
        let env = PhoenixEnvelope(
            topic: name,
            event: "broadcast",
            payload: PhoenixMessageBuilder.broadcastPayload(
                event: event,
                data: JSONValue.dict(from: payload)
            ),
            ref: await connection.nextRef()
        )
        try await connection.send(env)
    }

    // MARK: - Presence

    public func track(state: [String: any Sendable]) async throws(RealtimeError) {
        guard _status == .subscribed else {
            throw RealtimeError.notSubscribed(channel: name)
        }
        let env = PhoenixEnvelope(
            topic: name,
            event: "presence",
            payload: PhoenixMessageBuilder.presenceTrackPayload(state: JSONValue.dict(from: state)),
            ref: await connection.nextRef()
        )
        try await connection.send(env)
    }

    public func untrack() async throws(RealtimeError) {
        guard _status == .subscribed else {
            throw RealtimeError.notSubscribed(channel: name)
        }
        let env = PhoenixEnvelope(
            topic: name,
            event: "presence",
            payload: PhoenixMessageBuilder.presenceUntrackPayload(),
            ref: await connection.nextRef()
        )
        try await connection.send(env)
    }

    public func presenceState() async -> [String: [PresenceMember]] {
        return presence
    }

    // MARK: - Connection bridge

    private func makeBridge() -> ChannelBridge {
        ChannelBridge(
            onMessage: { [weak self] env in
                await self?.handleIncoming(env)
            },
            onReconnect: { [weak self] in
                await self?.handleReconnect()
            },
            onDisconnect: { [weak self] in
                await self?.handleDisconnect()
            }
        )
    }

    private func sendJoin() async throws(RealtimeError) {
        let ref = await connection.nextRef()
        pendingJoinRef = ref
        let token = await accessTokenProvider()
        let joinPayload = PhoenixMessageBuilder.joinPayload(
            apiKey: apiKey,
            accessToken: token,
            broadcastEvents: broadcastListeners.map { $0.event },
            presenceEnabled: !presenceListeners.isEmpty,
            postgresChanges: postgresListeners.map {
                PostgresChangeBinding(event: $0.event, schema: $0.schema, table: $0.table, filter: $0.filter)
            }
        )
        let env = PhoenixEnvelope(topic: name, event: "phx_join", payload: joinPayload, ref: ref)
        try await connection.send(env)
        try await waitForJoin()
    }

    private func waitForJoin() async throws(RealtimeError) {
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                joinContinuations.append(cont)
                let timeout = joinTimeoutNs
                let channelName = self.name
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeout)
                    await self?.timeoutPendingJoin(channelName: channelName)
                }
            }
        } catch let err as RealtimeError {
            throw err
        } catch {
            throw RealtimeError.connectionFailed(message: error.localizedDescription)
        }
    }

    private func timeoutPendingJoin(channelName: String) {
        guard !joinContinuations.isEmpty, _status != .subscribed else { return }
        let conts = joinContinuations
        joinContinuations.removeAll()
        pendingJoinRef = nil
        if _status != .subscribed {
            _status = .idle
        }
        let err = RealtimeError.subscriptionTimeout(channel: channelName)
        for c in conts { c.resume(throwing: err) }
    }

    // MARK: - Incoming dispatch

    private func handleIncoming(_ env: PhoenixEnvelope) async {
        switch env.event {
        case "phx_reply":
            handlePhxReply(env)
        case "phx_close":
            _status = .closed
        case "phx_error":
            failPendingJoin(message: env.payload["reason"]?.stringValue ?? "phx_error")
        case "presence_state":
            handlePresenceState(env.payload)
        case "presence_diff":
            handlePresenceDiff(env.payload)
        case "broadcast":
            handleBroadcast(env.payload)
        case "postgres_changes":
            handlePostgresChanges(env.payload)
        default:
            // Some servers route broadcasts through a custom event name —
            // try matching against broadcast listeners as a fallback.
            handleBroadcast(env.payload)
        }
    }

    private func handlePhxReply(_ env: PhoenixEnvelope) {
        // Only treat replies that match our pending join ref as join confirmations.
        guard let ref = env.ref, ref == pendingJoinRef else { return }
        pendingJoinRef = nil
        let status = env.payload["status"]?.stringValue
        if status == "ok" {
            _status = .subscribed
            let conts = joinContinuations
            joinContinuations.removeAll()
            for c in conts { c.resume() }
        } else {
            let response = env.payload["response"]?.objectValue
            let reason = response?["reason"]?.stringValue ?? "join failed"
            failPendingJoin(message: reason)
        }
    }

    private func failPendingJoin(message: String) {
        let conts = joinContinuations
        joinContinuations.removeAll()
        pendingJoinRef = nil
        _status = .idle
        let err = RealtimeError.serverError(message: message)
        for c in conts { c.resume(throwing: err) }
    }

    private func handlePresenceState(_ payload: [String: JSONValue]) {
        // Backend may wrap the state under a "state" key or send it at the root.
        let stateMap: [String: JSONValue]
        if let inner = payload["state"]?.objectValue {
            stateMap = inner
        } else {
            stateMap = payload
        }
        presence = PresenceDecoder.decodeState(stateMap)
        let event = PresencePayload(event: .sync, state: presence)
        for l in presenceListeners where l.event == .sync {
            l.callback(event)
        }
    }

    private func handlePresenceDiff(_ payload: [String: JSONValue]) {
        let joinsMap = payload["joins"]?.objectValue ?? [:]
        let leavesMap = payload["leaves"]?.objectValue ?? [:]
        let joins = PresenceDecoder.decodeState(joinsMap)
        let leaves = PresenceDecoder.decodeState(leavesMap)

        // Apply diff to local state.
        for (k, v) in joins { presence[k] = v }
        for k in leaves.keys { presence.removeValue(forKey: k) }

        let payloadJoin = PresencePayload(event: .join, state: presence, joins: joins, leaves: leaves)
        let payloadLeave = PresencePayload(event: .leave, state: presence, joins: joins, leaves: leaves)
        let payloadSync = PresencePayload(event: .sync, state: presence, joins: joins, leaves: leaves)

        for l in presenceListeners {
            switch l.event {
            case .sync: l.callback(payloadSync)
            case .join: if !joins.isEmpty { l.callback(payloadJoin) }
            case .leave: if !leaves.isEmpty { l.callback(payloadLeave) }
            }
        }
    }

    private func handleBroadcast(_ payload: [String: JSONValue]) {
        let event = payload["event"]?.stringValue ?? ""
        let data: [String: JSONValue]
        if let p = payload["payload"]?.objectValue {
            data = p
        } else {
            data = [:]
        }
        let bp = BroadcastPayload(event: event, data: data)
        for l in broadcastListeners where l.event == event {
            l.callback(bp)
        }
    }

    private func handlePostgresChanges(_ payload: [String: JSONValue]) {
        // Support both a flat `payload` and a nested `data` envelope.
        let body = payload["data"]?.objectValue ?? payload
        let eventStr = (body["type"]?.stringValue ?? body["eventType"]?.stringValue ?? "").uppercased()
        guard let event = PostgresEvent(rawValue: eventStr) else { return }
        let schema = body["schema"]?.stringValue ?? "public"
        let table = body["table"]?.stringValue ?? ""
        let new = body["record"]?.objectValue ?? body["new"]?.objectValue
        let old = body["old_record"]?.objectValue ?? body["old"]?.objectValue
        let timestamp = body["commit_timestamp"]?.stringValue ?? body["timestamp"]?.stringValue ?? ""

        let pp = PostgresChangePayload(
            event: event, schema: schema, table: table,
            new: new, old: old, timestamp: timestamp
        )

        for l in postgresListeners {
            if l.event != .all && l.event != event { continue }
            if l.table != table { continue }
            l.callback(pp)
        }
    }

    // MARK: - Connection lifecycle

    private func handleReconnect() async {
        // Connection re-opened after a drop. Re-send phx_join so the server
        // restores our subscription with the same listener config.
        do {
            try await sendJoin()
        } catch {
            // Leave status as .idle; the connection will continue retrying.
        }
    }

    private func handleDisconnect() async {
        if _status == .closed { return }
        _status = .idle
    }
}
