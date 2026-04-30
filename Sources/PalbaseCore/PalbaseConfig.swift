import Foundation

/// Which Palbase environment the SDK should talk to.
///
/// Apps deployed against the production cluster use `.prod` (the
/// default — `<ref>.palbase.studio`). Internal builds and developer
/// previews target the dev cluster via `.dev`
/// (`<ref>.dev.palbase.studio`). The mapping is identical to the
/// `palbase` CLI's `--mode` flag, so a key minted in dev keeps working
/// when you bring it into Xcode by toggling one parameter.
///
/// Tests + custom deployments can still override `PalbaseConfig.url`
/// directly; that wins over `mode`.
public enum PalbaseMode: String, Sendable {
    case prod
    case dev

    /// Public domain suffix the SDK appends to the API key's project
    /// ref when building the base URL.
    public var domain: String {
        switch self {
        case .prod: return "palbase.studio"
        case .dev:  return "dev.palbase.studio"
        }
    }
}

/// Configuration for the SDK. Apps usually call
/// `Palbase.configure(apiKey:)` (or `.configure(apiKey:mode:)` for dev
/// builds) — only use this struct directly when you need to override
/// transport behavior (custom URL, timeouts, custom URLSession for
/// testing).
public struct PalbaseConfig: Sendable {
    /// API key in `pb_{ref}_{random}` format.
    public let apiKey: String

    /// Override the base URL. Defaults to `https://{ref}.{mode.domain}`
    /// derived from the API key. Setting this wins over `mode`.
    public let url: String?

    /// Override the URL `PalbaseBackend` (typed RPC + /openapi.json)
    /// targets. When `nil`, backend calls go through `url` like every
    /// other module. Set this to point at a local `palbase backend dev`
    /// server (`http://localhost:4000`) without changing where
    /// auth/db/docs/storage talk to.
    public let backendURL: String?

    /// Environment to target. `.prod` by default; `.dev` swaps the
    /// domain to `*.dev.palbase.studio`. Ignored when `url` is set.
    public let mode: PalbaseMode

    /// Service role key (server-only). When set, used instead of the user's access token.
    public let serviceRoleKey: String?

    /// Custom headers added to every request.
    public let headers: [String: String]

    /// URLSession for HTTP. Override for testing or background uploads.
    public let urlSession: URLSession

    /// Request timeout in seconds. Default 30.
    public let requestTimeout: TimeInterval

    /// Number of retry attempts for network/429 errors. Default 3.
    public let maxRetries: Int

    /// Initial backoff (ms) between retries. Doubles each attempt. Default 200.
    public let initialBackoffMs: UInt64

    public init(
        apiKey: String,
        url: String? = nil,
        backendURL: String? = nil,
        mode: PalbaseMode = .prod,
        serviceRoleKey: String? = nil,
        headers: [String: String] = [:],
        urlSession: URLSession = .shared,
        requestTimeout: TimeInterval = 30,
        maxRetries: Int = 3,
        initialBackoffMs: UInt64 = 200
    ) {
        self.apiKey = apiKey
        self.url = url
        self.backendURL = backendURL
        self.mode = mode
        self.serviceRoleKey = serviceRoleKey
        self.headers = headers
        self.urlSession = urlSession
        self.requestTimeout = requestTimeout
        self.maxRetries = maxRetries
        self.initialBackoffMs = initialBackoffMs
    }
}
