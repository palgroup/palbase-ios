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

## MFA (Multi-Factor Auth)

### TOTP enrollment (Authenticator apps)

```swift
// 1. Start enrollment — show secret/QR to user
let result = try await PalbaseAuth.shared.enrollMFA(type: .totp)
// result.secret           → "JBSWY3DPEHPK3PXP" (Base32)
// result.otpUrl           → "otpauth://totp/Palbase:..." (feed to QR generator)
// result.recoveryCodes    → ["abcd-efgh", ...] (show ONCE, ask to save)

// 2. User scans QR with Google Authenticator / 1Password
// 3. User enters the 6-digit code from their app
try await PalbaseAuth.shared.verifyMFAEnrollment(code: "123456")
```

### Sign-in with MFA

```swift
do {
    try await PalbaseAuth.shared.signIn(email: email, password: password)
} catch AuthError.mfaRequired(let challengeId) {
    // Prompt user for MFA code
    let code = await promptForCode()
    try await PalbaseAuth.shared.submitMFAChallenge(
        mfaToken: challengeId,
        type: .totp,
        code: code
    )
}
```

### Recovery codes

```swift
// User lost their authenticator app:
try await PalbaseAuth.shared.recoverMFA(
    mfaToken: challengeId,
    recoveryCode: "abcd-efgh"
)
```

### Email MFA

```swift
// Enroll email as a factor
try await PalbaseAuth.shared.enrollEmailMFA()

// On sign-in, send code to email
try await PalbaseAuth.shared.sendEmailMFACode(mfaToken: challengeId)

// Verify code
try await PalbaseAuth.shared.verifyEmailMFACode(
    mfaToken: challengeId,
    code: "123456"
)
```

### Manage factors

```swift
let factors = try await PalbaseAuth.shared.listMFAFactors()
for f in factors {
    print("\(f.type.rawValue) — verified: \(f.verified)")
}

try await PalbaseAuth.shared.removeMFAFactor(id: factors[0].id)

let newCodes = try await PalbaseAuth.shared.regenerateRecoveryCodes()
// Show new codes once, invalidate old ones
```

## Trusted Devices

Skip MFA for known devices.

```swift
// Generate a stable fingerprint for this device (do this yourself)
let fingerprint = sha256("\(UIDevice.current.identifierForVendor!)|\(Bundle.main.bundleIdentifier!)")

// Register after successful sign-in
let token = try await PalbaseAuth.shared.registerTrustedDevice(
    fingerprintHash: fingerprint,
    deviceName: "iPhone 15 Pro"
)
// Save token to Keychain — present on future sign-ins to skip MFA

// List
let devices = try await PalbaseAuth.shared.listTrustedDevices()

// Revoke
try await PalbaseAuth.shared.revokeTrustedDevice(id: devices[0].id)
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
| `.mfaInvalidCode` | Wrong TOTP/email code |
| `.mfaFactorNotFound` | Factor ID doesn't exist |
| `.passkeyNotSupported` | Passkeys require iOS 16+ |
| `.passkeyCancelled` | User cancelled passkey prompt |
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
| `MFAFactorType` | `.totp`, `.email`, `.passkey` |
| `MFAFactor` | Enrolled MFA factor |
| `MFAEnrollResult` | TOTP secret, otp URL, recovery codes |
| `TrustedDevice` | Registered trusted device entry |

## TODO

- [ ] Passkeys (ASAuthorizationPlatformPublicKeyCredentialProvider) — backend not ready yet
- [ ] DPoP (proof-of-possession token binding) — Phase 8
