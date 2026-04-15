import Foundation

// MARK: - Public enums

/// Lifecycle status of a `RealtimeChannel`.
public enum ChannelStatus: String, Sendable, Equatable {
    case idle
    case subscribing
    case subscribed
    case unsubscribing
    case closed
}

/// Presence event filter for `onPresence`.
public enum PresenceEvent: String, Sendable, Equatable {
    case sync
    case join
    case leave
}

/// Postgres change event filter for `onPostgresChanges`.
public enum PostgresEvent: String, Sendable, Equatable {
    case insert = "INSERT"
    case update = "UPDATE"
    case delete = "DELETE"
    case all = "*"
}

// MARK: - JSONValue

/// A JSON-encodable value used in realtime payloads.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// Build from a common Swift value (`String`, `Int`, `Bool`, `Double`,
    /// `[Any?]`, `[String: Any?]`, `nil`, etc).
    public static func from(_ value: Any?) -> JSONValue {
        guard let value = value else { return .null }
        switch value {
        case let v as JSONValue: return v
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(Int64(v))
        case let v as Int64: return .int(v)
        case let v as Double: return .double(v)
        case let v as Float: return .double(Double(v))
        case let v as UUID: return .string(v.uuidString.lowercased())
        case let v as [Any?]: return .array(v.map { JSONValue.from($0) })
        case let v as [String: Any?]:
            var out: [String: JSONValue] = [:]
            for (k, val) in v { out[k] = .from(val) }
            return .object(out)
        default:
            return .string(String(describing: value))
        }
    }
}

extension JSONValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }
}

// MARK: - Public payloads

/// Payload delivered to an `onBroadcast` callback.
public struct BroadcastPayload: Sendable, Equatable {
    public let event: String
    public let data: [String: JSONValue]

    package init(event: String, data: [String: JSONValue]) {
        self.event = event
        self.data = data
    }
}

/// A single member tracked via presence.
public struct PresenceMember: Sendable, Equatable {
    public let presenceRef: String
    public let payload: [String: JSONValue]

    package init(presenceRef: String, payload: [String: JSONValue]) {
        self.presenceRef = presenceRef
        self.payload = payload
    }
}

/// Payload delivered to an `onPresence` callback.
public struct PresencePayload: Sendable, Equatable {
    public let event: PresenceEvent
    public let state: [String: [PresenceMember]]
    public let joins: [String: [PresenceMember]]?
    public let leaves: [String: [PresenceMember]]?

    package init(
        event: PresenceEvent,
        state: [String: [PresenceMember]],
        joins: [String: [PresenceMember]]? = nil,
        leaves: [String: [PresenceMember]]? = nil
    ) {
        self.event = event
        self.state = state
        self.joins = joins
        self.leaves = leaves
    }
}

/// Payload delivered to an `onPostgresChanges` callback.
public struct PostgresChangePayload: Sendable, Equatable {
    public let event: PostgresEvent
    public let schema: String
    public let table: String
    public let new: [String: JSONValue]?
    public let old: [String: JSONValue]?
    public let timestamp: String

    package init(
        event: PostgresEvent,
        schema: String,
        table: String,
        new: [String: JSONValue]?,
        old: [String: JSONValue]?,
        timestamp: String
    ) {
        self.event = event
        self.schema = schema
        self.table = table
        self.new = new
        self.old = old
        self.timestamp = timestamp
    }
}
