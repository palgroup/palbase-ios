import Foundation

// MARK: - Path validation

enum DocsValidator {
    /// Each segment must match this pattern: letters, numbers, underscore, hyphen.
    /// Empty segments, `.` and `..` are rejected.
    static let segmentPattern = "^[a-zA-Z0-9_\\-]+$"

    static func validatePath(_ path: String) throws(DocsError) {
        guard !path.isEmpty else {
            throw DocsError.invalidPath(path)
        }
        if path.contains("..") || path.contains("//") {
            throw DocsError.invalidPath(path)
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        for seg in segments {
            let s = String(seg)
            if s.isEmpty || s == "." || s == ".." {
                throw DocsError.invalidPath(path)
            }
            if !matches(s, pattern: segmentPattern) {
                throw DocsError.invalidPath(path)
            }
        }
    }

    static func validateCollectionPath(_ path: String) throws(DocsError) {
        try validatePath(path)
        let segments = path.split(separator: "/")
        if segments.count % 2 == 0 {
            throw DocsError.invalidPath(path)
        }
    }

    static func validateDocumentPath(_ path: String) throws(DocsError) {
        try validatePath(path)
        let segments = path.split(separator: "/")
        if segments.count % 2 != 0 {
            throw DocsError.invalidPath(path)
        }
    }

    static func validateFieldName(_ name: String) throws(DocsError) {
        if name.isEmpty {
            throw DocsError.invalidFieldName(name)
        }
        // Reject control-like characters; allow dot notation for nested fields.
        for ch in name where ch.isNewline || ch == "/" {
            throw DocsError.invalidFieldName(name)
        }
    }

    static func validateSegment(_ segment: String) throws(DocsError) {
        if !matches(segment, pattern: segmentPattern) {
            throw DocsError.invalidPath(segment)
        }
    }

    private static func matches(_ input: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(input.startIndex..., in: input)
        return regex.firstMatch(in: input, range: range) != nil
    }
}

// MARK: - JSON value

/// A JSON value usable in query values, cursors, update maps, and arbitrary data payloads.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public static func from(_ value: Any?) -> JSONValue {
        guard let value = value else { return .null }
        switch value {
        case let v as JSONValue: return v
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(Int64(v))
        case let v as Int64: return .int(v)
        case let v as Int32: return .int(Int64(v))
        case let v as Double: return .double(v)
        case let v as Float: return .double(Double(v))
        case let v as UUID: return .string(v.uuidString.lowercased())
        case let v as Date:
            let fmt = ISO8601DateFormatter()
            return .string(fmt.string(from: v))
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

// MARK: - Type-erased Encodable

/// Wraps any `Encodable & Sendable` so builders can hold one in Sendable state.
package struct AnyEncodable: Encodable, Sendable {
    private let _encode: @Sendable (Encoder) throws -> Void

    package init<T: Encodable & Sendable>(_ value: T) {
        self._encode = { encoder in try value.encode(to: encoder) }
    }

    package func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

// MARK: - Raw JSON

/// Wraps pre-encoded JSON bytes as a drop-in `Encodable` payload.
struct RawJSON: Encodable, Sendable {
    let data: Data

    init(_ data: Data) { self.data = data }

    func encode(to encoder: Encoder) throws {
        // Decode the bytes into a JSONValue and re-encode — the simplest way
        // to thread arbitrary JSON through an Encoder without reaching into
        // the underlying output buffer.
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        try value.encode(to: encoder)
    }
}

// MARK: - Wire DTOs

struct DocumentDTO: Decodable, Sendable {
    let id: String
    let path: String
    let collection: String
    let documentId: String
    let data: JSONValue
    let metadata: JSONValue?
    let version: Int64
    let createdAt: String
    let updatedAt: String
}

struct QueryResponseDTO: Decodable, Sendable {
    let documents: [DocumentDTO]
    let count: Int
}

struct CollectionListResponseDTO: Decodable, Sendable {
    let documents: [DocumentDTO]
    let count: Int
}

struct ListCollectionIdsResponseDTO: Decodable, Sendable {
    let collections: [String]
}

struct AggregateResponseDTO: Decodable, Sendable {
    let results: [String: JSONValue]
}

struct BatchWriteResultDTO: Decodable, Sendable {
    let path: String
    let op: String
    let success: Bool
}

struct BatchWriteResponseDTO: Decodable, Sendable {
    let results: [BatchWriteResultDTO]
}

struct BatchGetResultDTO: Decodable, Sendable {
    let path: String
    let found: Bool
    let document: DocumentDTO?
}

struct BatchGetResponseDTO: Decodable, Sendable {
    let results: [BatchGetResultDTO]
}

struct TransactionBeginResponseDTO: Decodable, Sendable {
    let transactionId: String
}

struct SubscribeResponseDTO: Decodable, Sendable {
    let subscriptionId: String
    let documents: [DocumentDTO]?
    let count: Int?
    let streamUrl: String
    let expiresAt: String?
}

struct SSEEventDTO: Decodable, Sendable {
    let type: String
    let path: String?
    let document: JSONValue?
}

// MARK: - Request bodies

struct BatchWriteRequestBody: Encodable, Sendable {
    let operations: [BatchOperationDTO]
}

struct BatchOperationDTO: Encodable, Sendable {
    let op: String
    let path: String
    let data: JSONValue?
    let transforms: [FieldTransformDTO]?

    enum CodingKeys: String, CodingKey {
        case op, path, data, transforms
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(op, forKey: .op)
        try c.encode(path, forKey: .path)
        if let data = data { try c.encode(data, forKey: .data) }
        if let transforms = transforms, !transforms.isEmpty {
            try c.encode(transforms, forKey: .transforms)
        }
    }
}

struct FieldTransformDTO: Encodable, Sendable {
    let field: String
    let type: String
    let value: JSONValue?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(field, forKey: .field)
        try c.encode(type, forKey: .type)
        if let value = value { try c.encode(value, forKey: .value) }
    }

    enum CodingKeys: String, CodingKey { case field, type, value }
}

struct BatchGetRequestBody: Encodable, Sendable {
    let paths: [String]
}

struct TransformRequestBody: Encodable, Sendable {
    let transforms: [FieldTransformDTO]
}

struct QueryRequestBody: Encodable, Sendable {
    let `where`: JSONValue?
    let orderBy: [OrderBySpec]?
    let limit: Int?
    let select: [String]?
    let startAt: [JSONValue]?
    let startAfter: [JSONValue]?
    let endAt: [JSONValue]?
    let endBefore: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case `where`, orderBy, limit, select, startAt, startAfter, endAt, endBefore
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let w = `where` { try c.encode(w, forKey: .where) }
        if let ob = orderBy, !ob.isEmpty { try c.encode(ob, forKey: .orderBy) }
        if let l = limit { try c.encode(l, forKey: .limit) }
        if let s = select, !s.isEmpty { try c.encode(s, forKey: .select) }
        if let v = startAt, !v.isEmpty { try c.encode(v, forKey: .startAt) }
        if let v = startAfter, !v.isEmpty { try c.encode(v, forKey: .startAfter) }
        if let v = endAt, !v.isEmpty { try c.encode(v, forKey: .endAt) }
        if let v = endBefore, !v.isEmpty { try c.encode(v, forKey: .endBefore) }
    }
}

struct AggregateRequestBody: Encodable, Sendable {
    let `where`: JSONValue?
    let aggregations: [AggregationSpec]

