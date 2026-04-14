# Palbase iOS SDK

Native Swift SDK for [Palbase](https://palbase.studio).

- **Pure Swift**, no Kotlin bridging, no XCFramework
- **Swift 6** with strict concurrency — `async throws`, `Sendable`, `actor`
- **Granular modules** (Firebase-style) — install only what you need
- **Single configure point** — `PalbaseSDK.configure(apiKey:)`, then `.shared` everywhere
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
            // Option 1 — everything
            .product(name: "Palbase", package: "palbase-ios"),

            // Option 2 — granular (smaller binary)
            .product(name: "PalbaseAuth", package: "palbase-ios"),
            .product(name: "PalbaseDB", package: "palbase-ios"),
        ]
    )
]
```

## Quick Start

### 1. Configure once at app startup

```swift
import PalbaseCore

@main
struct MyApp: App {
    init() {
        PalbaseSDK.configure(apiKey: "pb_abc123_xxx")
    }
    var body: some Scene { ... }
}
```

For advanced setup (Keychain storage, custom URL, custom URLSession):

```swift
PalbaseSDK.configure(PalbaseConfig(
    apiKey: "pb_abc123_xxx",
    tokenStorage: KeychainTokenStorage(),  // coming soon
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
} catch let error as AuthError {
    switch error {
    case .invalidCredentials:
        print("Wrong password")
    case .userNotFound:
        print("No such user")
    default:
        print("Error: \(error.localizedDescription)")
    }
}
```

### 3. Or use the umbrella `Palbase`

```swift
import Palbase

let palbase = Palbase()
let result = try await palbase.auth.signIn(email: "...", password: "...")
let rooms = try await palbase.db.from("rooms").select().execute()  // coming soon
```

## Error Handling

All public methods `throw`. Each module defines its own typed error enum implementing `PalbaseError`:

```swift
public protocol PalbaseError: Error, Sendable, LocalizedError {
    var code: String { get }
    var statusCode: Int? { get }
    var requestId: String? { get }
}

public enum AuthError: PalbaseError {
    case invalidCredentials
    case userNotFound
    case emailAlreadyInUse
    case mfaRequired(challengeId: String)
    case transport(PalbaseCoreError)
    // ...
}
```

Use `do/catch` with pattern matching:

```swift
do {
    try await PalbaseAuth.shared.signIn(email: email, password: pass)
} catch AuthError.invalidCredentials {
    showError("Wrong credentials")
} catch AuthError.mfaRequired(let challengeId) {
    promptMfa(challengeId)
} catch let error as PalbaseError {
    showError(error.localizedDescription)
}
```

## Auth State Changes

Listen to auth events. **Capture `self` weakly** to avoid retain cycles:

```swift
class AuthViewModel {
    private var unsubscribe: Unsubscribe?

    init() {
        Task {
            guard let tokens = PalbaseSDK.tokens else { return }
            self.unsubscribe = await tokens.onAuthStateChange { [weak self] event, session in
                self?.handleAuthChange(event, session)
            }
        }
    }

    deinit {
        unsubscribe?()
    }
}
```

## Token Refresh

Auto-refresh is wired after first `signIn`/`signUp`. If the access token expires, the next
HTTP request transparently refreshes it. Concurrent refreshes are collapsed into one request.

## Concurrency

- `HttpClient` and `TokenManager` are `actor`s — thread-safe by construction
- All public types are `Sendable`
- Module clients are `struct` — cheap to create, value semantics
- `PalbaseSDK` global state is protected by `NSLock`

```swift
// Safe from any context
Task { @MainActor in
    let result = try await PalbaseAuth.shared.signIn(email: e, password: p)
    self.isLoggedIn = true
}
```

## Modules

| Module | Status | Description |
|--------|--------|-------------|
| `PalbaseCore` | ✅ | `PalbaseSDK`, `Session`, `PalbaseError` protocol, `TokenStorage` |
| `PalbaseAuth` | ✅ | `signUp`, `signIn`, `signOut`, `getUser`, auto-refresh |
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

## License

MIT
