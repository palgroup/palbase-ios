# Palbase iOS SDK — Development Rules

## Project

Native Swift SDK for Palbase, distributed via Swift Package Manager. Source-only, no XCFramework, no KMP.

## Structure

```
palbase-ios/
├── Package.swift              → Multi-product SPM manifest (Firebase-style)
├── Sources/
│   ├── PalbaseCore/           → HttpClient, TokenManager, errors, types
│   ├── PalbaseAuth/           → Auth module
│   ├── PalbaseDB/             → Relational DB (PostgREST)
│   ├── PalbaseDocs/           → Document DB
│   ├── PalbaseStorage/        → File storage
│   ├── PalbaseRealtime/       → WebSocket subscriptions
│   ├── PalbaseFunctions/      → Edge function invoke
│   ├── PalbaseFlags/          → Feature flags
│   ├── PalbaseNotifications/  → Push/email/SMS
│   ├── PalbaseAnalytics/      → Event tracking
│   ├── PalbaseLinks/          → Deep links
│   ├── PalbaseCms/            → Content mgmt
│   └── Palbase/               → Umbrella — re-exports all, PalbaseClient
└── Tests/
    └── PalbaseCoreTests/      → Core unit tests
```

Every module (except umbrella) depends only on `PalbaseCore`. Users install granularly.

## Language & Toolchain

- **Swift 6.0** — strict concurrency enabled via `swiftLanguageModes: [.v6]`
- **Platforms**: iOS 15+, macOS 13+, tvOS 15+, watchOS 8+
- **Foundation only** — no third-party dependencies
- **URLSession** for HTTP (not Alamofire/etc)
- **async/await** for all async APIs (no completion handlers)
- **actor** for shared mutable state
- **Sendable** on all public types

## Response Contract

All module methods return `PalbaseResponse<T>`. API errors (4xx/5xx) do NOT throw:

```swift
public struct PalbaseResponse<T: Sendable>: Sendable {
    public let data: T?
    public let error: PalbaseError?
    public let status: Int
    public let count: Int?
}
```

Non-API errors (e.g., missing refresh token, encoding failure) throw `PalbaseError`.

## API Design

### Naming

- Swift-native naming, not TS-ish (e.g., `signIn(email:password:)` not `signIn(credentials:)`)
- Use named parameters for clarity: `auth.signIn(email: "...", password: "...")`
- No `Palbase` prefix on types inside module (`User`, not `PalbaseUser`) — module name is the namespace
- Client types get `Palbase` prefix to avoid collision at call site (`PalbaseAuthClient`)

### Mirror TS SDK

API surface should mirror `palbase-ts` where possible. When TS does:
```ts
palbase.auth.signIn({ email, password })
```
Swift does:
```swift
await palbase.auth.signIn(email: "...", password: "...")
```

### Wire format

Server returns snake_case. Use `CodingKeys` to map to camelCase Swift types.
Keep DTO structs internal (`struct UserInfoDTO: Decodable`) and convert to public types.

## Concurrency

### actor vs final class

- **Shared mutable state** → `actor`
  - `HttpClient`, `TokenManager`, per-module clients that hold state
- **Stateless or init-only immutable** → `final class: Sendable` with all `let` properties
  - `PalbaseClient` (umbrella) — holds references but doesn't mutate after init

### Retain cycles

Callback API for listeners is primary. Document `[weak self]` requirement loudly in doc comments:

```swift
/// > Warning: Capture `self` weakly in the closure to avoid retain cycles:
/// > ```swift
/// > client.tokens.onAuthStateChange { [weak self] event, session in ... }
/// > ```
```

Inside library code, always `[weak self]` in escaping closures that capture `self`.

### Task management

Library does not spawn detached Tasks that outlive requests. If needed for event delivery,
Task is short-lived and doesn't capture strong `self`.

## HTTP Client

- `HttpClient` is an `actor`
- `request(_:path:body:headers:decoding:)` — generic decodable response
- `requestVoid(...)` — for 204 No Content / empty body
- Auto-retry: 3 attempts, exponential backoff (200ms base)
- 429 handling: respects `Retry-After` header
- Interceptors: `@Sendable (inout URLRequest) async throws -> Void`

## Auth Token Flow

1. `auth.signIn/signUp` → receives `AuthResult` from server
2. `AuthClient.handleAuthResult` → calls `tokens.setSession(...)`
3. `AuthClient.wireRefreshFunction` → installs closure into `TokenManager.refreshFunction`
4. On next request, if `tokens.isExpired` → `HttpClient` auto-calls `refreshSession()`
5. Concurrent refresh calls collapse into one via `refreshTask`

## Testing

- Use `XCTest` for unit tests (until Swift Testing is universally available)
- `actor` helpers for thread-safe assertion collection (e.g., `ReceivedBox`)
- Test retain cycles explicitly: assert listener count reaches 0 after unsubscribe
- For HTTP, inject custom `URLSession` with `URLProtocol` mocks
- Every public method: happy path + error path minimum

Test layout:
```
Tests/
└── PalbaseCoreTests/
    ├── PalbaseCoreTests.swift            → basic types, parsers
    └── TokenManagerRetainCycleTests.swift → lifecycle, listener cleanup
```

## Build & Verify

```bash
swift build                  # must succeed with no warnings
swift test                   # all green
```

Lokal dev:
```bash
cd palbase-ios
swift build
swift test
```

Xcode için: Package.swift'i direkt aç, Xcode SPM projesi olarak tanır.

## Distribution

- Source-only SPM — no binary, no XCFramework
- User import: `https://github.com/palgroup/palbase-ios`, version semver tag
- Tag `0.x.y` (no `v` prefix) — SPM reads semver tags directly

## CI (TODO)

- `on: push to main` → `swift build && swift test` on macOS runner
- `on: push tags '*.*.*'` → tag the release (no publish step needed, SPM pulls from git)

## Do NOT

- Use completion handlers — async/await only
- Use third-party HTTP (Alamofire, Moya, etc.) — Foundation URLSession
- Block main thread — everything async
- Leak `self` in closures
- Store tokens in UserDefaults — `Keychain` when TokenStorage is added
- Use `any` type — strong typing always
- Mix Swift concurrency with DispatchQueue — pure Task/actor
- Throw for API (4xx/5xx) errors — return `PalbaseResponse` with `.error` populated
- Add features without matching test — every public method needs at least one test
