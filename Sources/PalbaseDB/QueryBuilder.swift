import Foundation
@_exported import PalbaseCore

/// Chainable query/mutation builder. Call `.execute()` to run it.
public struct QueryBuilder<T: Decodable & Encodable & Sendable>: Sendable {
    // MARK: - State

    let http: HTTPRequesting
    let basePath: String
    let table: String

    private var method: String = "GET"
    private var body: AnyEncodable?
    private var extraHeaders: [String: String] = [:]
    private var filters: [String] = []
    private var params: [(String, String)] = []  // preserve order
    private var isSingle = false
    private var isMaybeSingle = false

    // MARK: - Init

    package init(http: HTTPRequesting, table: String, basePath: String) {
        self.http = http
        self.table = table
        self.basePath = basePath
    }

    // MARK: - Selection

    public func select(_ columns: String = "*") -> QueryBuilder {
        var copy = self
        copy.upsertParam("select", columns)
        return copy
    }

    // MARK: - Filters

    public func eq(_ column: String, _ value: any Sendable) throws(DBError) -> QueryBuilder {
        try addFilter(column, op: "eq", value: value)
    }
    public func neq(_ column: String, _ value: any Sendable) throws(DBError) -> QueryBuilder {
        try addFilter(column, op: "neq", value: value)
    }
    public func gt(_ column: String, _ value: any Sendable) throws(DBError) -> QueryBuilder {
        try addFilter(column, op: "gt", value: value)
    }
    public func gte(_ column: String, _ value: any Sendable) throws(DBError) -> QueryBuilder {
        try addFilter(column, op: "gte", value: value)
    }
    public func lt(_ column: String, _ value: any Sendable) throws(DBError) -> QueryBuilder {
        try addFilter(column, op: "lt", value: value)
    }
    public func lte(_ column: String, _ value: any Sendable) throws(DBError) -> QueryBuilder {
        try addFilter(column, op: "lte", value: value)
    }
    public func like(_ column: String, _ pattern: String) throws(DBError) -> QueryBuilder {
        try addFilter(column, op: "like", value: pattern)
    }
    public func ilike(_ column: String, _ pattern: String) throws(DBError) -> QueryBuilder {
        try addFilter(column, op: "ilike", value: pattern)
    }

    public func in_(_ column: String, values: [any Sendable]) throws(DBError) -> QueryBuilder {
        try DBValidator.validateColumn(column)
        let list = values.map { FilterEncoder.encodeForList($0) }.joined(separator: ",")
        var copy = self
        copy.filters.append("\(column)=in.(\(list))")
        return copy
    }

    public func is_(_ column: String, _ value: any Sendable) throws(DBError) -> QueryBuilder {
        try addFilter(column, op: "is", value: value)
    }

    // MARK: - Modifiers

    public func order(_ column: String, ascending: Bool = true) throws(DBError) -> QueryBuilder {
        try DBValidator.validateColumn(column)
        var copy = self
        copy.upsertParam("order", "\(column).\(ascending ? "asc" : "desc")")
        return copy
    }

    public func limit(_ count: Int) -> QueryBuilder {
        var copy = self
        copy.upsertParam("limit", String(count))
        return copy
    }

    public func range(from: Int, to: Int) -> QueryBuilder {
        var copy = self
        copy.extraHeaders["Range"] = "\(from)-\(to)"
        return copy
    }

    // MARK: - Mutations

    public func insert<E: Encodable & Sendable>(_ values: E) -> QueryBuilder {
        var copy = self
        copy.method = "POST"
        copy.body = AnyEncodable(values)
        copy.extraHeaders["Prefer"] = "return=representation"
        return copy
    }

    public func update<E: Encodable & Sendable>(_ values: E) -> QueryBuilder {
        var copy = self
        copy.method = "PATCH"
        copy.body = AnyEncodable(values)
        copy.extraHeaders["Prefer"] = "return=representation"
        return copy
    }

    public func upsert<E: Encodable & Sendable>(_ values: E) -> QueryBuilder {
        var copy = self
        copy.method = "POST"
        copy.body = AnyEncodable(values)
        copy.extraHeaders["Prefer"] = "resolution=merge-duplicates,return=representation"
        return copy
    }

    public func delete() -> QueryBuilder {
        var copy = self
        copy.method = "DELETE"
        return copy
    }

    // MARK: - Single-row variants

    public func single() -> SingleQueryBuilder<T> {
        var copy = self
        copy.isSingle = true
        copy.extraHeaders["Accept"] = "application/vnd.pgrst.object+json"
        return SingleQueryBuilder(inner: copy)
    }

