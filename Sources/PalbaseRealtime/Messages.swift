import Foundation

// MARK: - Phoenix wire envelope

/// Generic Phoenix envelope: `{topic, event, payload, ref}`.
package struct PhoenixEnvelope: Sendable {
    package let topic: String
    package let event: String
    package let payload: [String: JSONValue]
    package let ref: String?

    package init(topic: String, event: String, payload: [String: JSONValue], ref: String?) {
        self.topic = topic
        self.event = event
        self.payload = payload
        self.ref = ref
    }
}

// MARK: - Encoder/decoder configured for raw Phoenix wire format
//
// Phoenix uses snake_case keys (`presence_state`, `postgres_changes`) and field
// names that don't follow Swift conventions (`apikey`). We do NOT use
// `JSONDecoder.palbaseDefault` (which would convert to camelCase) — instead we
// keep keys verbatim and parse via `[String: JSONValue]`.

enum PhoenixCodec {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    /// Encode an outgoing envelope as JSON `Data`.
    static func encode(_ env: PhoenixEnvelope) throws(RealtimeError) -> Data {
        var obj: [String: JSONValue] = [
            "topic": .string(env.topic),
            "event": .string(env.event),
            "payload": .object(env.payload)
        ]
        if let ref = env.ref { obj["ref"] = .string(ref) }
        do {
            return try encoder.encode(obj)
        } catch {
            throw RealtimeError.messageEncodingFailed(message: error.localizedDescription)
        }
    }

    /// Decode an incoming envelope from `Data`.
    static func decode(_ data: Data) throws(RealtimeError) -> PhoenixEnvelope {
        let raw: [String: JSONValue]
        do {
            raw = try decoder.decode([String: JSONValue].self, from: data)
        } catch {
            throw RealtimeError.messageDecodingFailed(message: error.localizedDescription)
        }
        guard case .string(let topic) = raw["topic"] ?? .null else {
            throw RealtimeError.messageDecodingFailed(message: "missing topic")
        }
        guard case .string(let event) = raw["event"] ?? .null else {
            throw RealtimeError.messageDecodingFailed(message: "missing event")
        }
        let payload: [String: JSONValue]
        if case .object(let p) = raw["payload"] ?? .object([:]) {
            payload = p
        } else {
            payload = [:]
        }
        var ref: String? = nil
        if case .string(let r) = raw["ref"] ?? .null { ref = r }
        return PhoenixEnvelope(topic: topic, event: event, payload: payload, ref: ref)
    }
}

// MARK: - Outgoing message builders

enum PhoenixMessageBuilder {
    /// Build the `phx_join` payload for a channel, including credentials and
    /// listener config.
    static func joinPayload(
        apiKey: String,
        accessToken: String?,
        broadcastEvents: [String],
        presenceEnabled: Bool,
        postgresChanges: [PostgresChangeBinding]
    ) -> [String: JSONValue] {
        // Broadcast config: list of events the client wants to receive.
        let broadcastEventsValue: [JSONValue] = broadcastEvents.map { .string($0) }
        let broadcastConfig: [String: JSONValue] = [
            "self": .bool(false),
            "ack": .bool(false),
            "events": .array(broadcastEventsValue)
        ]

        let presenceConfig: [String: JSONValue] = [
            "enabled": .bool(presenceEnabled),
            "key": .string("")
        ]

        let pgChangesArr: [JSONValue] = postgresChanges.map { binding in
            .object([
                "event": .string(binding.event.rawValue),
                "schema": .string(binding.schema),
                "table": .string(binding.table),
                "filter": binding.filter.map(JSONValue.string) ?? .string("")
            ])
        }

        let config: [String: JSONValue] = [
            "broadcast": .object(broadcastConfig),
            "presence": .object(presenceConfig),
            "postgres_changes": .array(pgChangesArr)
        ]

        var payload: [String: JSONValue] = [
            "apikey": .string(apiKey),
            "config": .object(config)
        ]
        if let token = accessToken {
            payload["token"] = .string(token)
            payload["access_token"] = .string(token)
        }
        return payload
    }

    /// Build a broadcast outgoing payload.
    static func broadcastPayload(event: String, data: [String: JSONValue]) -> [String: JSONValue] {
        return [
            "type": .string("broadcast"),
            "event": .string(event),
            "payload": .object(data)
        ]
    }

    /// Build a presence track payload.
    static func presenceTrackPayload(state: [String: JSONValue]) -> [String: JSONValue] {
        return [
            "type": .string("presence"),
            "event": .string("track"),
            "payload": .object(state)
        ]
    }

    /// Build a presence untrack payload.
    static func presenceUntrackPayload() -> [String: JSONValue] {
        return [
            "type": .string("presence"),
            "event": .string("untrack")
        ]
    }
}

/// Internal binding descriptor for postgres_changes (used in phx_join config).
struct PostgresChangeBinding: Sendable, Equatable {
    let event: PostgresEvent
    let schema: String
    let table: String
    let filter: String?
}

// MARK: - Helpers for converting JSONValue → public payloads

extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Coerce arbitrary `Sendable` values (passed by callers via
    /// `[String: any Sendable]`) into a `JSONValue` map.
    static func dict(from any: [String: any Sendable]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (k, v) in any { out[k] = JSONValue.from(v) }
        return out
    }
}

/// Decode a presence state map from a Phoenix `presence_state` payload.
///
/// Wire format:
/// ```json
/// {
///   "<key>": {
///     "metas": [
///       { "phx_ref": "...", ...userPayload }
///     ]
///   }
/// }
/// ```
enum PresenceDecoder {
    static func decodeState(_ payload: [String: JSONValue]) -> [String: [PresenceMember]] {
        var result: [String: [PresenceMember]] = [:]
        for (key, value) in payload {
            guard case .object(let entry) = value else { continue }
            // Two formats: { metas: [...] } or directly an array of members.
            var members: [PresenceMember] = []
            if case .array(let metas) = entry["metas"] ?? .null {
                members = metas.compactMap { decodeMember($0) }
            } else if case .array(let arr) = value {
                members = arr.compactMap { decodeMember($0) }
            } else {
                if let m = decodeMember(.object(entry)) { members = [m] }
            }
            result[key] = members
        }
        return result
    }

    static func decodeMember(_ value: JSONValue) -> PresenceMember? {
        guard case .object(var dict) = value else { return nil }
        let ref: String
        if case .string(let r) = dict.removeValue(forKey: "phx_ref") ?? .null {
            ref = r
        } else if case .string(let r) = dict.removeValue(forKey: "presence_ref") ?? .null {
            ref = r
        } else {
            ref = ""
        }
        return PresenceMember(presenceRef: ref, payload: dict)
    }
}
