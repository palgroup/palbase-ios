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

/// Umbrella client — one-stop entry point that configures all modules with a shared
/// HttpClient and TokenManager.
///
/// ```swift
/// let palbase = PalbaseClient(apiKey: "pb_abc123_xxx")
/// let result = await palbase.auth.signIn(email: "...", password: "...")
/// ```
///
/// Prefer granular modules if you only need specific features (smaller binary):
/// ```swift
/// // Only depend on PalbaseAuth in your Package.swift
/// let http = HttpClient(apiKey: "pb_abc123_xxx")
/// let tokens = TokenManager()
/// let auth = PalbaseAuthClient(http: http, tokens: tokens)
/// ```
public final class PalbaseClient: Sendable {
    public let http: HttpClient
    public let tokens: TokenManager

    public let auth: PalbaseAuthClient
    public let db: PalbaseDBClient
    public let docs: PalbaseDocsClient
    public let storage: PalbaseStorageClient
    public let realtime: PalbaseRealtimeClient
    public let functions: PalbaseFunctionsClient
    public let flags: PalbaseFlagsClient
    public let notifications: PalbaseNotificationsClient
    public let analytics: PalbaseAnalyticsClient
    public let links: PalbaseLinksClient
    public let cms: PalbaseCmsClient

    public init(apiKey: String, options: HttpClientOptions = .init()) {
        let http = HttpClient(apiKey: apiKey, options: options)
        let tokens = TokenManager()

        self.http = http
        self.tokens = tokens
        self.auth = PalbaseAuthClient(http: http, tokens: tokens)
        self.db = PalbaseDBClient(http: http)
        self.docs = PalbaseDocsClient(http: http)
        self.storage = PalbaseStorageClient(http: http)
        self.realtime = PalbaseRealtimeClient(http: http)
        self.functions = PalbaseFunctionsClient(http: http)
        self.flags = PalbaseFlagsClient(http: http)
        self.notifications = PalbaseNotificationsClient(http: http)
        self.analytics = PalbaseAnalyticsClient(http: http)
        self.links = PalbaseLinksClient(http: http)
        self.cms = PalbaseCmsClient(http: http)

        Task { await http.setTokenManager(tokens) }
    }
}
