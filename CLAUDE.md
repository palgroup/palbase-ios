# Palbase iOS SDK — Development Rules

## Project

Native Swift SDK for Palbase. Source-only SPM, granular per-module products
(Firebase-style). No KMP, no XCFramework, no third-party dependencies.

## Structure

```
palbase-ios/
├── Package.swift              → Multi-product manifest, swiftLanguageModes: [.v6]
├── .swift-format              → Format config
├── Sources/
│   ├── PalbaseCore/           → SDK foundation
│   │   ├── Palbase.swift      → public enum Palbase { configure(...) }
│   │   ├── PalbaseConfig.swift
│   │   ├── PalbaseError.swift → PalbaseError protocol + PalbaseCoreError enum
│   │   ├── HTTPRequesting.swift, HttpClient.swift  → package
│   │   ├── TokenManager.swift, TokenStorage.swift  → package
│   │   ├── KeychainTokenStorage (in TokenStorage.swift) → package, default
│   │   ├── RequestInterceptor.swift                 → package
│   │   ├── Codec.swift        → JSONDecoder/Encoder.palbaseDefault → package
│   │   └── Types.swift        → Session, AuthStateEvent, callback typealiases
│   ├── PalbaseAuth/           → AuthError, PalbaseAuth.shared
│   ├── PalbaseDB/, PalbaseDocs/, PalbaseStorage/, ...  → other modules
│   └── (no umbrella — users add modules they need)
└── Tests/
    └── PalbaseCoreTests/      → Swift Testing (@Test, @Suite)
```

## API Architecture

### User-facing surface

- **`Palbase.configure(apiKey:)`** — call once at app startup
- **`Palbase.configure(PalbaseConfig)`** — for advanced opts (URL, URLSession, timeouts)
- **`PalbaseAuth.shared`**, **`PalbaseDB.shared`**, etc. — module access
- **All async methods are `async throws(SpecificError)`** — typed errors per module

### Internal surface (`package` access — hidden from users)

- `HttpClient`, `TokenManager`, `HTTPRequesting`, `RequestInterceptor`
- `TokenStorage`, `InMemoryTokenStorage`, `KeychainTokenStorage`
- `JSONDecoder/Encoder.palbaseDefault`, `EmptyResponse`, `PalbaseErrorEnvelope`
- `RefreshFunction` typealias
- `Palbase.http`, `Palbase.tokens`, `Palbase.requireHTTP/requireTokens` accessors
- DTO struct (request/response wire format) — use no modifier (internal)

### Visibility rules

1. Anything user calls → `public`
2. Anything modules pass between each other → `package`
3. Anything inside one module → `internal` (default, no modifier)
4. Anything inside one file → `private` or `fileprivate`
5. **Default to most restrictive that compiles.** When in doubt, start `internal`.

### Public Surface Whitelist (audit before every PR)

Only these symbols are allowed to be `public`:

**PalbaseCore:**
- `enum Palbase` — `configure(apiKey:)`, `configure(_:)` ONLY
- `struct PalbaseConfig` + properties + init
- `protocol PalbaseError`
- `enum PalbaseCoreError` (referenced by module errors)
- `struct Session` + read-only properties (init is `package`)
- `enum AuthStateEvent`
- `typealias AuthStateCallback`
- `typealias Unsubscribe`

**Per module (e.g., PalbaseAuth):**
- `struct Palbase{Module}` + `static var shared` + public methods
- Module-specific `enum {Module}Error: PalbaseError`
- Domain types: `User`, `AuthSuccess`, `MFAFactor`, etc. (read-only — init is `package`)

**Forbidden public:**
- `HttpClient`, `TokenManager`, `HTTPRequesting`, `RequestInterceptor`
- `TokenStorage`, `KeychainTokenStorage`, `InMemoryTokenStorage`
- `JSONDecoder/Encoder.palbaseDefault`, `EmptyResponse`, `PalbaseErrorEnvelope`
- `RefreshFunction`, `Palbase.http`, `Palbase.tokens`, `Palbase.requireHTTP/Tokens`
- DTO structs (`AuthResultDTO`, `UserInfoDTO`, etc.) — keep `internal`
- Module client `init(http:tokens:)` — keep `package`
- Domain type `init` — keep `package` (users only read, never construct)
4. Anything inside one file → `private` or `fileprivate`
5. **Default to most restrictive that compiles.** When in doubt, start `internal`.

### Domain types (read-only by user)

- `Session`, `User`, `AuthSuccess` — public struct, but `init` is `package`
  (only SDK constructs them; users only read)

## Core Patterns

### Errors

```swift
public protocol PalbaseError: Error, Sendable, LocalizedError {
    var code: String { get }              // snake_case stable identifier
    var statusCode: Int? { get }
    var requestId: String? { get }
}

// Each module defines its own error type implementing PalbaseError:
public enum AuthError: PalbaseError {
    case invalidCredentials(message: String)
    case userNotFound(message: String)
    case mfaRequired(challengeId: String)
    case network(message: String)         // from PalbaseCoreError, mapped
    case rateLimited(retryAfter: Int?)
    case http(status: Int, code: String, message: String, requestId: String?)
    case server(code: String, message: String, requestId: String?)
    case notConfigured                     // SDK not configured
    // ... ~12 cases
}
```

**PalbaseCoreError must NOT leak through module errors.** Map transport errors via
`AuthError.from(transport: PalbaseCoreError)` so users only see one error type per call.

### Module client pattern

