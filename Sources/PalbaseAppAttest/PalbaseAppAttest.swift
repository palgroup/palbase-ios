import Foundation
@_exported import PalbaseCore

extension Palbase {
    /// Turn on App Attest enforcement for this app.
    ///
    /// Once enabled, every Palbase request (DB, storage, auth, …) carries a
    /// fresh, request-bound App Attest assertion proving the call comes
    /// from a genuine build of the app on real Apple hardware — requests
    /// replayed from an extracted API key are rejected server-side. The
    /// `/attest/*` enrollment endpoints and unauthenticated credential
    /// exchanges are exempt (they can't carry an assertion yet).
    ///
    /// Call once, after `Palbase.configure(...)`. This is the all-or-nothing
    /// switch — there is no per-request opt-in. Leave it off in development
    /// and on the Simulator (App Attest is unavailable there); on an
    /// unsupported device the SDK surfaces a clear error rather than
    /// silently dropping the guard.
    ///
    /// Enforcement is only meaningful when the project also has App Attest
    /// enabled server-side; the two must agree.
    public static func enableAppAttest() {
        guard let http = Palbase.http else { return }
        setAttestor(AppAttestProvider(http: http))
    }

    /// Turn App Attest enforcement back off.
    public static func disableAppAttest() {
        setAttestor(nil)
    }
}
