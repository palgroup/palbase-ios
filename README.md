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
            // Install only what you need
            .product(name: "PalbaseAuth", package: "palbase-ios"),
            .product(name: "PalbaseDB", package: "palbase-ios"),
        ]
    )
]
```

`PalbaseCore` is a transitive dependency — every module re-exports its symbols.

## Quick Start

```swift
import PalbaseAuth   // implicitly imports Palbase.configure, etc.

@main
struct MyApp: App {
    init() {
        Palbase.configure(apiKey: "pb_abc123_xxx")
    }
    var body: some Scene { ... }
}

// Sign in
let result = try await PalbaseAuth.shared.signIn(
    email: "user@example.com",
    password: "secret"
)
```

## Modules

| Module | Status | Docs |
|--------|--------|------|
| [`PalbaseCore`](Sources/PalbaseCore/README.md) | ✅ | SDK foundation: `Palbase.configure`, `PalbaseConfig`, `Session`, `PalbaseError` |
| [`PalbaseAuth`](Sources/PalbaseAuth/README.md) | ✅ | Email/password, magic link, OAuth, Apple Sign In, sessions |
| [`PalbaseDB`](Sources/PalbaseDB/README.md) | ✅ | Relational DB (PostgREST): typed queries, RPC, transactions |
| [`PalbaseDocs`](Sources/PalbaseDocs/README.md) | ✅ | Document DB (Firestore-like): refs, queries, transforms, batch, transactions, listeners |
| [`PalbaseStorage`](Sources/PalbaseStorage/README.md) | ✅ | File storage: upload/download, signed URLs, transforms, resumable (TUS) |
| [`PalbaseRealtime`](Sources/PalbaseRealtime/README.md) | ✅ | WebSocket: broadcast, presence, postgres_changes |
| [`PalbaseFunctions`](Sources/PalbaseFunctions/README.md) | 🚧 | Edge functions |
| [`PalbaseFlags`](Sources/PalbaseFlags/README.md) | ✅ | Feature flags: typed values, cache, realtime sync, per-key listeners |
| [`PalbaseNotifications`](Sources/PalbaseNotifications/README.md) | 🚧 | Push / email / SMS |
| [`PalbaseAnalytics`](Sources/PalbaseAnalytics/README.md) | ✅ | Event tracking: capture, identify, alias, screen/page, offline queue, auto-flush |
| [`PalbaseLinks`](Sources/PalbaseLinks/README.md) | 🚧 | Deep linking |
| [`PalbaseCms`](Sources/PalbaseCms/README.md) | 🚧 | Content management |

> The managed-backend SDK lives in its own repo:
> [`palbackend-ios`](https://github.com/palgroup/palbackend-ios) — a single
> closed surface (`configure` + `pb.backend.*` + `pb.auth.*`) for apps that
> need a backend. palbase-ios is the small-project surface only.

## Concepts

### Configuration

```swift
Palbase.configure(apiKey: "pb_abc123_xxx")  // simplest
Palbase.configure(PalbaseConfig(apiKey: "...", requestTimeout: 60))  // full options
```

See [PalbaseCore](Sources/PalbaseCore/README.md) for all `PalbaseConfig` fields.

### Errors — typed throws per module

Every module has its own error enum. Example with `AuthError`:

```swift
do {
    try await PalbaseAuth.shared.signIn(email: "...", password: "...")
} catch AuthError.invalidCredentials {
    showError("Wrong password")
} catch AuthError.notConfigured {
    fatalError("Call Palbase.configure(apiKey:) first")
} catch {
    showError(error.localizedDescription)
}
```

All module errors implement the `PalbaseError` protocol:

```swift
public protocol PalbaseError: Error, Sendable, LocalizedError {
    var code: String { get }       // snake_case stable identifier
    var statusCode: Int? { get }
    var requestId: String? { get }
}
```

### Session persistence

Sessions are stored in **Keychain** automatically. After `signIn`/`signUp`:
- Saved to Keychain (encrypted, survives app restarts)
- Auto-refresh when access token expires
- Concurrent refresh calls collapsed into one
- Cleared on `signOut`

### Concurrency

- All public types are `Sendable`
- All async methods are `async throws(SpecificError)`
- Module clients are `struct` (value semantics, cheap)
- Internal `HttpClient`, `TokenManager` are `actor`s

```swift
Task { @MainActor in
    let result = try await PalbaseAuth.shared.signIn(email: e, password: p)
    self.isLoggedIn = true
}
```

## Public API Surface

The SDK only exposes what you need. Internal types like `HttpClient`, `TokenManager`,
`KeychainTokenStorage` are hidden via Swift's `package` access level.

What you'll see in autocomplete:

- `Palbase.configure(apiKey:)` / `Palbase.configure(_:)`
- `PalbaseConfig`
- `PalbaseAuth.shared` (and other module `.shared`)
- Module-specific errors (`AuthError`, etc.)
- Read-only domain types (`Session`, `User`, `AuthSuccess`, ...)

See each module's README for its specific API.

## License

MIT
