import Foundation

// MARK: - Validation

enum DBValidator {
    static func validateTable(_ name: String) throws(DBError) {
        if !matches(name, pattern: "^[A-Za-z_][A-Za-z0-9_.]*$") {
            throw DBError.invalidTable(name)
        }
    }

    static func validateColumn(_ name: String) throws(DBError) {
        // Columns may contain PostgREST JSON path operators: . : - > #
        if !matches(name, pattern: "^[A-Za-z_][A-Za-z0-9_.:\\->#]*$") {
            throw DBError.invalidColumn(name)
        }
    }

    static func validateFunctionName(_ name: String) throws(DBError) {
        if !matches(name, pattern: "^[A-Za-z_][A-Za-z0-9_.]*$") {
            throw DBError.invalidFunctionName(name)
        }
    }

    static func validateTransactionId(_ id: String) throws(DBError) {
        if !matches(id, pattern: "^[A-Za-z0-9_\\-]+$") {
            throw DBError.invalidTransactionId(id)
        }
    }

    private static func matches(_ input: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(input.startIndex..., in: input)
        return regex.firstMatch(in: input, range: range) != nil
    }
}

// MARK: - Filter value encoding

enum FilterEncoder {
    /// Convert a value to its PostgREST string representation.
    static func encode(_ value: any Sendable) -> String {
        let raw: String
        switch value {
        case let s as String: raw = s
        case let b as Bool: raw = b ? "true" : "false"
        case let i as Int: raw = String(i)
        case let i as Int64: raw = String(i)
        case let d as Double: raw = String(d)
        case let f as Float: raw = String(f)
        case let u as UUID: raw = u.uuidString.lowercased()
        case Optional<Any>.none: raw = "null"
        default: raw = String(describing: value)
        }
        return percentEncode(raw, extra: "&#")
    }

    /// Encode a value for use inside an `in.(...)` list — additionally escapes
    /// `,` and `)` which are list delimiters.
    static func encodeForList(_ value: any Sendable) -> String {
        let basic = encode(value)
        var result = ""
        for char in basic {
            if char == "," || char == ")" {
                result.append(char.asciiValue.map { String(format: "%%%02X", $0) } ?? String(char))
            } else {
                result.append(char)
            }
        }
        return result
    }

    /// Percent-encode only the characters in `extra`; leaves already-encoded
    /// sequences alone (matches TS behaviour).
    private static func percentEncode(_ input: String, extra: String) -> String {
        let set = Set(extra)
        var out = ""
        out.reserveCapacity(input.count)
        for ch in input {
            if set.contains(ch), let ascii = ch.asciiValue {
                out.append(String(format: "%%%02X", ascii))
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

// MARK: - JSON value (encoding-friendly wrapper)

/// A JSON-encodable value. Used by `rpc` params and by `JSONObject`-style inputs
/// when callers don't want to define a dedicated `Encodable` struct.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// Helper for building from common Swift values.
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

// MARK: - DTOs

struct TransactionBeginResponse: Decodable, Sendable {
    let txId: String
}

struct RPCBody<Params: Encodable & Sendable>: Encodable, Sendable {
    let params: Params?

    func encode(to encoder: Encoder) throws {
        if let params = params {
            try params.encode(to: encoder)
        } else {
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        }
    }
}
