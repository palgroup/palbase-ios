# Palbase iOS SDK

Native Swift SDK for [Palbase](https://palbase.studio).

- **Pure Swift**, no Kotlin bridging, no XCFramework
- **Swift 6** with strict concurrency — `async throws`, `Sendable`, `actor`
- **Typed throws** — every method declares its specific error enum
- **Granular modules** (Firebase-style) — install only what you need
- **Single configure point** — `Palbase.configure(apiKey:)`, then module `.shared` everywhere
- **Keychain by default** — sessions persist across app launches automatically
- iOS 15+ / macOS 13+ / tvOS 15+ / watchOS 8+

## Installation

In Xcode: **File → Add Package Dependencies** → `https://github.com/palgroup/palbase-ios`

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/palgroup/palbase-ios", from: "0.1.0")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            // Install only what you need (smaller binary)
            .product(name: "PalbaseAuth", package: "palbase-ios"),
            .product(name: "PalbaseDB", package: "palbase-ios"),
        ]
    )
]
```

There is no umbrella product. Add each module you actually use.

## Quick Start

### 1. Configure once at app startup

```swift
import PalbaseCore

@main
struct MyApp: App {
    init() {
        Palbase.configure(apiKey: "pb_abc123_xxx")
    }
    var body: some Scene { ... }
}
```

For advanced setup (custom URL, URLSession, timeouts):

```swift
Palbase.configure(PalbaseConfig(
    apiKey: "pb_abc123_xxx",
    requestTimeout: 30,
    maxRetries: 3
))
```

### 2. Use modules via `.shared`

```swift
import PalbaseAuth

do {
    let result = try await PalbaseAuth.shared.signIn(
        email: "user@example.com",
        password: "secret"
    )
    print("Signed in: \(result.user.email)")
} catch AuthError.invalidCredentials {
    print("Wrong password")
} catch AuthError.notConfigured {
    fatalError("Call Palbase.configure(apiKey:) first")
} catch {
    print("Error: \(error.localizedDescription)")
}
```

## Error Handling

Every method uses **typed throws** — the error type is part of the signature:

```swift
public func signIn(...) async throws(AuthError) -> AuthSuccess
```

`AuthError` is an exhaustive enum:

```swift
public enum AuthError: PalbaseError {
    case invalidCredentials(message: String)
    case userNotFound(message: String)
    case emailAlreadyInUse(message: String)
    case weakPassword(message: String)
    case emailNotVerified(message: String)
    case mfaRequired(challengeId: String)
    case sessionExpired(message: String)
    case noActiveSession(message: String)
    case network(message: String)
    case decoding(message: String)
    case rateLimited(retryAfter: Int?)
    case serverError(status: Int, message: String)
    case http(status: Int, code: String, message: String, requestId: String?)
    case server(code: String, message: String, requestId: String?)
    case notConfigured
}
```

Each module defines its own error enum implementing the `PalbaseError` protocol:

```swift
public protocol PalbaseError: Error, Sendable, LocalizedError {
    var code: String { get }              // snake_case stable identifier
    var statusCode: Int? { get }
    var requestId: String? { get }
}
```

## Auth State Changes

```swift
class AuthViewModel: ObservableObject {
    @Published var session: Session?
    private var unsubscribe: Unsubscribe?

    init() {
        Task {
            let auth = try? PalbaseAuth.shared
            self.unsubscribe = await auth?.onAuthStateChange { [weak self] event, session in
                Task { @MainActor in self?.session = session }
            }
        }
    }

    deinit { unsubscribe?() }
}
```

> **Warning:** Always capture `self` weakly. The library returns the `Unsubscribe`
> closure — call it when you no longer want events.

## Session Persistence

Sessions are stored in **Keychain** automatically. After `signIn`, the session survives
app restarts and is re-loaded on `Palbase.configure(_:)`.

You don't manage tokens. The SDK handles:

- Saving to Keychain after `signIn`/`signUp`
- Auto-refreshing the access token before it expires
- Collapsing concurrent refresh calls into one request
- Clearing on `signOut`

```swift
let isSignedIn = await PalbaseAuth.shared.isSignedIn
let session = await PalbaseAuth.shared.currentSession
```

## Concurrency

- All public types are `Sendable`
- All methods are `async throws(SpecificError)`
- Module clients are `struct` — value semantics, cheap
- Internal `HttpClient` and `TokenManager` are `actor`s — thread-safe

```swift
Task { @MainActor in
    let result = try await PalbaseAuth.shared.signIn(email: e, password: p)
    self.isLoggedIn = true
}
```

## Modules

| Module | Status | Description |
|--------|--------|-------------|
| `PalbaseCore` | ✅ | `Palbase`, `Session`, `PalbaseError` protocol, `PalbaseConfig` |
| `PalbaseAuth` | ✅ | `signUp`, `signIn`, `signOut`, `getUser`, auto-refresh, listener |
| `PalbaseDB` | 🚧 | Relational DB (PostgREST query builder) |
| `PalbaseDocs` | 🚧 | Document DB (Firestore-like) |
| `PalbaseStorage` | 🚧 | File storage with progress |
| `PalbaseRealtime` | 🚧 | WebSocket subscriptions |
| `PalbaseFunctions` | 🚧 | Edge functions |
| `PalbaseFlags` | 🚧 | Feature flags |
| `PalbaseNotifications` | 🚧 | Push / email / SMS |
| `PalbaseAnalytics` | 🚧 | Event tracking |
| `PalbaseLinks` | 🚧 | Deep linking |
| `PalbaseCms` | 🚧 | Content management |

## Public API Surface

The SDK only exposes what you need. Internal types like `HttpClient`, `TokenManager`,
`KeychainTokenStorage` are hidden via Swift's `package` access level.

What you'll see in autocomplete:

- `Palbase.configure(apiKey:)`
- `PalbaseConfig`
- `PalbaseAuth.shared` (and other module `.shared`)
- `Session`, `User`, `AuthSuccess`
- `AuthStateEvent`, `AuthStateCallback`, `Unsubscribe`
- `PalbaseError` protocol
- `PalbaseCoreError`, `AuthError` enums

## License

MIT
