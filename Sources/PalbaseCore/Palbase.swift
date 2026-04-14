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
    public static func configure(apiKey: String) {
        configure(PalbaseConfig(apiKey: apiKey))
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