    enum CodingKeys: String, CodingKey { case `where`, aggregations }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let w = `where` { try c.encode(w, forKey: .where) }
        try c.encode(aggregations, forKey: .aggregations)
    }
}

struct AggregationSpec: Encodable, Sendable {
    let alias: String
    let op: String
    let field: String?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(alias, forKey: .alias)
        try c.encode(op, forKey: .op)
        if let f = field { try c.encode(f, forKey: .field) }
    }

    enum CodingKeys: String, CodingKey { case alias, op, field }
}

struct OrderBySpec: Encodable, Sendable {
    let field: String
    let direction: String
}

// MARK: - Transaction DTOs

struct TransactionGetRequestBody: Encodable, Sendable {
    let transactionId: String
    let path: String
}

struct TransactionQueryRequestBody: Encodable, Sendable {
    let transactionId: String
    let collection: String
    let `where`: JSONValue?
    let orderBy: [OrderBySpec]?
    let limit: Int?
    let select: [String]?

    enum CodingKeys: String, CodingKey {
        case transactionId, collection, `where`, orderBy, limit, select
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transactionId, forKey: .transactionId)
        try c.encode(collection, forKey: .collection)
        if let w = `where` { try c.encode(w, forKey: .where) }
        if let ob = orderBy, !ob.isEmpty { try c.encode(ob, forKey: .orderBy) }
        if let l = limit { try c.encode(l, forKey: .limit) }
        if let s = select, !s.isEmpty { try c.encode(s, forKey: .select) }
    }
}

struct TransactionCommitRequestBody: Encodable, Sendable {
    let transactionId: String
    let operations: [BatchOperationDTO]
}

struct TransactionRollbackRequestBody: Encodable, Sendable {
    let transactionId: String
}
