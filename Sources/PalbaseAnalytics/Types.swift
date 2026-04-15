import Foundation

// MARK: - Public-facing constants (internal — limits are implementation detail)

/// Server-enforced limits. Kept in sync with `modules/analytics` spec.
enum AnalyticsLimits {
    /// Maximum bytes a single event (JSON-encoded) may take up. Server rejects larger.
    static let maxEventBytes: Int = 32 * 1024
    /// Maximum bytes a batch body may take up.
    static let maxBatchBytes: Int = 3 * 1024 * 1024
    /// Maximum number of events in one batch.
    static let maxBatchEvents: Int = 100
    /// Maximum local queue size (FIFO — overflow drops oldest).
    static let maxQueueSize: Int = 1000
    /// Auto-flush interval.
    static let autoFlushInterval: TimeInterval = 10
    /// Queue size that triggers an immediate flush.
    static let autoFlushThreshold: Int = 50
    /// Session inactivity timeout.
    static let sessionInactivityTimeout: TimeInterval = 30 * 60
    /// Max session duration regardless of activity.
    static let sessionMaxDuration: TimeInterval = 24 * 60 * 60
    /// Retry backoff ceiling (seconds).
    static let maxBackoffSeconds: TimeInterval = 30
    /// Initial retry backoff (seconds).
    static let initialBackoffSeconds: TimeInterval = 1
}

// MARK: - Internal event type (queued, persisted, serialized)

/// An event as queued locally. Serialized to NDJSON when persisted to disk and
/// flattened into the wire format when sent.
package struct QueuedEvent: Codable, Sendable, Equatable {
    /// SDK-generated UUIDv7 for idempotency / debugging.
    package let eventId: String

    /// The event name. Built-ins use `$identify`, `$create_alias`, `$screen`,
    /// `$pageview`; all others come from user code.
    package let event: String

    /// Endpoint path (drives flush routing).
    package let endpoint: Endpoint

    /// Distinct ID at capture time.
    package let distinctId: String

    /// Capture-time properties (may be nil).
    package let properties: [String: AnalyticsValue]?

    /// Traits for $identify (optional).
    package let traits: [String: AnalyticsValue]?

    /// Alias-specific field.
    package let alias: AliasFields?

    /// Screen-specific field.
    package let screenName: String?

    /// Page-specific fields.
    package let pageURL: String?
    package let pageTitle: String?

    /// Client capture timestamp (unix ms).
    package let timestampMs: Int64

    /// Session id at capture time (nil for identify/alias, set for capture/screen/page).
    package let sessionId: String?

    /// App version snapshot.
    package let appVersion: String?

    package init(
        eventId: String,
        event: String,
        endpoint: Endpoint,
        distinctId: String,
        properties: [String: AnalyticsValue]?,
        traits: [String: AnalyticsValue]?,
        alias: AliasFields?,
        screenName: String?,
        pageURL: String?,
        pageTitle: String?,
        timestampMs: Int64,
        sessionId: String?,
        appVersion: String?
    ) {
        self.eventId = eventId
        self.event = event
        self.endpoint = endpoint
        self.distinctId = distinctId
        self.properties = properties
        self.traits = traits
        self.alias = alias
        self.screenName = screenName
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.timestampMs = timestampMs
        self.sessionId = sessionId
        self.appVersion = appVersion
    }

    package enum Endpoint: String, Codable, Sendable {
        case capture
        case identify
        case alias
        case screen
        case page
        case batch
    }

    package struct AliasFields: Codable, Sendable, Equatable {
        package let from: String
        package let to: String
        package init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }
}

// MARK: - Wire DTOs (what goes over the HTTP body)

/// Wire payload for `/v1/analytics/capture`.
struct CaptureRequestDTO: Encodable, Sendable {
    let event: String
    let distinctId: String
    let properties: [String: AnalyticsValue]?
    let timestamp: Int64
    let sentAt: Int64
    let sessionId: String?
    let appVersion: String?
}

struct IdentifyRequestDTO: Encodable, Sendable {
    let distinctId: String
    let traits: [String: AnalyticsValue]?
    let timestamp: Int64
    let sentAt: Int64
}

struct AliasRequestDTO: Encodable, Sendable {
    let from: String
    let to: String
    let timestamp: Int64
    let sentAt: Int64
}

struct ScreenRequestDTO: Encodable, Sendable {
    let screenName: String
    let distinctId: String
    let properties: [String: AnalyticsValue]?
    let timestamp: Int64
    let sentAt: Int64
    let sessionId: String?
}

struct PageRequestDTO: Encodable, Sendable {
    let url: String
    let title: String?
    let distinctId: String
    let properties: [String: AnalyticsValue]?
    let timestamp: Int64
    let sentAt: Int64
    let sessionId: String?
}

struct BatchRequestDTO: Encodable, Sendable {
    let events: [BatchEventDTO]
}

struct BatchEventDTO: Encodable, Sendable {
    let event: String
    let distinctId: String
    let properties: [String: AnalyticsValue]?
    let timestamp: Int64
    let sentAt: Int64
    let sessionId: String?
    let appVersion: String?
}

// MARK: - UUID helpers

/// Minimal UUIDv7 implementation — foundation only.
///
/// Layout:
///  - 48 bits unix ms timestamp
///  - 4 bits version (7)
///  - 12 bits random
///  - 2 bits variant (10)
///  - 62 bits random
enum UUIDv7 {
    static func string(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ms = UInt64(max(now.timeIntervalSince1970 * 1000, 0))
        bytes[0] = UInt8((ms >> 40) & 0xFF)
        bytes[1] = UInt8((ms >> 32) & 0xFF)
        bytes[2] = UInt8((ms >> 24) & 0xFF)
        bytes[3] = UInt8((ms >> 16) & 0xFF)
        bytes[4] = UInt8((ms >> 8) & 0xFF)
        bytes[5] = UInt8(ms & 0xFF)

        var rand = [UInt8](repeating: 0, count: 10)
        for i in 0..<rand.count { rand[i] = UInt8.random(in: 0...255) }
        bytes[6] = (rand[0] & 0x0F) | 0x70  // version 7
        bytes[7] = rand[1]
        bytes[8] = (rand[2] & 0x3F) | 0x80  // variant 10
        bytes[9] = rand[3]
        bytes[10] = rand[4]
        bytes[11] = rand[5]
        bytes[12] = rand[6]
        bytes[13] = rand[7]
        bytes[14] = rand[8]
        bytes[15] = rand[9]

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let chars = Array(hex)
        func slice(_ start: Int, _ end: Int) -> String {
            String(chars[start..<end])
        }
        return [
            slice(0, 8),
            slice(8, 12),
            slice(12, 16),
            slice(16, 20),
            slice(20, 32),
        ].joined(separator: "-")
    }
}
