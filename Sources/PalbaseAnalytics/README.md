# PalbaseAnalytics

Event capture for Palbase. Batched, offline-queued, opt-out aware. Mixpanel / PostHog
style ergonomics.

## Setup

```swift
import PalbaseAnalytics

@main
struct MyApp: App {
    init() { Palbase.configure(apiKey: "pb_abc123_xxx") }
    var body: some Scene { ... }
}
```

`PalbaseAnalytics` re-exports `PalbaseCore`, so `import PalbaseAnalytics` is enough.

## Capturing events

```swift
await PalbaseAnalytics.shared.capture("purchase", properties: [
    "amount": 99.99,
    "currency": "USD",
    "items": ["item_1", "item_2"]
])
```

`capture` is **fire-and-forget** — it never throws and never blocks. Events are
queued locally (file-backed) and flushed in batches. Invalid events (name regex
failure, >32KB payload) are silently dropped and logged to stderr.

### Mobile screen views

```swift
await PalbaseAnalytics.shared.screen("Home", properties: ["source": "push"])
```

### Web page views

```swift
await PalbaseAnalytics.shared.page(
    url: "https://example.com/checkout",
    title: "Checkout"
)
```

## Identity

Associate events with a specific user:

```swift
// After sign-in
await PalbaseAnalytics.shared.identify(distinctId: "user_42", traits: [
    "plan": "pro",
    "email": "jane@example.com"
])

// Link two ids (e.g. anonymous session → signed-in user)
await PalbaseAnalytics.shared.alias(from: "anon_abc", to: "user_42")
```

## Sessions

A session id is generated automatically on first capture and attached to every
subsequent event. Rules:

- Resets after **30 minutes of inactivity**
- Resets after **24 hours** regardless of activity
- Inspect: `await PalbaseAnalytics.shared.sessionId`
- Force rotate: `await PalbaseAnalytics.shared.resetSession()`

```swift
let sid = await PalbaseAnalytics.shared.sessionId
```

On sign-out, clear identity + session:

```swift
await PalbaseAnalytics.shared.reset()
```

`reset()` picks a new anonymous distinct_id and session id. Events that were
already queued before `reset()` still deliver under the previous identity.

## Flushing

Auto-flush runs every **10 seconds** and immediately when the queue reaches **50
events**. For explicit control:

```swift
// Force immediate send — throws on network/rate-limit/server failure
try await PalbaseAnalytics.shared.flush()

// Stop the background timer (events still queue locally)
await PalbaseAnalytics.shared.stopAutoFlush()

// Restart it
PalbaseAnalytics.shared.startAutoFlush()
```

## Offline behavior

The queue persists to
`~/Library/Application Support/Palbase/analytics-queue/queue.ndjson`. Events
survive app termination and deliver when connectivity returns. Overflow
(default cap: 1000 events) drops the **oldest** first.

## GDPR opt-out

```swift
PalbaseAnalytics.shared.optOut()  // clears queue, stops auto-flush, persists flag
PalbaseAnalytics.shared.optIn()   // resumes capture
let out = await PalbaseAnalytics.shared.isOptedOut
```

Capture calls while opted-out are no-ops — they do not throw.

## AnalyticsValue

`AnalyticsValue` is the type-safe property value. Literals are supported:

```swift
let props: [String: AnalyticsValue] = [
    "amount": 99.99,
    "count": 3,
    "premium": true,
    "note": nil,
    "items": ["a", "b"],
    "meta": ["source": "email"]
]
```

## Error Handling

Only `flush()` throws. All capture / identify / alias / screen / page calls
swallow errors so analytics failures can't cascade into app bugs.

```swift
do {
    try await PalbaseAnalytics.shared.flush()
} catch AnalyticsError.rateLimited(let retryAfter) {
    print("retry in \(retryAfter ?? 0)s")
} catch AnalyticsError.network(let m) {
    print("network: \(m)")
} catch {
    print("error: \(error.localizedDescription)")
}
```

### `AnalyticsError` cases

| Case | When |
|------|------|
| `.notConfigured` | `Palbase.configure(_:)` not called |
| `.invalidEventName(String)` | Event name failed `^[a-zA-Z][a-zA-Z0-9_.:-]{0,64}$` |
| `.eventTooLarge(maxBytes)` | Single event > 32 KB |
| `.batchTooLarge(maxBytes, maxEvents)` | Batch > 3 MB or > 100 events |
| `.queueFull(maxSize)` | Local queue overflow |
| `.optedOut` | Explicit API call while user opted out |
| `.network(String)` | Transport failure |
| `.decoding(String)` | Invalid response from server |
| `.rateLimited(retryAfter)` | 429 response |
| `.serverError(status, message)` | 5xx |
| `.http(status, code, message, requestId)` | Other HTTP error |
| `.server(code, message, requestId)` | Unrecognized server error |

## Public Types

| Type | Purpose |
|------|---------|
| `PalbaseAnalytics` | Module entry — `PalbaseAnalytics.shared` |
| `AnalyticsError` | All errors thrown by PalbaseAnalytics |
| `AnalyticsValue` | Property value (string / int / double / bool / null / array / object) |

## Limits

| | Value |
|---|---|
| Event name | regex `^[a-zA-Z][a-zA-Z0-9_.:-]{0,64}$` |
| Event size | 32 KB |
| Batch size | 100 events OR 3 MB |
| Queue size | 1000 events (FIFO overflow) |
| Auto-flush interval | 10 seconds |
| Threshold flush | 50 events |
| Session inactivity | 30 minutes |
| Session max | 24 hours |

## TODO

- [ ] Device enrichment (OS version, model) — currently server-only
- [ ] Group analytics (`$groups` property)
- [ ] Cohort / funnel / retention queries — server-side only (service key required)
