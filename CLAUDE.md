# Palbase iOS SDK — Development Rules

## Project

Native Swift SDK for Palbase. Source-only SPM, multi-product (Firebase-style granular).
No KMP, no XCFramework, no third-party dependencies.

## Structure

```
palbase-ios/
├── Package.swift              → Multi-product manifest, swiftLanguageModes: [.v6]
├── .swift-format              → Format config (swift-format)
├── Sources/
│   ├── PalbaseCore/           → SDK foundation (PalbaseSDK, HttpClient, TokenManager)
│   ├── PalbaseAuth/           → AuthError, PalbaseAuth.shared
│   ├── PalbaseDB/             → relational DB (PostgREST)
│   ├── PalbaseDocs/           → document DB
│   ├── PalbaseStorage/        → file storage
│   ├── PalbaseRealtime/       → WebSocket
│   ├── PalbaseFunctions/      → edge functions
│   ├── PalbaseFlags/          → feature flags
│   ├── PalbaseNotifications/  → push/email/sms
│   ├── PalbaseAnalytics/      → event tracking
│   ├── PalbaseLinks/          → deep links
│   ├── PalbaseCms/            → content
│   └── Palbase/               → umbrella (re-exports + Palbase struct)
└── Tests/
    └── PalbaseCoreTests/      → Swift Testing (@Test, @Suite)
```

## API Architecture

### User-facing surface

- **`PalbaseSDK.configure(apiKey:)`** — call once at app startup
- **`PalbaseAuth.shared`** (and other `.shared`) — primary access point per module
- **`Palbase()`** — umbrella convenience for `palbase.auth.signIn(...)` syntax
- All async methods are **`async throws`** — typed errors per module
- Each module has its own `Error` enum implementing `PalbaseError` protocol

### Internal surface (hidden from users)

- **`HttpClient`, `TokenManager`, `HTTPRequesting`, `RequestInterceptor`** — `package` access
  - Visible to all modules in this SPM package
  - **NOT** visible to consumers of the SDK
  - Module clients use these via `PalbaseSDK.requireHTTP()` / `requireTokens()`
- DTO structs (request/response wire format) — `internal` (file-scoped via no modifier)
- Helper functions, type-erasure helpers — `internal` or `private`

### Visibility checklist (audit before every PR)

1. Anything user calls → `public`
2. Anything modules pass between each other → `package`
3. Anything inside one module → `internal` (default, no modifier)
4. Anything inside one file → `private` or `fileprivate`
5. **Default to most restrictive that compiles.** When in doubt, start `internal`.

## Core Patterns

### Errors

```swift
public protocol PalbaseError: Error, Sendable, LocalizedError {
    var code: String { get }              // snake_case stable identifier
    var statusCode: Int? { get }          // HTTP status if applicable
    var requestId: String? { get }        // server-side trace ID
}

// Each module:
public enum AuthError: PalbaseError {
    case invalidCredentials
    case userNotFound
    case mfaRequired(challengeId: String)
    case transport(PalbaseCoreError)      // wrap transport errors
    case server(code: String, message: String, requestId: String?)
}
```

Map server JSON envelope `{ error, error_description, request_id }` to typed cases via
`AuthError.from(envelope:)` static helper.

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
        get throws {
            let http = try PalbaseSDK.requireHTTP()
            let tokens = try PalbaseSDK.requireTokens()
            return PalbaseAuth(http: http, tokens: tokens)
        }
    }

    public func signIn(email: String, password: String) async throws -> AuthSuccess { ... }
}
```

- **`struct` not `actor`** — module clients are stateless wrappers, no shared mutable state
- **`package init`** — only umbrella/SDK can construct, users use `.shared`
- **`shared` is `throws`** — fails fast if `PalbaseSDK.configure(_:)` not called

### HTTP

Use `JSONEncoder.palbaseDefault` / `JSONDecoder.palbaseDefault` — they handle snake_case
conversion automatically. **Do not write `CodingKeys` for casing** — let the decoder strategy
handle it.

```swift
struct AuthResultDTO: Decodable, Sendable {
    let accessToken: String      // matches "access_token" automatically
    let refreshToken: String
    let expiresIn: Int
    let user: UserInfoDTO
}
```

Only write `CodingKeys` for non-trivial mappings (`error_description` → `message`).

### Concurrency

- `actor` for things with shared mutable state (`HttpClient`, `TokenManager`)
- `struct: Sendable` for stateless module clients
- `final class: Sendable` only when reference semantics needed (`State` container)
- All escaping closures `@Sendable`
- All `Task` blocks that capture `self` use `[weak self]`
- Strict concurrency enforced via `swiftLanguageModes: [.v6]`

## Configuration

```swift
public struct PalbaseConfig: Sendable {
    public let apiKey: String
    public let url: String?                 // base URL override
    public let serviceRoleKey: String?      // server-side bypass token
    public let headers: [String: String]
    public let urlSession: URLSession       // injectable for tests
    public let tokenStorage: TokenStorage   // protocol — InMemory or Keychain
    public let requestTimeout: TimeInterval
    public let maxRetries: Int
    public let initialBackoffMs: UInt64
}
```

`PalbaseSDK.configure(apiKey:)` shorthand uses defaults. `PalbaseSDK.configure(_:)` accepts
full config.

## Testing

- **Swift Testing** (`import Testing`, `@Test`, `@Suite`, `#expect`) — not XCTest
- Place tests under `Tests/{Module}Tests/`
- Use `@testable import` to access internal/package symbols
- `actor` helpers for thread-safe state (`actor ReceivedEvents { var events: [Event] }`)
- Mock HTTP via custom `URLProtocol` and inject via `PalbaseConfig.urlSession`

```swift
@Suite("PalbaseCore basics")
struct CoreTests {
    @Test("description")
    func methodName() async throws {
        #expect(actual == expected)
    }
}
```

## Build & Verify

```bash
swift build      # must succeed with no warnings
swift test       # all green
swift-format -i -r Sources/  # auto-format
```

## Refactor Roadmap

See main project for the 51-item refactor list. Phase 1 (R1-R17) done.
Next phases: full Auth (Phase 2), DB query builder (Phase 3), etc.

## Do NOT

- Use completion handlers — `async throws` only
- Use `URLSession.shared.dataTask` — `URLSession.data(for:)` async API
- Use third-party HTTP libraries — Foundation only
- Mark anything `public` if `package` or `internal` works
- Write `CodingKeys` just for snake_case — use `palbaseDefault` decoder
- Leak `self` in escaping closures
- Mix `Task`/actors with `DispatchQueue`
- Throw generic `Error` from public API — use a typed `PalbaseError`-conforming enum
- Add a public method without a corresponding test
- Create new `actor` for stateless types — use `struct: Sendable`