    public func maybeSingle() -> MaybeSingleQueryBuilder<T> {
        var copy = self
        copy.isMaybeSingle = true
        copy.extraHeaders["Accept"] = "application/vnd.pgrst.object+json"
        return MaybeSingleQueryBuilder(inner: copy)
    }

    // MARK: - Execute

    /// Execute the request and decode the response as `[T]`.
    public func execute() async throws(DBError) -> [T] {
        let path = buildPath()
        let raw: (data: Data, status: Int)
        do {
            raw = try await http.requestRaw(method: method, path: path, body: body, headers: extraHeaders)
        } catch {
            throw DBError.from(transport: error)
        }
        if raw.data.isEmpty { return [] }
        return try decodeArray(from: raw.data)
    }

    // MARK: - Internal helpers

    package var currentMethod: String { method }
    package var currentBody: AnyEncodable? { body }
    package var currentHeaders: [String: String] { extraHeaders }
    package var currentFilters: [String] { filters }
    package var currentParams: [(String, String)] { params }

    package func buildPath() -> String {
        var parts: [String] = []
        for (k, v) in params { parts.append("\(k)=\(v)") }
        for f in filters { parts.append(f) }
        if parts.isEmpty { return basePath }
        return "\(basePath)?\(parts.joined(separator: "&"))"
    }

    private mutating func upsertParam(_ key: String, _ value: String) {
        if let idx = params.firstIndex(where: { $0.0 == key }) {
            params[idx] = (key, value)
        } else {
            params.append((key, value))
        }
    }

    private func addFilter(_ column: String, op: String, value: any Sendable) throws(DBError) -> QueryBuilder {
        try DBValidator.validateColumn(column)
        var copy = self
        copy.filters.append("\(column)=\(op).\(FilterEncoder.encode(value))")
        return copy
    }

    private func decodeArray(from data: Data) throws(DBError) -> [T] {
        do {
            // Try array first; fall back to single object for PostgREST endpoints
            // that sometimes return a single row for mutations without an array.
            if let first = data.first, first == UInt8(ascii: "[") {
                return try JSONDecoder.palbaseDefault.decode([T].self, from: data)
            }
            let one = try JSONDecoder.palbaseDefault.decode(T.self, from: data)
            return [one]
        } catch {
            throw DBError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - Single / MaybeSingle variants

/// Returned by `.single()` — `execute()` yields exactly one row.
public struct SingleQueryBuilder<T: Decodable & Encodable & Sendable>: Sendable {
    let inner: QueryBuilder<T>

    package init(inner: QueryBuilder<T>) { self.inner = inner }

    public func execute() async throws(DBError) -> T {
        let path = inner.buildPath()
        let raw: (data: Data, status: Int)
        do {
            raw = try await inner.http.requestRaw(
                method: inner.currentMethod,
                path: path,
                body: inner.currentBody,
                headers: inner.currentHeaders
            )
        } catch {
            throw DBError.from(transport: error)
        }
        return try decode(from: raw.data)
    }

    private func decode(from data: Data) throws(DBError) -> T {
        do {
            return try JSONDecoder.palbaseDefault.decode(T.self, from: data)
        } catch {
            throw DBError.decoding(error.localizedDescription)
        }
    }
}

/// Returned by `.maybeSingle()` — `execute()` yields an optional row.
public struct MaybeSingleQueryBuilder<T: Decodable & Encodable & Sendable>: Sendable {
    let inner: QueryBuilder<T>

    package init(inner: QueryBuilder<T>) { self.inner = inner }

    public func execute() async throws(DBError) -> T? {
        let path = inner.buildPath()
        let raw: (data: Data, status: Int)
        do {
            raw = try await inner.http.requestRaw(
                method: inner.currentMethod,
                path: path,
                body: inner.currentBody,
                headers: inner.currentHeaders
            )
        } catch {
            // PostgREST returns 406 when a single-row query has 0 rows.
            if case .http(let status, _, _, _) = error, status == 406 {
                return nil
            }
            throw DBError.from(transport: error)
        }
        if raw.data.isEmpty { return nil }
        return try decode(from: raw.data)
    }

    private func decode(from data: Data) throws(DBError) -> T? {
        do {
            return try JSONDecoder.palbaseDefault.decode(T.self, from: data)
        } catch {
            throw DBError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - Type-erased Encodable wrapper

/// Type-erases any `Encodable & Sendable` so it can be stored in the builder
/// state (which must itself be `Sendable`).
package struct AnyEncodable: Encodable, Sendable {
    private let _encode: @Sendable (Encoder) throws -> Void

    package init<T: Encodable & Sendable>(_ value: T) {
        self._encode = { encoder in
            try value.encode(to: encoder)
        }
    }

    package func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
