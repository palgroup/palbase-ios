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

/// Umbrella client. All modules share a single HttpClient and TokenManager.
///
/// ```swift
/// let palbase = PalbaseClient(apiKey: "pb_abc123_xxx")
/// let result = await palbase.auth.signIn(email: "...", password: "...")
/// ```
///
/// For smaller binaries, use granular modules instead:
/// ```swift
/// let auth = PalbaseAuthClient(apiKey: "pb_abc123_xxx")
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
        self.auth = PalbaseAuthClient(sharedHttp: http, sharedTokens: tokens)
        self.db = PalbaseDBClient(sharedHttp: http, sharedTokens: tokens)
        self.docs = PalbaseDocsClient(sharedHttp: http, sharedTokens: tokens)
        self.storage = PalbaseStorageClient(sharedHttp: http, sharedTokens: tokens)
        self.realtime = PalbaseRealtimeClient(sharedHttp: http, sharedTokens: tokens)
        self.functions = PalbaseFunctionsClient(sharedHttp: http, sharedTokens: tokens)
        self.flags = PalbaseFlagsClient(sharedHttp: http, sharedTokens: tokens)
        self.notifications = PalbaseNotificationsClient(sharedHttp: http, sharedTokens: tokens)
        self.analytics = PalbaseAnalyticsClient(sharedHttp: http, sharedTokens: tokens)
        self.links = PalbaseLinksClient(sharedHttp: http, sharedTokens: tokens)
        self.cms = PalbaseCmsClient(sharedHttp: http, sharedTokens: tokens)

        Task { await http.setTokenManager(tokens) }
    }
}
