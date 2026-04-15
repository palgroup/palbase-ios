import Foundation

/// Type-safe representation of a feature flag value. Matches JSON primitives
/// plus arrays and objects.
///
/// ```swift
/// let v: FlagValue = true          // .bool(true)
/// let n: FlagValue = 42            // .int(42)
/// let d: FlagValue = 9.5           // .double(9.5)
/// let s: FlagValue = "on"          // .string("on")
/// let a: FlagValue = [1, 2, 3]     // .array
/// let o: FlagValue = ["k": 1]      // .object
/// ```
public enum FlagValue: Sendable, Codable, Hashable {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case object([String: FlagValue])
    case array([FlagValue])
    case null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let i = try? c.decode(Int64.self) {
            self = .int(i)
            return
        }
        if let d = try? c.decode(Double.self) {
            self = .double(d)
            return
        }
        if let s = try? c.decode(String.self) {
            self = .string(s)
            return
        }
        if let a = try? c.decode([FlagValue].self) {
            self = .array(a)
            return
        }
        if let o = try? c.decode([String: FlagValue].self) {
            self = .object(o)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unsupported FlagValue payload"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

// MARK: - Literal convenience

extension FlagValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension FlagValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self = .int(value)
    }
}

extension FlagValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension FlagValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension FlagValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension FlagValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: FlagValue...) {
        self = .array(elements)
    }
}

extension FlagValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, FlagValue)...) {
        var dict: [String: FlagValue] = [:]
        dict.reserveCapacity(elements.count)
        for (k, v) in elements { dict[k] = v }
        self = .object(dict)
    }
}

// MARK: - Typed accessors

extension FlagValue {
    /// Unwrap as `Bool`, returning `nil` on mismatch.
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Unwrap as `Int`, returning `nil` on mismatch. `.double` values are
    /// truncated; `.int` is returned as-is.
    public var intValue: Int? {
        switch self {
        case .int(let i): return Int(i)
        case .double(let d):
            guard d.isFinite, d >= Double(Int.min), d <= Double(Int.max) else { return nil }
            return Int(d)
        default: return nil
        }
    }

    /// Unwrap as `Double`, returning `nil` on mismatch. Integer values are
    /// widened to `Double`.
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    /// Unwrap as `String`, returning `nil` on mismatch.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Unwrap as an object map, returning `nil` on mismatch.
    public var objectValue: [String: FlagValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Unwrap as a heterogeneous array, returning `nil` on mismatch.
    public var arrayValue: [FlagValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// `true` iff the value is `.null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
