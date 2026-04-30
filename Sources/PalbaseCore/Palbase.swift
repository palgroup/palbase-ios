import Foundation

/// Single global entry point for SDK configuration. Inspired by `FirebaseApp.configure()`.
///
/// Call once at app startup:
/// ```swift
/// Palbase.configure(apiKey: "pb_abc123_xxx")
///
/// // Anywhere else:
/// let auth = try PalbaseAuth.shared
/// try await auth.signIn(email: "...", password: "...")
/// ```
public enum Palbase {
    private static let state = State()

    /// Configure the SDK with a single API key. Most apps use this.
    /// Targets the production cluster by default — for dev clusters,
    /// pass `mode: .dev`.
    public static func configure(apiKey: String) {
        configure(PalbaseConfig(apiKey: apiKey))
    }

    /// Configure the SDK with a single API key + environment mode.
    /// `.dev` swaps the SDK's base URL to `<ref>.dev.palbase.studio`.
    public static func configure(apiKey: String, mode: PalbaseMode) {
        configure(PalbaseConfig(apiKey: apiKey, mode: mode))
    }

    /// Configure with full options (custom URL, URLSession, timeouts, etc.).
    public static func configure(_ config: PalbaseConfig) {
        let storage = KeychainTokenStorage()
        let tokens = TokenManager(storage: storage)
        let http = HttpClient(config: config, tokens: tokens)
        state.set(config: config, tokens: tokens, http: http)

        // Hydrate session from Keychain in background
        Task { await tokens.loadFromStorage() }
    }

    package static var config: PalbaseConfig? { state.config }
    package static var http: HTTPRequesting? { state.http }
    package static var tokens: TokenManager? { state.tokens }

    /// API key supplied to `configure(apiKey:)`. `nil` until configured.
    /// Public accessor so `PalbaseBackend.shared` (and any future module
    /// that needs the raw apikey for direct HTTP) can read it without
    /// reaching into HttpClient.
    public static var apiKey: String? { state.config?.apiKey }

    /// Project ref derived from the apikey (`pb_<ref>_c<random>` /
    /// `pb_<ref>_s<random>`). `nil` when no apikey has been set.
    public static var endpointRef: String? {
        guard let key = state.config?.apiKey else { return nil }
        let parts = key.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    /// Public host the SDK targets. Order of precedence:
    /// (1) `PalbaseConfig.url` if explicitly set,
    /// (2) the configured `PalbaseMode`'s domain (`palbase.studio` or
    ///     `dev.palbase.studio`),
    /// (3) `nil` when nothing is configured yet.
    /// Used by `PalbaseBackend` to build per-tenant URLs without
    /// reaching into HttpClient.
    public static var host: String? {
        if let configured = state.config?.url {
            if let url = URL(string: configured), let host = url.host {
                return host
            }
            return configured
        }
        guard let cfg = state.config else { return nil }
        return cfg.mode.domain
    }

    package static func requireHTTP() throws(PalbaseCoreError) -> HTTPRequesting {
        guard let http = state.http else { throw PalbaseCoreError.notConfigured }
        return http
    }

    package static func requireTokens() throws(PalbaseCoreError) -> TokenManager {
        guard let tokens = state.tokens else { throw PalbaseCoreError.notConfigured }
        return tokens
    }
}

/// Thread-safe container for SDK state.
final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var _config: PalbaseConfig?
    private var _tokens: TokenManager?
    private var _http: HTTPRequesting?

    var config: PalbaseConfig? {
        lock.lock(); defer { lock.unlock() }
        return _config
    }

    var tokens: TokenManager? {
        lock.lock(); defer { lock.unlock() }
        return _tokens
    }

    var http: HTTPRequesting? {
        lock.lock(); defer { lock.unlock() }
        return _http
    }

    func set(config: PalbaseConfig, tokens: TokenManager, http: HTTPRequesting) {
        lock.lock(); defer { lock.unlock() }
        _config = config
        _tokens = tokens
        _http = http
    }
}
