import Foundation

/// Single global entry point for SDK configuration. Inspired by `FirebaseApp.configure()`.
///
/// Call once at app startup:
/// ```swift
/// PalbaseSDK.configure(apiKey: "pb_abc123_xxx")
///
/// // Anywhere else:
/// let auth = try PalbaseAuth.shared
/// try await auth.signIn(email: "...", password: "...")
/// ```
public enum PalbaseSDK {
    /// Internal shared state — all access goes through synchronized accessors.
    private static let state = State()

    /// Configure the SDK with a single API key. Most apps use this.
    public static func configure(apiKey: String) {
        configure(PalbaseConfig(apiKey: apiKey))
    }

    /// Configure with full options (custom URL, token storage, URLSession, etc.).
    public static func configure(_ config: PalbaseConfig) {
        let tokens = TokenManager(storage: config.tokenStorage)
        let http = HttpClient(config: config, tokens: tokens)
        state.set(config: config, tokens: tokens, http: http)

        // Hydrate session from storage in background
        Task { await tokens.loadFromStorage() }
    }

    /// Reset SDK state. Test-only.
    public static func reset() {
        state.reset()
    }

    /// The active configuration, if `configure(_:)` has been called.
    public static var config: PalbaseConfig? { state.config }

    /// The shared HTTP client. Throws `.notConfigured` if not configured.
    package static var http: HTTPRequesting? { state.http }

    /// The shared token manager. Throws `.notConfigured` if not configured.
    package static var tokens: TokenManager? { state.tokens }

    package static func requireHTTP() throws -> HTTPRequesting {
        guard let http = state.http else { throw PalbaseCoreError.notConfigured }
        return http
    }

    package static func requireTokens() throws -> TokenManager {
        guard let tokens = state.tokens else { throw PalbaseCoreError.notConfigured }
        return tokens
    }
}

/// Thread-safe container for SDK state. Uses NSLock for atomic mutation.
/// Reads are lock-free since references are atomic on Apple platforms; writes are locked.
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

    func reset() {
        lock.lock(); defer { lock.unlock() }
        _config = nil
        _tokens = nil
        _http = nil
    }
}
