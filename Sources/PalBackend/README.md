# PalBackend

The **palbackend** SDK — one import for apps with a managed Palbase backend.

`import PalBackend` gives you exactly two surfaces:

- `pb.backend.*` — typed RPC + file upload to your `defineEndpoint` handlers
- `pb.auth.*` — the full auth module (email, OAuth, Apple, MFA, magic link, sessions)

…and nothing else. Transport, token storage, App Attest, and direct database
access are internal. A backend app talks to **its backend**, not to the database —
so there is no second door that bypasses your server's business rules.

> Building a smaller app that talks directly to the database with RLS? Use the
> granular `palbase` modules (`PalbaseAuth` + `PalbaseDB` + …) instead.

## Configure

```swift
import PalBackend

// Anon (publishable) key — the project ref is embedded, base URL auto-resolves.
PalBackend.configure(apiKey: "pb_abc123m_c…")

// Dev cluster:
PalBackend.configure(apiKey: "pb_abc123s_c…", mode: .dev)

// Local `palbase backend dev` server for backend RPC (auth still hits cluster):
PalBackend.configure(apiKey: "pb_abc123s_c…", mode: .dev, backendURL: "http://localhost:4003")

// Enforce App Attest (production — see below):
PalBackend.configure(apiKey: "pb_abc123m_c…", appAttest: true)
```

## Calling endpoints

Every `defineEndpoint` you ship is reachable as a typed RPC.

```swift
struct CreateRoom: Encodable, Sendable { let name: String }
struct Room: Decodable, Sendable { let id: String; let name: String }

let room: Room = try await pb.backend.call("rooms.create", CreateRoom(name: "lobby"))
```

### Generated, namespaced API

Run `palbase backend types` (CLI) to generate Swift types from your backend's
published OpenAPI document. Calls then become namespaced and fully typed:

```swift
let room = try await pb.backend.rooms.create(.init(name: "lobby", capacity: 50))
// room: Rooms.Create.Output — room.id, room.name, room.capacity
```

The generated code is a thin layer over `call(_:_:)`; the wire convention is always
`POST /rpc/{operationId}`.

## Errors

Failures are a single typed `BackendError` you can `switch` on — including
**named** server errors and Zod field errors:

```swift
do {
    let room = try await pb.backend.rooms.create(.init(name: "x"))
} catch let error as BackendError {
    switch error {
    case .validation(let fields, _):
        for f in fields { print("\(f.field): \(f.message)") }   // map to form inputs
    case .server(let code, _, _, _) where code == "room_taken":
        // handle a named domain error your handler threw
    case .rateLimited(let retryAfter):
        // back off
    case .unauthorized:
        // re-auth
    default:
        break
    }
}
```

| Case | When |
|------|------|
| `.server(code:status:message:requestId:)` | `throw new HttpError(...)` in your handler, or runtime error |
| `.validation(fields:requestId:)` | input failed the endpoint's Zod schema (400) |
| `.rateLimited(retryAfter:)` | 429 — `retryAfter` from the `Retry-After` header |
| `.unauthorized(requestId:)` | 401 after the SDK already tried a token refresh |
| `.attestationUnavailable(reason:)` | App Attest enforced but the device can't attest |
| `.network` / `.transport` / `.decode` / `.encode` | transport / serialization failures |
| `.notConfigured` | `configure` not called |

Mutating calls automatically carry an `Idempotency-Key` reused across the
transport's retries, so a dropped-then-retried `POST` is not applied twice.

## File upload

For endpoints declaring an `upload` config:

```swift
struct PutAvatar: Decodable, Sendable { let url: String }

let out: PutAvatar = try await pb.backend.upload(
    "avatars.put",
    fileURL: localURL,
    fields: ["caption": "me"],
    constraints: UploadConstraints(maxSize: 5_000_000, allowedTypes: ["image/png"])
) { progress in
    print(progress.fraction)   // 0.0 … 1.0
}
```

When `constraints` are supplied, an oversize or wrong-type file is rejected
client-side (`.validation`) before any bytes are sent.

## App Attest (anti-abuse)

App Attest proves a request comes from a genuine build of your app on real Apple
hardware — requests replayed from an extracted anon key (Postman, scripts) are
rejected server-side.

- **Flag-gated, all-or-nothing.** `configure(..., appAttest: true)` activates the
  entire client→gateway verification chain. Off by default.
- **Production: recommended on.** Dev / Simulator: leave off (App Attest is
  unavailable on the Simulator).
- The project must also have App Attest enabled in Studio; the two must agree.

When enabled, the SDK enrolls a Secure-Enclave key on first use and attaches a
fresh, request-bound assertion to every backend call — entirely behind the
façade. You write no attestation code.