```swift
public struct PalbaseAuth: Sendable {           // struct, not actor
    private let http: HTTPRequesting             // package type
    private let tokens: TokenManager             // package type

    package init(http: HTTPRequesting, tokens: TokenManager) {
        self.http = http
        self.tokens = tokens
    }

    public static var shared: PalbaseAuth {
        get throws(AuthError) {
            guard let http = Palbase.http, let tokens = Palbase.tokens else {
                throw AuthError.notConfigured
            }
            return PalbaseAuth(http: http, tokens: tokens)
        }
    }

    public func signIn(email: String, password: String) async throws(AuthError) -> AuthSuccess { ... }
}
```

- **`struct` not `actor`** — module clients are stateless wrappers, no shared state
- **`package init`** — users use `.shared`, never construct directly
- **`shared` `throws(SpecificError)`** — module's own error type (not `PalbaseCoreError`)
- **All public methods `async throws(SpecificError)`** — typed throws everywhere

### Token persistence

- **Keychain by default** — `KeychainTokenStorage` is `package`, set internally by `Palbase.configure`
- Users never see `TokenStorage` — it's an implementation detail
- After `signIn`/`signUp`, session saved to Keychain automatically
- On `Palbase.configure(_:)`, session re-loaded from Keychain in background Task

### Auth state listener

Expose listener via the module client, NOT TokenManager directly:

```swift
// User writes:
let unsub = await PalbaseAuth.shared.onAuthStateChange { [weak self] event, session in
    self?.handle(event, session)
}

// PalbaseAuth.swift forwards to the internal TokenManager:
public func onAuthStateChange(_ callback: @escaping AuthStateCallback) async -> Unsubscribe {
    await tokens.onAuthStateChange(callback)
}
```

### HTTP

- `HttpClient` is `package actor` — `HTTPRequesting` protocol implementation
- All methods `async throws(PalbaseCoreError) -> ...`
- `JSONEncoder.palbaseDefault` / `JSONDecoder.palbaseDefault` (package) handle
  snake_case conversion automatically — **don't write `CodingKeys` for casing**
- Auto-retry: 3 attempts, exponential backoff
- 429 with `Retry-After` respected
- Interceptor untyped throws are wrapped to `PalbaseCoreError.network`

### Concurrency

- `actor` for shared mutable state (`HttpClient`, `TokenManager`, `KeychainTokenStorage`)
- `struct: Sendable` for stateless module clients
- `final class: Sendable` with `NSLock` only when reference semantics needed (`State`)
- All escaping closures `@Sendable`
- All `Task` blocks capturing `self` use `[weak self]`
- Strict concurrency enforced via `swiftLanguageModes: [.v6]`

## Configuration

```swift
public struct PalbaseConfig: Sendable {
    public let apiKey: String
    public let url: String?                 // base URL override
    public let serviceRoleKey: String?      // server-side bypass token
    public let headers: [String: String]
    public let urlSession: URLSession       // injectable for tests
    public let requestTimeout: TimeInterval
    public let maxRetries: Int
    public let initialBackoffMs: UInt64
}
```

`tokenStorage` is **not** a parameter — Keychain is forced (internal decision).

## Testing

- **Swift Testing** (`import Testing`, `@Test`, `@Suite`, `#expect`) — not XCTest
- Place tests under `Tests/{Module}Tests/`
- Use `@testable import` to access internal/package symbols
- `actor` helpers for thread-safe state collection
- Mock HTTP via custom `URLProtocol` and inject via `PalbaseConfig.urlSession`

## Build & Verify

```bash
swift build      # must succeed with no warnings
swift test       # all green
swift-format -i -r Sources/  # auto-format
```

## Documentation maintenance

Every module has its own `README.md` at `Sources/{Module}/README.md`. The root
`README.md` references them in a table.

**Rules — apply on every PR:**

1. Adding a new public method/type to a module → **update that module's README.md**
   - Add to the relevant section (e.g., "Magic Link", "Sessions")
   - Show a usage example
   - If error cases were added, update the `AuthError` (or module's error) table
2. Adding a new module or completing a placeholder → **update root README's module table**
   (move from 🚧 to ✅, link to its README)
3. Changing public API surface (visibility, signature, naming) → **update both the
   module README and CLAUDE.md's "Public Surface Whitelist"**
4. Never let docs lag behind code. If you skip docs in a PR, leave a TODO in the
   commit message and open a follow-up.

When you're unsure if a doc change is needed: read the affected README; if any code
example or type table is now incorrect → fix it.

## Refactor Roadmap

Phase 1 (R1-R17) done — see Tasks list. Next:
- Phase 2: Full Auth (magic link, OAuth, MFA, passkeys, ...)
- Phase 3-7: Implement DB, Docs, Storage, Realtime, etc.
- Phase 8-11: Production hardening, testing infra, docs, release CI

## Do NOT

- Use completion handlers — `async throws(...)` only
- Use `URLSession.shared.dataTask` — `URLSession.data(for:)` async API
- Use third-party HTTP libraries — Foundation only
- Mark anything `public` if `package` or `internal` works
- Write `CodingKeys` just for snake_case — use `palbaseDefault` decoder
- Leak `PalbaseCoreError` through module errors — map to module's own error type
- Leak `self` in escaping closures
- Mix `Task`/actors with `DispatchQueue`
- Throw untyped `Error` from public API — use module's typed `Error` enum
- Add a public method without a corresponding test
- Create new `actor` for stateless types — use `struct: Sendable`
- Re-introduce the umbrella `Palbase` struct — users add only modules they need
