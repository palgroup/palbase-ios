import Foundation
@_exported import PalbaseCore

/// Palbase Realtime module entry point. Use `PalbaseRealtime.shared` after
/// `Palbase.configure(_:)`.
///
/// ```swift
/// let realtime = try PalbaseRealtime.shared
/// let channel = await realtime.channel("room:lobby")
/// await channel.onBroadcast(event: "chat") { msg in
///     print("got chat: \(msg.data)")
/// }
/// try await channel.subscribe()
/// ```
public actor PalbaseRealtime {
    private let connection: Connection
    private let apiKey: String
    private let tokens: TokenManager
    private var channels: [String: RealtimeChannel] = [:]

    package init(connection: Connection, apiKey: String, tokens: TokenManager) {
        self.connection = connection
        self.apiKey = apiKey
        self.tokens = tokens
    }

    /// Shared client backed by the global SDK configuration.
    /// Throws `RealtimeError.notConfigured` if `Palbase.configure(_:)` was not called.
    public static var shared: PalbaseRealtime {
        get throws(RealtimeError) {
            guard let cfg = Palbase.config, let tokens = Palbase.tokens else {
                throw RealtimeError.notConfigured
            }
            return RealtimeClientCache.getOrCreate(config: cfg, tokens: tokens)
        }
    }

    /// Get (or create) a channel by name. Channels are cached — repeated calls
    /// for the same name return the same `RealtimeChannel`.
    ///
    /// Throws `RealtimeError.invalidChannelName` if `name` does not match
    /// `^[a-zA-Z0-9_\-:]+$`.
    public func channel(_ name: String) throws(RealtimeError) -> RealtimeChannel {
        try ChannelNameValidator.validate(name)
        if let existing = channels[name] { return existing }
        let tokensRef = tokens
        let ch = RealtimeChannel(
            name: name,
            connection: connection,
            apiKey: apiKey,
            accessTokenProvider: { await tokensRef.accessToken }
        )
        channels[name] = ch
        return ch
    }

    /// Unsubscribe and forget a channel by name.
    public func removeChannel(_ name: String) async {
        guard let ch = channels.removeValue(forKey: name) else { return }
        await ch.unsubscribe()
        if channels.isEmpty {
            await connection.close()
        }
    }

    /// Unsubscribe and forget every channel; closes the underlying connection.
    public func removeAllChannels() async {
        let all = Array(channels.values)
        channels.removeAll()
        for ch in all { await ch.unsubscribe() }
        await connection.close()
    }

    package func channelCount() -> Int { channels.count }
}

// MARK: - Singleton cache

/// Caches a single `PalbaseRealtime` per (apiKey, baseURL) pair so that
/// `.shared` returns the same actor across calls — required so multiple
/// channels share one WebSocket.
final class RealtimeClientCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (key: String, value: PalbaseRealtime)?

    private static let instance = RealtimeClientCache()

    static func getOrCreate(config: PalbaseConfig, tokens: TokenManager) -> PalbaseRealtime {
        instance.getOrCreate(config: config, tokens: tokens)
    }

    /// Test-only: drop the cached client.
    package static func _resetForTesting() {
        instance.lock.lock(); defer { instance.lock.unlock() }
        instance.cached = nil
    }

    private func getOrCreate(config: PalbaseConfig, tokens: TokenManager) -> PalbaseRealtime {
        let baseURL = Self.realtimeURL(for: config)
        let cacheKey = "\(config.apiKey)|\(baseURL.absoluteString)"
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.key == cacheKey { return cached.value }
        let factory = DefaultWebSocketFactory(session: config.urlSession)
        let conn = Connection(url: baseURL, factory: factory)
        let client = PalbaseRealtime(connection: conn, apiKey: config.apiKey, tokens: tokens)
        cached = (cacheKey, client)
        return client
    }

    static func realtimeURL(for config: PalbaseConfig) -> URL {
        let baseString: String
        if let url = config.url {
            baseString = url
        } else if let ref = parseProjectRef(from: config.apiKey) {
            baseString = "https://\(ref).palbase.studio"
        } else {
            baseString = "https://palbase.studio"
        }

        // Convert https:// → wss:// and http:// → ws://.
        var wsString = baseString
        if wsString.hasPrefix("https://") {
            wsString = "wss://" + wsString.dropFirst("https://".count)
        } else if wsString.hasPrefix("http://") {
            wsString = "ws://" + wsString.dropFirst("http://".count)
        }
        if wsString.hasSuffix("/") { wsString = String(wsString.dropLast()) }

        let urlString = "\(wsString)/v1/realtime/websocket"
        return URL(string: urlString) ?? URL(string: "wss://palbase.studio/v1/realtime/websocket")!
    }

    private static func parseProjectRef(from apiKey: String) -> String? {
        let parts = apiKey.split(separator: "_")
        guard parts.count >= 3, parts[0] == "pb" else { return nil }
        return String(parts[1])
    }
}
