# PalbaseRealtime

Realtime subscriptions over WebSocket for Palbase. Three capabilities, one channel:

- **broadcast** — send/receive app-level events between clients
- **presence** — track who's online in a channel
- **postgres_changes** — listen to INSERT/UPDATE/DELETE on a database table

Built on `URLSessionWebSocketTask` (Foundation only, no third-party).

## Setup

```swift
import PalbaseRealtime

@main
struct MyApp: App {
    init() { Palbase.configure(apiKey: "pb_abc123_xxx") }
    var body: some Scene { ... }
}
```

`PalbaseRealtime` re-exports `PalbaseCore`, so `import PalbaseRealtime` is enough.

## Getting a channel

```swift
let realtime = try PalbaseRealtime.shared
let channel = try await realtime.channel("room:lobby")
```

Channel names must match `^[a-zA-Z0-9_\-:]+$` and be at most 255 characters.
The same name always returns the same `RealtimeChannel` actor (repeated calls
are cached — you register listeners once per channel).

## Broadcast (send + listen)

```swift
let channel = try await realtime.channel("room:lobby")

// Listen for chat messages from other clients.
await channel.onBroadcast(event: "chat") { [weak self] payload in
    let text = payload.data["text"]?.stringValue ?? ""
    self?.appendChat(text)
}

// Subscribe — opens the WebSocket if needed and sends phx_join.
try await channel.subscribe()

// Send a broadcast event to everyone subscribed to the channel.
try await channel.broadcast(event: "chat", payload: ["text": "hello"])
```

`payload` values can be any `Sendable` — strings, numbers, bools, nested
dicts/arrays. They are serialized to JSON on the way out and decoded into
`[String: JSONValue]` on the way in.

## Presence (track + state + join/leave)

```swift
await channel.onPresence(event: .sync) { [weak self] p in
    // Full current state — fired on initial join and after every diff.
    self?.updateOnlineList(p.state)
}

await channel.onPresence(event: .join) { p in
    if let joins = p.joins { print("joined:", joins.keys) }
}

await channel.onPresence(event: .leave) { p in
    if let leaves = p.leaves { print("left:", leaves.keys) }
}

try await channel.subscribe()

// Announce your state so other clients see you as "online".
try await channel.track(state: ["username": "alice", "status": "typing"])

// Fetch the current snapshot at any time.
let online = await channel.presenceState()
// online is [String: [PresenceMember]] — key is typically the user id.

// Stop being tracked.
try await channel.untrack()
```

## Postgres changes

Listen to database changes by schema/table/event. Filters use PostgREST syntax
(e.g. `"id=eq.123"`).

```swift
// All inserts into the public.messages table.
await channel.onPostgresChanges(event: .insert, table: "messages") { change in
    print("new row:", change.new ?? [:])
}

// Only updates matching a filter.
await channel.onPostgresChanges(
    event: .update,
    table: "orders",
    schema: "public",
    filter: "status=eq.pending"
) { change in
    print("updated:", change.new ?? [:])
}

// All events on a table.
await channel.onPostgresChanges(event: .all, table: "comments") { change in
    print(change.event, change.new ?? change.old ?? [:])
}

try await channel.subscribe()
```

## Lifecycle

- `subscribe()` opens the shared WebSocket (if needed), sends `phx_join`, then
  suspends until the server replies `ok`. Raises
  `RealtimeError.subscriptionTimeout` if no reply arrives within ~10 seconds.
- `unsubscribe()` sends `phx_leave`, drops every listener on the channel, and
  marks the channel `.closed`. It never throws; failures on the wire are best-
  effort.
- `removeChannel("name")` — unsubscribe and forget the channel. When the last
  channel goes away the WebSocket is closed.
- `removeAllChannels()` — unsubscribe every channel and close the WebSocket.

Auto-reconnect is built in: dropped connections are retried up to **10 times**
with exponential backoff (1s, 2s, 4s, 8s, 16s, then capped at 30s). On each
reconnect, every registered channel is re-joined with its current listener
config.

Heartbeats are sent on the connection every 30 seconds.

## Retain-cycle warning

All listener callbacks are `@Sendable` closures. **Capture `self` weakly**:

```swift
await channel.onBroadcast(event: "chat") { [weak self] payload in
    guard let self else { return }
    self.handle(payload)
}
```

The `Unsubscribe` returned from each `on*` method detaches that specific
listener. Call it when the listener outlives its target:

```swift
let unsub = await channel.onBroadcast(event: "chat") { ... }
// ... later
unsub()
```

## Status

```swift
let status = await channel.status  // ChannelStatus
// .idle, .subscribing, .subscribed, .unsubscribing, .closed
```

## Public types

| Type | Purpose |
|------|---------|
| `PalbaseRealtime` | Module entry point (actor). `PalbaseRealtime.shared` |
| `RealtimeChannel` | Per-topic actor managing listeners and lifecycle |
| `ChannelStatus` | `.idle / .subscribing / .subscribed / .unsubscribing / .closed` |
| `PresenceEvent` | `.sync / .join / .leave` |
| `PostgresEvent` | `.insert / .update / .delete / .all` |
| `BroadcastPayload` | `event: String`, `data: [String: JSONValue]` |
| `PresencePayload` | `event`, `state`, optional `joins`/`leaves` |
| `PresenceMember` | `presenceRef: String`, `payload: [String: JSONValue]` |
| `PostgresChangePayload` | `event`, `schema`, `table`, `new`, `old`, `timestamp` |
| `JSONValue` | Wire-format JSON value (string/int/double/bool/null/array/object) |
| `Unsubscribe` | `@Sendable () -> Void` — detach a listener |

## Errors — `RealtimeError`

| Case | `code` | When |
|------|--------|------|
| `.notConfigured` | `not_configured` | Accessed `.shared` without `Palbase.configure(_:)` |
| `.invalidChannelName(String)` | `invalid_channel_name` | Name fails regex or length check |
| `.notSubscribed(channel:)` | `not_subscribed` | `broadcast`/`track`/`untrack` called before `subscribe()` |
| `.subscriptionTimeout(channel:)` | `subscription_timeout` | No `phx_reply` within timeout |
| `.connectionClosed(reason:)` | `connection_closed` | WebSocket closed underneath a send |
| `.connectionFailed(message:)` | `connection_failed` | WebSocket refused to open |
| `.messageEncodingFailed(message:)` | `message_encoding_failed` | Outgoing message failed to encode |
| `.messageDecodingFailed(message:)` | `message_decoding_failed` | Incoming frame was not valid Phoenix JSON |
| `.network(String)` | `network_error` | Underlying transport error |
| `.serverError(message:)` | `server_error` | Server replied `{"status":"error"}` to a join |

Every case conforms to `PalbaseError` (`code`, `statusCode?`, `requestId?`).
