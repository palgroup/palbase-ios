# PalbaseAuth

Authentication module for Palbase. Email/password, magic links, OAuth (Google, GitHub,
Microsoft, etc.), native Apple Sign In, sessions, MFA, passkeys.

## Setup

```swift
import PalbaseAuth

@main
struct MyApp: App {
    init() { Palbase.configure(apiKey: "pb_abc123_xxx") }
    var body: some Scene { ... }
}
```

`PalbaseAuth` re-exports `PalbaseCore`, so `import PalbaseAuth` is enough.

## Email & Password

```swift
// Sign up
let result = try await PalbaseAuth.shared.signUp(email: "a@b.com", password: "secret")

// Sign in
let result = try await PalbaseAuth.shared.signIn(email: "a@b.com", password: "secret")

// Sign out
try await PalbaseAuth.shared.signOut()

// Current user
let user = try await PalbaseAuth.shared.getUser()
```

## Email Verification

```swift
// User clicks the link in their email → URL has ?token=...
try await PalbaseAuth.shared.verifyEmail(token: tokenFromURL)

// Or by code
try await PalbaseAuth.shared.verifyEmail(code: "123456", email: "a@b.com")

// Resend
let challenge = try await PalbaseAuth.shared.resendVerification(email: "a@b.com")
print(challenge.token, challenge.code as Any)
```

## Password Reset

```swift
// Step 1: Request reset email
try await PalbaseAuth.shared.requestPasswordReset(email: "a@b.com")

// Step 2: User clicks link → token in URL → submit new password
try await PalbaseAuth.shared.confirmPasswordReset(
    token: tokenFromURL,
    newPassword: "newSecret"
)

// Change password while signed in
try await PalbaseAuth.shared.changePassword(
    currentPassword: "old",
    newPassword: "new"
)
```

## Magic Link (Passwordless)

```swift
// Send link
try await PalbaseAuth.shared.requestMagicLink(
    email: "a@b.com",
    redirectURL: "myapp://magic-link"
)

// In your AppDelegate / SwiftUI .onOpenURL:
let token = url.queryItems?["token"]
let result = try await PalbaseAuth.shared.verifyMagicLink(token: token)
```

## Social Login

### Apple Sign In (recommended for iOS)

```swift
let result = try await PalbaseAuth.shared.signInWithApple()
print("Welcome, \(result.user.email)")
```

Requires: enable **Sign in with Apple** capability in your Xcode target.

### OAuth via Web (Google, GitHub, etc.)

```swift
// SwiftUI
let window = UIApplication.shared.connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .flatMap(\.windows)
    .first { $0.isKeyWindow }!

let result = try await PalbaseAuth.shared.signInWithOAuth(
    provider: .google,
    callbackURLScheme: "myapp",
    presentationAnchor: window
)
```

Add the URL scheme to your Info.plist.

### Native ID Token Exchange

If you have an ID token from a native SDK (Google Sign In, Facebook SDK, etc.):

```swift
let result = try await PalbaseAuth.shared.signIn(
    provider: .google,
    credential: googleIDToken
)
```

### Supported Providers

`OAuthProvider` enum:
- `.google`, `.apple`, `.github`, `.microsoft`, `.facebook`, `.twitter`, `.discord`, `.slack`
- `.custom("name")` — for any provider configured on your Palbase project

## Linked Identities

```swift
// List linked accounts
let identities = try await PalbaseAuth.shared.listIdentities()

// Link another provider to current user
try await PalbaseAuth.shared.linkIdentity(provider: .github, credential: idToken)

// Unlink
try await PalbaseAuth.shared.unlinkIdentity(id: identity.id)
```

## Sessions

```swift
// Force refresh access token
let session = try await PalbaseAuth.shared.refresh()

// List all active sessions across devices
let sessions = try await PalbaseAuth.shared.listSessions()
for s in sessions {
    print("\(s.userAgent ?? "Unknown") — \(s.lastActivity) [current: \(s.current)]")
}

// Revoke specific session
try await PalbaseAuth.shared.revokeSession(id: sessions[0].id)

// Revoke ALL (sign out everywhere)
try await PalbaseAuth.shared.revokeAllSessions()
```

## Auth State Listener

```swift
class AuthViewModel: ObservableObject {
    @Published var session: Session?
    private var unsubscribe: Unsubscribe?

    init() {
        Task {
            let auth = try? PalbaseAuth.shared
            self.unsubscribe = await auth?.onAuthStateChange { [weak self] event, session in
                Task { @MainActor in
                    self?.session = session
                }
            }
        }
    }

    deinit { unsubscribe?() }
}
```

> **Always capture `self` weakly** to avoid retain cycles.

## Session Inspection

```swift
let session = await PalbaseAuth.shared.currentSession   // Session?
let signedIn = await PalbaseAuth.shared.isSignedIn      // Bool
```

## Error Handling

All public methods `throws(AuthError)`:

```swift
do {
    try await PalbaseAuth.shared.signIn(email: "...", password: "...")
} catch AuthError.invalidCredentials {
    showError("Wrong email or password")
} catch AuthError.emailNotVerified {
    showError("Please verify your email first")
} catch AuthError.mfaRequired(let challengeId) {
    promptMFA(challengeId)
} catch AuthError.notConfigured {
    fatalError("Call Palbase.configure(apiKey:) first")
} catch AuthError.network(let message) {
    showError("Network error: \(message)")
} catch {
    showError(error.localizedDescription)
}
```

### `AuthError` cases

| Case | When |
|------|------|
| `.invalidCredentials` | Wrong password or invalid OAuth token |
| `.userNotFound` | Email doesn't exist |
| `.emailAlreadyInUse` | Sign up with existing email |
| `.weakPassword` | Password fails policy |
| `.emailNotVerified` | Sign in requires verified email |
| `.mfaRequired(challengeId)` | MFA challenge needed before sign-in completes |
| `.sessionExpired` | Refresh failed or no valid session |
| `.noActiveSession` | Operation needs a signed-in user |
| `.network(message)` | Transport failure |
| `.decoding(message)` | Invalid response from server |
| `.rateLimited(retryAfter)` | Too many requests |
| `.serverError(status, message)` | 5xx |
| `.http(status, code, message, requestId)` | Other HTTP error |
| `.server(code, message, requestId)` | Unrecognized server error |
| `.notConfigured` | `Palbase.configure(_:)` not called |

## Public Types

| Type | Purpose |
|------|---------|
| `PalbaseAuth` | Module entry — `PalbaseAuth.shared` |
| `AuthError` | All errors thrown by PalbaseAuth |
| `User` | Authenticated user (id, email, emailVerified, ...) |
| `AuthSuccess` | `(user, session)` returned by sign-in/sign-up |
| `Session` | Access + refresh tokens (from PalbaseCore) |
| `OAuthProvider` | Enum of supported providers |
| `Identity` | Linked OAuth identity |
| `AuthSession` | One active session (from `listSessions`) |
| `VerificationChallenge` | Pending email verification (token + code) |

## TODO

- [ ] MFA (TOTP enroll/verify, email)
- [ ] Passkeys (ASAuthorizationPlatformPublicKeyCredentialProvider)
- [ ] Trusted devices
- [ ] DPoP (proof-of-possession)
