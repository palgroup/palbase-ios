import Foundation

/// Aggregation operation to apply during an aggregate query.
public enum Aggregate: Sendable {
    /// Count documents matching the filter. Use `.count(alias:)` to override the
    /// default alias `count`. Field is ignored by the server and reported as `*`.
    case count(alias: String = "count")
    case sum(field: String, alias: String? = nil)
    case avg(field: String, alias: String? = nil)
    case min(field: String, alias: String? = nil)
    case max(field: String, alias: String? = nil)

    var alias: String {
        switch self {
        case .count(let a): return a
        case .sum(let f, let a): return a ?? "sum_\(sanitize(f))"
        case .avg(let f, let a): return a ?? "avg_\(sanitize(f))"
        case .min(let f, let a): return a ?? "min_\(sanitize(f))"
        case .max(let f, let a): return a ?? "max_\(sanitize(f))"
        }
    }

    var op: String {
        switch self {
        case .count: return "count"
        case .sum: return "sum"
        case .avg: return "avg"
        case .min: return "min"
        case .max: return "max"
        }
    }

    var field: String? {
        switch self {
        case .count: return nil
        case .sum(let f, _), .avg(let f, _), .min(let f, _), .max(let f, _): return f
        }
    }

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: "_")
    }

    func toSpec() -> AggregationSpec {
        AggregationSpec(alias: alias, op: op, field: field)
    }
}

/// Result of an aggregation query — keyed by alias.
public struct AggregateResult: Sendable {
    public let values: [String: JSONValue]

    package init(values: [String: JSONValue]) {
        self.values = values
    }

    public func int(_ alias: String) -> Int64? {
        guard let v = values[alias] else { return nil }
        switch v {
        case .int(let n): return n
        case .double(let d): return Int64(d)
        default: return nil
        }
    }

    public func double(_ alias: String) -> Double? {
        guard let v = values[alias] else { return nil }
        switch v {
        case .int(let n): return Double(n)
        case .double(let d): return d
        default: return nil
        }
    }

    public subscript(alias: String) -> JSONValue? { values[alias] }
}
