# Palbase iOS SDK

Native Swift SDK for [Palbase](https://palbase.studio) — Backend-as-a-Service.

- **Pure Swift**, no Kotlin bridging, no XCFramework
- **Swift 6** with strict concurrency — full `async/await`, `Sendable`, `actor`
- **Granular modules** (Firebase-style) — install only what you need
- Requires iOS 15+, macOS 13+, tvOS 15+, watchOS 8+

## Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies** → enter:

```
https://github.com/palgroup/palbase-ios
```

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

            // Option 2 — only what you need (smaller binary)
            .product(name: "PalbaseAuth", package: "palbase-ios"),
            .product(name: "PalbaseDB", package: "palbase-ios"),
        ]
    )
]
```

## Quick Start

### Umbrella client (all modules)

```swift
import Palbase

let palbase = PalbaseClient(apiKey: "pb_abc123_xxx")

// Auth
let result = await palbase.auth.signIn(email: "user@example.com", password: "secret")
if let auth = result.data {
    print("Signed in as \(auth.user.email)")
}

// Database (coming)
// let rooms = await palbase.db.from("rooms").select().execute()

// Documents (coming)
// let doc = await palbase.docs.collection("users").document("user1").get()
```

### Granular modules

```swift
import PalbaseCore
import PalbaseAuth

let http = HttpClient(apiKey: "pb_abc123_xxx")
let tokens = TokenManager()
await http.setTokenManager(tokens)

let auth = PalbaseAuthClient(http: http, tokens: tokens)
let result = await auth.signIn(email: "...", password: "...")
```

## Modules

| Module | Status | Description |
|--------|--------|-------------|
| `PalbaseCore` | ✅ | HttpClient, TokenManager, errors, types |
| `PalbaseAuth` | ✅ | Email/password sign in, sign up, sign out, get user |
| `PalbaseDB` | 🚧 | Relational database (PostgREST) |
| `PalbaseDocs` | 🚧 | Document database (Firestore-like) |
| `PalbaseStorage` | 🚧 | File storage |
| `PalbaseRealtime` | 🚧 | WebSocket subscriptions |
| `PalbaseFunctions` | 🚧 | Edge functions |
| `PalbaseFlags` | 🚧 | Feature flags |
| `PalbaseNotifications` | 🚧 | Push / email / SMS |
| `PalbaseAnalytics` | 🚧 | Event tracking |
| `PalbaseLinks` | 🚧 | Deep linking |
| `PalbaseCms` | 🚧 | Content management |

## Response Format

All API calls return `PalbaseResponse<T>`. API errors do **not** throw — check `.error`:

```swift
let response = await palbase.auth.signIn(email: "...", password: "...")
if let error = response.error {
    print("Error: \(error.code) — \(error.message)")
    return
}
let auth = response.data!  // type-safe, guaranteed non-nil when error is nil
```

Only non-HTTP errors throw (e.g., `TokenManager.refreshSession()` throws if no refresh token).

## Auth State Changes

Listen to auth state with a callback. **Capture `self` weakly** to avoid retain cycles:

```swift
class AuthViewModel {
    private var unsubscribe: Unsubscribe?

    init(client: PalbaseClient) {
        Task {
            self.unsubscribe = await client.tokens.onAuthStateChange { [weak self] event, session in
                self?.handleAuthChange(event, session)
            }
        }
    }

    deinit {
        unsubscribe?()
    }
}
```

The `Unsubscribe` closure is returned — call it when you no longer want events.

## Token Refresh

Once you call `signIn` / `signUp`, auto-refresh is wired. If the access token expires,
`HttpClient` will refresh it transparently before the next request.

Concurrent refresh calls are collapsed into a single request.

## Concurrency Model

- `HttpClient` and `TokenManager` are `actor` types — thread-safe by construction
- All public types are `Sendable`
- Built for Swift 6 strict concurrency (`swiftLanguageModes: [.v6]`)

Access the client from any Task or thread. For UI updates, hop to `@MainActor`:

```swift
Task { @MainActor in
    let result = await palbase.auth.signIn(email: "...", password: "...")
    self.isLoggedIn = result.data != nil
}
```

## License

MIT
