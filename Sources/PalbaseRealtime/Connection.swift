import Foundation

// MARK: - WebSocket task abstraction

/// Abstraction over `URLSessionWebSocketTask` to enable testing without a real
/// network. Production: `URLSessionWebSocketShim`. Tests provide their own
/// in-memory implementation.
package protocol WebSocketTaskProtocol: Sendable, AnyObject {
    func resume()
    func cancel(closeCode: Int, reason: Data?)
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage
}

/// Mirrors `URLSessionWebSocketTask.Message` — kept module-local so the
/// protocol stays Sendable and free of `URLSessionWebSocketTask` dependencies.
package enum WebSocketMessage: Sendable {
    case data(Data)
    case string(String)
}

/// Factory used by the connection to open a new WebSocket task.
package protocol WebSocketFactory: Sendable {
    func makeTask(url: URL) -> any WebSocketTaskProtocol
}

/// Default factory: wraps `URLSession.webSocketTask(with:)`.
package struct DefaultWebSocketFactory: WebSocketFactory {
    let session: URLSession
    package init(session: URLSession = .shared) { self.session = session }
    package func makeTask(url: URL) -> any WebSocketTaskProtocol {
        URLSessionWebSocketShim(task: session.webSocketTask(with: url))
    }
}

/// Wraps `URLSessionWebSocketTask` to conform to `WebSocketTaskProtocol`.
final class URLSessionWebSocketShim: WebSocketTaskProtocol, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }

    func resume() { task.resume() }

    func cancel(closeCode: Int, reason: Data?) {
        let code = URLSessionWebSocketTask.CloseCode(rawValue: closeCode) ?? .normalClosure
        task.cancel(with: code, reason: reason)
    }

    func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .data(let d):
            try await task.send(.data(d))
        case .string(let s):
            try await task.send(.string(s))
        }
    }

    func receive() async throws -> WebSocketMessage {
        let m = try await task.receive()
        switch m {
        case .data(let d): return .data(d)
        case .string(let s): return .string(s)
        @unknown default:
            throw RealtimeError.messageDecodingFailed(message: "unknown WebSocket message kind")
        }
    }
}

// MARK: - Connection state

/// Per-channel hooks the connection invokes when traffic for that topic arrives
/// or when the connection lifecycle changes.
package struct ChannelBridge: Sendable {
    /// Called when a Phoenix message lands on this channel's topic.
    let onMessage: @Sendable (PhoenixEnvelope) async -> Void

    /// Called when the connection re-opens — the channel should re-send `phx_join`.
    let onReconnect: @Sendable () async -> Void

    /// Called when the connection drops — the channel should reset its status to idle.
    let onDisconnect: @Sendable () async -> Void
}

/// Owns a single WebSocket to the Realtime server, multiplexed across channels.
package actor Connection {
    private let url: URL
    private let factory: any WebSocketFactory

    private var task: (any WebSocketTaskProtocol)?
    private var receiveLoop: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var channels: [String: ChannelBridge] = [:]
    private var refCounter: UInt64 = 0
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 10
    private let heartbeatIntervalNs: UInt64 = 30 * 1_000_000_000

    /// State.
    private(set) var isOpen: Bool = false

    package init(url: URL, factory: any WebSocketFactory) {
        self.url = url
        self.factory = factory
    }

    // MARK: - Channel registry

    package func registerChannel(topic: String, bridge: ChannelBridge) {
        channels[topic] = bridge
    }

    package func unregisterChannel(topic: String) {
        channels.removeValue(forKey: topic)
    }

    package func channelCount() -> Int { channels.count }

    // MARK: - Lifecycle

    /// Open the WebSocket if it isn't already open. Returns when the underlying
    /// task has been resumed and the receive loop is running.
    package func open() async throws(RealtimeError) {
        if isOpen { return }
        let newTask = factory.makeTask(url: url)
        task = newTask
        newTask.resume()
        isOpen = true
        startReceiveLoop()
        startHeartbeat()
    }

    /// Send a Phoenix envelope. Throws if the WebSocket is not open or the
    /// underlying send fails.
    package func send(_ env: PhoenixEnvelope) async throws(RealtimeError) {
        guard let task else {
            throw RealtimeError.connectionClosed(reason: "no active socket")
        }
        let data = try PhoenixCodec.encode(env)
        guard let str = String(data: data, encoding: .utf8) else {
            throw RealtimeError.messageEncodingFailed(message: "non-utf8")
        }
        do {
            try await task.send(.string(str))
        } catch {
            throw RealtimeError.connectionFailed(message: error.localizedDescription)
        }
    }

    /// Generate a fresh outgoing message ref.
    package func nextRef() -> String {
        refCounter &+= 1
        return String(refCounter)
    }

    /// Close the connection and cancel pending tasks.
    package func close() {
        receiveLoop?.cancel(); receiveLoop = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        task?.cancel(closeCode: 1000, reason: nil)
        task = nil
        isOpen = false
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    private func runReceiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                let data: Data
                switch msg {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                }
                await dispatch(data: data)
            } catch {
                await handleDisconnect(reason: error.localizedDescription)
                return
            }
        }
    }

    private func dispatch(data: Data) async {
        let env: PhoenixEnvelope
        do {
            env = try PhoenixCodec.decode(data)
        } catch {
            return  // ignore malformed frames
        }
        if env.topic == "phoenix" { return }  // heartbeat acks
        if let bridge = channels[env.topic] {
            await bridge.onMessage(env)
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let intervalNs = heartbeatIntervalNs
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { return }
                await self?.sendHeartbeat()
            }
        }
    }

    /// Send heartbeat. Internal helper so tests can fast-forward by calling this directly.
    package func sendHeartbeat() async {
        let ref = nextRef()
        let env = PhoenixEnvelope(topic: "phoenix", event: "heartbeat", payload: [:], ref: ref)
        try? await send(env)
    }

    // MARK: - Reconnect

    private func handleDisconnect(reason: String) async {
        isOpen = false
        task = nil
        heartbeatTask?.cancel(); heartbeatTask = nil

        // Notify channels they should reset to idle.
        let bridges = Array(channels.values)
        for b in bridges { await b.onDisconnect() }

        // Don't reconnect if no channels remain.
        if channels.isEmpty { return }

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let attempt = reconnectAttempts
        reconnectAttempts += 1
        guard attempt < maxReconnectAttempts else { return }

        let backoffSec = min(30.0, pow(2.0, Double(attempt)))
        let nanos = UInt64(backoffSec * 1_000_000_000)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            await self?.attemptReconnect()
        }
    }

    private func attemptReconnect() async {
        do {
            try await open()
            reconnectAttempts = 0
            // Tell each channel to re-send its phx_join.
            let bridges = Array(channels.values)
            for b in bridges { await b.onReconnect() }
        } catch {
            scheduleReconnect()
        }
    }

    // MARK: - Testing helpers

    package func currentReconnectAttempts() -> Int { reconnectAttempts }

    /// Inject a synthetic disconnect — used by tests to exercise reconnect logic.
    package func _testForceDisconnect(reason: String) async {
        await handleDisconnect(reason: reason)
    }

    /// Inject a synthetic incoming frame — used by tests when the WebSocket
    /// implementation doesn't naturally surface server traffic.
    package func _testInjectIncoming(_ data: Data) async {
        await dispatch(data: data)
    }
}
