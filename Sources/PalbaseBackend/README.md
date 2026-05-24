# PalbaseBackend

Typed RPC + file upload client for a project's managed backend (`defineEndpoint`
handlers running in the `br-<ref>` runtime). Issues `POST /rpc/{operationId}`.

Most apps consume this through the **[PalBackend](../PalBackend/README.md)**
façade product (`import PalBackend` → `pb.backend.*`). This module can also be
imported directly alongside the granular `palbase` modules.

## Call

```swift
struct CheckoutIn: Encodable, Sendable { let items: [String] }
struct CheckoutOut: Decodable, Sendable { let orderId: String }

let out: CheckoutOut = try await PalbaseBackend.shared.call("checkout", CheckoutIn(items: ["a"]))

// No-input endpoint:
let me: Me = try await PalbaseBackend.shared.call("me")
```

Inherits the SDK's auth-header injection, pre-flight token refresh, 401 replay,
429 back-off, and interceptors from the shared transport. On top of that it adds:

- **Typed, named errors** decoded from the standard error envelope, including Zod
  field errors — see `BackendError`.
- **Idempotency key** on mutating calls (`Idempotency-Key`, reused across retries).
- **App Attest** assertion headers when the project enforces it (provider injected
  by the façade; `nil` = off).

## Upload

```swift
struct Out: Decodable, Sendable { let url: String }
let out: Out = try await PalbaseBackend.shared.upload(
    "avatars.put", fileURL: url, fields: ["caption": "me"]
) { progress in print(progress.fraction) }
```

See `BackendUpload.swift` for `UploadConstraints` (client-side size/type guard)
and `BackendUploadProgress`.

## Errors — `BackendError`

| Case | Code | When |
|------|------|------|
| `.server(code:status:message:requestId:)` | the server code | handler `HttpError` / runtime error |
| `.validation(fields:requestId:)` | `validation_error` | input rejected by Zod (400) |
| `.rateLimited(retryAfter:)` | `rate_limited` | 429 |
| `.unauthorized(requestId:)` | `unauthorized` | 401 after refresh attempt |
| `.attestationUnavailable(reason:)` | `attestation_unavailable` | App Attest enforced, device can't attest |
| `.network(message:)` | `network_error` | connection lost / timeout / cancelled |
| `.transport(message:)` | `transport_error` | other transport failure |
| `.decode(message:)` / `.encode(message:)` | `decoding_error` / `encoding_error` | (de)serialization |
| `.notConfigured` | `not_configured` | `configure` not called |

`BackendError` conforms to `PalbaseError`; `PalbaseCoreError` never leaks through it.

## Codegen seam

`palbase backend types` (CLI) generates namespaced Swift over `call(_:_:)`:

```swift
let room = try await pb.backend.rooms.create(.init(name: "lobby"))
```

The generated shape is a namespace value per path segment hanging off
`PalbaseBackend`, with leaf operations lowering to `call`/`upload`. See
`Tests/PalbaseBackendTests/GeneratedSeamTests.swift` for the canonical template.
