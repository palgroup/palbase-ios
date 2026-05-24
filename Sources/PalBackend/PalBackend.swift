import Foundation
@_exported import PalbaseBackend
import PalbaseAuth
import PalbaseAppAttest
import PalbaseCore

// Re-export the read-only domain + error types a backend app needs, so
// `import PalBackend` is the only import required. PalbaseBackend already
// re-exports PalbaseCore (Session, etc.) via @_exported.

/// The single entry point for the **palbackend** SDK.
///
/// `import PalBackend` gives an app with a managed backend exactly two
/// surfaces — `pb.backend.*` (typed RPC + upload) and `pb.auth.*` (the
/// full auth module) — and nothing else. Transport, token storage, App
/// Attest, and direct-DB access are all internal: a backend app cannot
/// bypass its backend by construction.
///
/// ```swift
/// import PalBackend
///
/// PalBackend.configure(apiKey: "pb_abc123m_c…")          // anon key
///
/// let room = try await pb.backend.call("rooms.create", CreateRoom(name: "lobby"))
/// try await pb.auth.signIn(email: "a@b.com", password: "…")
/// ```
public enum PalBackend {
    /// Configure with the project anon (publishable) key. The endpoint ref
    /// is embedded in the key, so the base URL is resolved automatically.
    public static func configure(apiKey: String) {
        Palbase.configure(apiKey: apiKey)
    }

    /// Configure with an environment mode (`.dev` targets the dev cluster).
    public static func configure(apiKey: String, mode: PalbaseMode) {
        Palbase.configure(apiKey: apiKey, mode: mode)
    }

    /// Configure and route backend RPC to a custom URL (typically a local
    /// `palbase backend dev` server). Auth still hits the cluster.
    public static func configure(apiKey: String, mode: PalbaseMode, backendURL: String) {
        Palbase.configure(apiKey: apiKey, mode: mode, backendURL: backendURL)
    }

    /// Configure and enable App Attest enforcement for backend RPC.
    ///
    /// When enabled, every backend call carries an App Attest assertion
    /// proving the request comes from a genuine build of the app on real
    /// hardware — requests from extracted keys / scripts are rejected
    /// server-side. This is the all-or-nothing flag: turning it on here
    /// activates the entire client→gateway verification chain. Leave it
    /// off (the default) in development and on the Simulator.
    ///
    /// Enforcement is only meaningful when the project also has App Attest
    /// turned on in Studio; the two must agree.
    public static func configure(apiKey: String, mode: PalbaseMode = .prod, appAttest: Bool) {
        Palbase.configure(apiKey: apiKey, mode: mode)
        if appAttest, let http = Palbase.backendHttp {
            Palbase.setAttestor(AppAttestProvider(http: http))
        } else {
            Palbase.setAttestor(nil)
        }
    }

    /// Project ref derived from the anon key.
    public static var endpointRef: String? { Palbase.endpointRef }
}

/// The configured client handle. `pb.backend` and `pb.auth` are the only
/// surfaces a backend app touches.
public struct PalBackendClient: Sendable {
    /// Typed RPC + upload client for the project's `defineEndpoint`s.
    public var backend: PalbaseBackend {
        get throws(BackendError) { try PalbaseBackend.shared }
    }

    /// The full auth module (email/OAuth/Apple/MFA/magic-link/sessions).
    public var auth: PalbaseAuth {
        get throws(AuthError) { try PalbaseAuth.shared }
    }

    fileprivate init() {}
}

/// Global accessor mirroring the JS SDK's `pb`. Lets call sites read
/// `pb.backend.call(...)` / `pb.auth.signIn(...)` after `PalBackend.configure`.
public let pb = PalBackendClient.make()

extension PalBackendClient {
    static func make() -> PalBackendClient { PalBackendClient() }
}
