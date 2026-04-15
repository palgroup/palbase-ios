import Foundation
import PalbaseRealtime

/// Abstraction over realtime subscriptions used by `PalbaseFlags`. Production
/// wires this to `PalbaseRealtime`; tests supply a mock to drive events
/// deterministically.
package protocol FlagsRealtimeSubscribing: Sendable {
    /// Subscribe to the pair of user + project channels for the given user.
    /// Delivers every relevant event to `onEvent` and every channel-level
    /// reconnect (joined → joined after a drop) to `onReconnect` so the caller
    /// can trigger a full resync.
    func subscribe(
        projectRef: String,
        userId: String,
        onEvent: @escaping @Sendable (FlagsRealtimeEvent) -> Void,
        onReconnect: @escaping @Sendable () -> Void
    ) async throws(FlagsError)

    /// Unsubscribe and drop references. Safe to call when not subscribed.
    func unsubscribe() async
}

/// Normalized event coming off the realtime pipe. We map Phoenix broadcast
/// payloads into this enum inside the bridge so the client only has to reason
/// about flag-level intents, not wire format.
package enum FlagsRealtimeEvent: Sendable {
    case userFlagChanged(key: String, value: FlagValue)
    case userFlagDeleted(key: String, systemValue: FlagValue?)
    case systemFlagChanged(key: String, value: FlagValue)
    case systemFlagDeleted(key: String)
}

// MARK: - Production adapter backed by PalbaseRealtime

/// Default `FlagsRealtimeSubscribing` implementation that drives two channels
/// (`user-flags:{ref}:user:{userId}` + `user-flags:{ref}:project`) through
/// `PalbaseRealtime`.
package actor DefaultFlagsRealtimeSubscriber: FlagsRealtimeSubscribing {
    private let realtime: PalbaseRealtime
    private var userChannel: RealtimeChannel?
    private var projectChannel: RealtimeChannel?
    private var unsubscribers: [Unsubscribe] = []

    package init(realtime: PalbaseRealtime) {
        self.realtime = realtime
    }

    package func subscribe(
        projectRef: String,
        userId: String,
        onEvent: @escaping @Sendable (FlagsRealtimeEvent) -> Void,
        onReconnect: @escaping @Sendable () -> Void
    ) async throws(FlagsError) {
        let userTopic = "user-flags:\(projectRef):user:\(userId)"
        let projectTopic = "user-flags:\(projectRef):project"

        let userCh: RealtimeChannel
        let projCh: RealtimeChannel
        do {
            userCh = try await realtime.channel(userTopic)
            projCh = try await realtime.channel(projectTopic)
        } catch {
            throw .network("Failed to create flags channels: \(error)")
        }

        let userUnsubChanged = await userCh.onBroadcast(event: "user_flag_changed") { payload in
            guard let key = readString(payload.data["key"]) else { return }
            let value = decodeFlagValue(payload.data["value"]) ?? .null
            onEvent(.userFlagChanged(key: key, value: value))
        }
        let userUnsubDeleted = await userCh.onBroadcast(event: "user_flag_deleted") { payload in
            guard let key = readString(payload.data["key"]) else { return }
            let systemValue = decodeFlagValue(payload.data["system_value"])
            onEvent(.userFlagDeleted(key: key, systemValue: systemValue))
        }
        let projUnsubChanged = await projCh.onBroadcast(event: "system_flag_changed") { payload in
            guard let key = readString(payload.data["key"]) else { return }
            let value = decodeFlagValue(payload.data["value"]) ?? .null
            onEvent(.systemFlagChanged(key: key, value: value))
        }
        let projUnsubDeleted = await projCh.onBroadcast(event: "system_flag_deleted") { payload in
            guard let key = readString(payload.data["key"]) else { return }
            onEvent(.systemFlagDeleted(key: key))
        }

        do {
            try await userCh.subscribe()
            try await projCh.subscribe()
        } catch {
            throw .network("Failed to subscribe to flags channels: \(error)")
        }

        self.userChannel = userCh
        self.projectChannel = projCh
        self.unsubscribers = [userUnsubChanged, userUnsubDeleted, projUnsubChanged, projUnsubDeleted]

        // Best-effort reconnect detection: the channel re-sends phx_join on
        // socket reconnect; we poll status transitions in a lightweight task.
        let userChRef = userCh
        let projChRef = projCh
        Task { [weak self] in
            await self?.watchReconnect(
                userChannel: userChRef,
                projectChannel: projChRef,
                onReconnect: onReconnect
            )
        }
    }

    package func unsubscribe() async {
        for unsub in unsubscribers { unsub() }
        unsubscribers.removeAll()
        if let ch = userChannel { await ch.unsubscribe() }
        if let ch = projectChannel { await ch.unsubscribe() }
        userChannel = nil
        projectChannel = nil
    }

    private func watchReconnect(
        userChannel: RealtimeChannel,
        projectChannel: RealtimeChannel,
        onReconnect: @Sendable @escaping () -> Void
    ) async {
        var previouslyDropped = false
        while true {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let userStatus = await userChannel.status
            let projStatus = await projectChannel.status
            if userStatus == .closed && projStatus == .closed { return }
            let dropped = userStatus == .idle || projStatus == .idle
            let joined = userStatus == .subscribed && projStatus == .subscribed
            if previouslyDropped, joined {
                previouslyDropped = false
                onReconnect()
            } else if dropped {
                previouslyDropped = true
            }
        }
    }
}

// MARK: - JSONValue → FlagValue helpers

private func readString(_ json: JSONValue?) -> String? {
    guard let json else { return nil }
    if case .string(let s) = json { return s }
    return nil
}

private func decodeFlagValue(_ json: JSONValue?) -> FlagValue? {
    guard let json else { return nil }
    switch json {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .array(let arr):
        return .array(arr.compactMap { decodeFlagValue($0) })
    case .object(let obj):
        var out: [String: FlagValue] = [:]
        for (k, v) in obj {
            if let mapped = decodeFlagValue(v) { out[k] = mapped }
        }
        return .object(out)
    }
}
