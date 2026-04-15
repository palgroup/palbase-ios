# PalbaseFlags

Client-side SDK for Palbase feature flags. Reads user-effective flag values
(system defaults + user overrides, merged server-side), caches them locally,
and keeps them in sync via realtime.

## Install

Add the product to your target in `Package.swift`:

```swift
.product(name: "PalbaseFlags", package: "palbase-ios")
```

`PalbaseFlags` depends on `PalbaseRealtime` — both libraries are added to your
app automatically when you add `PalbaseFlags`.

## Quick start

```swift
import PalbaseFlags

Palbase.configure(apiKey: "pb_abc123_xxxxxxxxxxxxxxxx")

// After sign-in:
try await PalbaseFlags.shared.start()

if await PalbaseFlags.shared.bool("ai_features", default: false) {
    // show AI features
}

let maxUpload = await PalbaseFlags.shared.int("max_upload_mb", default: 50)
```

## API surface

```swift
public actor PalbaseFlags {
    public static var shared: PalbaseFlags { get throws(FlagsError) }

    // Lifecycle
    public func start() async throws(FlagsError)     // fetch + subscribe to realtime
    public func stop() async                         // unsubscribe, keep cache
    public func clear() async                        // wipe cache + persistence

    // Fetch
    @discardableResult
    public func fetch() async throws(FlagsError) -> FlagsSnapshot

    // Read
    public func value(for key: String) async -> FlagValue?
    public func all() async -> [String: FlagValue]

    // Typed accessors (optional → nil on type mismatch)
    public func bool(_ key: String) async -> Bool?
    public func string(_ key: String) async -> String?
    public func int(_ key: String) async -> Int?
    public func double(_ key: String) async -> Double?
    public func object(_ key: String) async -> [String: FlagValue]?
    public func array(_ key: String) async -> [FlagValue]?

    // Typed accessors (with defaults — never fail)
    public func bool(_ key: String, default: Bool) async -> Bool
    public func string(_ key: String, default: String) async -> String
    public func int(_ key: String, default: Int) async -> Int
    public func double(_ key: String, default: Double) async -> Double

    // Listeners
    public func onChange(
        _ handler: @escaping @Sendable (String, FlagValue?) -> Void
    ) async -> Unsubscribe

    public func onChange(
        key: String,
        handler: @escaping @Sendable (FlagValue?) -> Void
    ) async -> Unsubscribe

    public var isStarted: Bool { get async }
    public var lastFetchedAt: Date? { get async }
}
```

## FlagValue

```swift
public enum FlagValue: Sendable, Codable, Hashable {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case object([String: FlagValue])
    case array([FlagValue])
    case null
}
```

`FlagValue` supports literal conformances — `true`, `42`, `3.14`, `"hi"`,
`nil`, arrays and dictionaries — and exposes typed accessors like
`boolValue`, `intValue`, `stringValue`, `objectValue`, `arrayValue`,
`isNull`.

## FlagsSnapshot

```swift
public struct FlagsSnapshot: Sendable, Codable {
    public let values: [String: FlagValue]
    public let fetchedAt: Date
}
```

Returned by `fetch()` and persisted under `palbase.flags.snapshot.{projectRef}.{userId}`
in `UserDefaults`. On `start()`, a previously persisted snapshot is loaded
synchronously before the network fetch — the first read after launch never
blocks on the network.

## FlagsError

| Case | `code` | When |
|---|---|---|
| `.notConfigured` | `not_configured` | `Palbase.configure(_:)` not called |
| `.notStarted` | `not_started` | Realtime subscription required before `start()` |
| `.noActiveSession` | `no_active_session` | User not signed in |
| `.network(_)` | `network_error` | Transport failure |
| `.decoding(_)` | `decoding_error` | Response couldn't be decoded |
| `.rateLimited(retryAfter:)` | `rate_limited` | HTTP 429 |
| `.serverError(status:message:)` | `server_error` | HTTP 5xx |
| `.http(status:code:message:requestId:)` | server code | Other 4xx |
| `.server(code:message:requestId:)` | server code | Unrecognized server envelope |

All cases conform to `PalbaseError`.

## Realtime

`start()` subscribes to two Phoenix channels:

- `user-flags:{projectRef}:user:{userId}` — user-scoped override events
- `user-flags:{projectRef}:project` — project-wide system flag events

Events handled:

| Event | Behavior |
|---|---|
| `user_flag_changed` | cache[key] = value |
| `user_flag_deleted` | cache[key] = system_value, or remove if absent |
| `system_flag_changed` | cache[key] = value |
| `system_flag_deleted` | remove cache[key] |

On reconnect, `start()` triggers a full `fetch()` resync so the client state
matches the server after any dropped events.

## Listeners

```swift
let unsub = await PalbaseFlags.shared.onChange { key, value in
    print("\(key) = \(String(describing: value))")
}

let keyUnsub = await PalbaseFlags.shared.onChange(key: "max_upload_mb") { v in
    print("max_upload_mb = \(v?.intValue ?? 0)")
}

// Call to stop receiving events:
unsub()
keyUnsub()
```

## Sign-out

```swift
await PalbaseFlags.shared.clear()
```

Wipes the in-memory cache, removes the persisted snapshot for the current
`(projectRef, userId)`, unsubscribes from realtime, and resets `isStarted`.

## Testing

Inject a `FlagsStorage` (use `InMemoryFlagsStorage`) and a mock
`FlagsRealtimeSubscribing` via the `package` initializer. See
`Tests/PalbaseFlagsTests/FlagsClientTests.swift` for patterns.
