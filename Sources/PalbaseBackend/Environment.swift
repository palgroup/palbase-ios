import Foundation
@_exported import PalbaseCore

/// Backend connection environment. Drives the base URL `PalbaseBackend`
/// uses for every `call(_:_:as:)` invocation.
///
/// Adım B14 — typed RPC + local auto-discovery.
public enum BackendEnvironment: Sendable {
    /// Default — Kong gateway via the configured `PalbaseConfig`.
    case remote
    /// Explicit base URL. Use for dev (`http://localhost:4003`) or any
    /// staging/preview environment that doesn't ride Kong.
    case custom(URL)
    #if DEBUG
    /// Bonjour-discovered `palbase backend dev` server on the local
    /// network. Falls through to `fallback` when discovery fails
    /// (no service advertised, multicast blocked, permission denied,
    /// 1.5s timeout). Compiled out of Release builds — production apps
    /// should never reach for the local dev loop.
    case autoDiscover(fallback: BackendEnvironmentFallback)
    #endif
}

#if DEBUG
/// `autoDiscover`'s fallback case is restricted to `.remote` or
/// `.custom(URL)` — recursion into `autoDiscover` is nonsensical and
/// the type system rules it out. Indirectly equivalent to a
/// `BackendEnvironment` minus the discover case.
public enum BackendEnvironmentFallback: Sendable {
    case remote
    case custom(URL)
}
#endif

extension BackendEnvironment {
    /// Convenience: `http://localhost:4003` — Mac dev server reachable
    /// from the iOS Simulator. Real devices need the Mac's LAN IP via
    /// `.custom(URL(string: "http://192.168.x.x:4003")!)` or
    /// `.autoDiscover(fallback: .remote)` (DEBUG only).
    public static let localhost = BackendEnvironment.custom(URL(string: "http://localhost:4003")!)
}
