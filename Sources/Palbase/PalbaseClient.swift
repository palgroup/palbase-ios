import Foundation
@_exported import PalbaseCore
@_exported import PalbaseAuth
@_exported import PalbaseDB
@_exported import PalbaseDocs
@_exported import PalbaseStorage
@_exported import PalbaseRealtime
@_exported import PalbaseFunctions
@_exported import PalbaseFlags
@_exported import PalbaseNotifications
@_exported import PalbaseAnalytics
@_exported import PalbaseLinks
@_exported import PalbaseCms

/// Convenience accessor that exposes all module clients as namespaced properties.
/// Useful when you want one symbol that's "the SDK".
///
/// ```swift
/// PalbaseSDK.configure(apiKey: "pb_abc123_xxx")
///
/// let palbase = Palbase()
/// try await palbase.auth.signIn(email: "...", password: "...")
/// ```
///
/// Equivalent to using each module's `.shared`:
/// ```swift
/// try await PalbaseAuth.shared.signIn(...)
/// ```
public struct Palbase: Sendable {
    public init() {}

    public var auth: PalbaseAuth {
        get throws { try PalbaseAuth.shared }
    }

    public var db: PalbaseDB {
        get throws { try PalbaseDB.shared }
    }

    public var docs: PalbaseDocs {
        get throws { try PalbaseDocs.shared }
    }

    public var storage: PalbaseStorage {
        get throws { try PalbaseStorage.shared }
    }

    public var realtime: PalbaseRealtime {
        get throws { try PalbaseRealtime.shared }
    }

    public var functions: PalbaseFunctions {
        get throws { try PalbaseFunctions.shared }
    }

    public var flags: PalbaseFlags {
        get throws { try PalbaseFlags.shared }
    }

    public var notifications: PalbaseNotifications {
        get throws { try PalbaseNotifications.shared }
    }

    public var analytics: PalbaseAnalytics {
        get throws { try PalbaseAnalytics.shared }
    }

    public var links: PalbaseLinks {
        get throws { try PalbaseLinks.shared }
    }

    public var cms: PalbaseCms {
        get throws { try PalbaseCms.shared }
    }
}
