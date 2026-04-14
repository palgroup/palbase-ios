# PalbaseCore

Foundation module for the Palbase SDK. Not added directly by users — it's a transitive
dependency of every module (e.g., `PalbaseAuth`, `PalbaseDB`).

When you `import PalbaseAuth`, Core's symbols (`Palbase`, `PalbaseConfig`, `Session`,
errors) are re-exported automatically.

## Public API

### `Palbase` — SDK entry point

```swift
Palbase.configure(apiKey: "pb_abc123_xxx")        // simple
Palbase.configure(PalbaseConfig(apiKey: "...",    // advanced
                                requestTimeout: 30,
                                maxRetries: 3))
```

Call once at app startup (e.g., in `App.init()` or `AppDelegate`).

### `PalbaseConfig`

| Field | Default | Purpose |
|-------|---------|---------|
| `apiKey` | required | `pb_{ref}_{random}` |
| `url` | derived from key | Override base URL |
| `serviceRoleKey` | nil | Server-side bypass token |
| `headers` | empty | Extra request headers |
| `urlSession` | `.shared` | URLSession for HTTP (override for tests/background) |
| `requestTimeout` | 30s | Per-request timeout |
| `maxRetries` | 3 | Network/429 retry count |
| `initialBackoffMs` | 200 | Backoff base, doubles per attempt |

> Token storage is fixed to **Keychain** (encrypted, persists across launches).
> Sessions are loaded automatically on `configure(_:)`.

### `Session`

```swift
public struct Session: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Int64       // Unix seconds
    public var isExpired: Bool { ... }
}
```

You don't construct `Session` — it's returned by `PalbaseAuth` after sign-in.

### `PalbaseError` protocol

Every module defines its own error enum implementing this protocol:

```swift
public protocol PalbaseError: Error, Sendable, LocalizedError {
    var code: String { get }              // snake_case stable ID
    var statusCode: Int? { get }
    var requestId: String? { get }
}
```

### `PalbaseCoreError`

Internal transport-level errors. Modules wrap these into their own error types:
- `.network(message:)`, `.http(status:code:message:requestId:)`
- `.decoding(message:)`, `.encoding(message:)`
- `.rateLimited(retryAfter:)`, `.server(status:message:)`
- `.invalidConfiguration(message:)`, `.notConfigured`, `.tokenRefreshFailed(message:)`

### Auth state

```swift
public enum AuthStateEvent { case sessionSet, sessionCleared, tokenRefreshed }
public typealias AuthStateCallback = @Sendable (AuthStateEvent, Session?) -> Void
public typealias Unsubscribe = @Sendable () -> Void
```

Listen via your module client (e.g., `PalbaseAuth.shared.onAuthStateChange { ... }`).

## Internal Architecture

These types are `package` access — visible across SDK modules but **not** to consumers:

- `HttpClient` — actor, implements `HTTPRequesting` protocol
- `TokenManager` — actor, holds session + refresh function
- `KeychainTokenStorage` / `InMemoryTokenStorage` — `TokenStorage` protocol implementations
- `RequestInterceptor` protocol — middleware hook
- `JSONDecoder/Encoder.palbaseDefault` — snake_case ↔ camelCase auto-conversion
- `EmptyResponse`, `PalbaseErrorEnvelope` — wire-format helpers

Module clients (`PalbaseAuth`, etc.) get HTTPRequesting via:

```swift
guard let http = Palbase.http else { throw .notConfigured }
```

## Concurrency

- All public types `Sendable`
- `HttpClient` and `TokenManager` are `actor`s
- `KeychainTokenStorage` is an `actor`
- Strict concurrency enabled (`swiftLanguageModes: [.v6]`)
