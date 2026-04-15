import Foundation

/// Type-safe analytics property value. Matches JSON primitives + arrays/objects.
///
/// Use literal syntax for convenience:
/// ```swift
/// let props: [String: AnalyticsValue] = [
///     "amount": 99.99,
///     "currency": "USD",
///     "count": 2,
///     "premium": true,
///     "items": ["a", "b"],
///     "meta": ["source": "email"]
/// ]
/// ```
public enum AnalyticsValue: Sendable, Codable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnalyticsValue])
    case object([String: AnalyticsValue])

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
        if let i = try? c.decode(Int.self) {
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
        if let a = try? c.decode([AnalyticsValue].self) {
            self = .array(a)
            return
        }
        if let o = try? c.decode([String: AnalyticsValue].self) {
            self = .object(o)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unsupported AnalyticsValue payload"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Literal convenience

extension AnalyticsValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension AnalyticsValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension AnalyticsValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension AnalyticsValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension AnalyticsValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension AnalyticsValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: AnalyticsValue...) {
        self = .array(elements)
    }
}

extension AnalyticsValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, AnalyticsValue)...) {
        var dict: [String: AnalyticsValue] = [:]
        dict.reserveCapacity(elements.count)
        for (k, v) in elements { dict[k] = v }
        self = .object(dict)
    }
}
