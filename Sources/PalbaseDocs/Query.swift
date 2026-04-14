import Foundation

/// Filter operator. The Go backend expects the symbolic form (`==`, `<`, `in`,
/// `array-contains`, etc.).
public enum WhereOperator: Sendable, Equatable {
    case equalTo
    case notEqualTo
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
    case `in`
    case notIn
    case arrayContains
    case arrayContainsAny
    case isNull
    case isNotNull

    var wireOp: String {
        switch self {
        case .equalTo: return "=="
        case .notEqualTo: return "!="
        case .lessThan: return "<"
        case .lessThanOrEqual: return "<="
        case .greaterThan: return ">"
        case .greaterThanOrEqual: return ">="
        case .in: return "in"
        case .notIn: return "not-in"
        case .arrayContains: return "array-contains"
        case .arrayContainsAny: return "array-contains-any"
        case .isNull: return "is-null"
        case .isNotNull: return "is-not-null"
        }
    }
}

/// Chainable, immutable query. Call `.get()` to execute or `.onSnapshot(...)` to
/// subscribe to live updates.
public struct Query<T: Codable & Sendable>: Sendable {
    private let http: HTTPRequesting
    private let pathPrefix: String
    private let collectionPath: String
    private let isCollectionGroup: Bool

    private var wheres: [JSONValue] = []
    private var orders: [OrderBySpec] = []
    private var lim: Int?
    private var selectFields: [String]?
    private var startAt: [JSONValue]?
    private var startAfter: [JSONValue]?
    private var endAt: [JSONValue]?
    private var endBefore: [JSONValue]?

    // MARK: - Init

    package init(ref: CollectionRef<T>) {
        self.http = ref.http
        self.pathPrefix = ref.pathPrefix
        self.collectionPath = ref.path
        self.isCollectionGroup = false
    }

    package init(http: HTTPRequesting, pathPrefix: String, collectionPath: String, isCollectionGroup: Bool) {
        self.http = http
        self.pathPrefix = pathPrefix
        self.collectionPath = collectionPath
        self.isCollectionGroup = isCollectionGroup
    }

    // MARK: - Chainable builders

    public func `where`(_ field: String, _ op: WhereOperator, _ value: JSONValue = .null) -> Query {
        var copy = self
        let clause: JSONValue
        switch op {
        case .isNull, .isNotNull:
            clause = .object([
                "field": .string(field),
                "op": .string(op.wireOp)
            ])
        default:
            clause = .object([
                "field": .string(field),
                "op": .string(op.wireOp),
                "value": value
            ])
        }
        copy.wheres.append(clause)
        return copy
    }

    public func orderBy(_ field: String, ascending: Bool = true) -> Query {
        var copy = self
        copy.orders.append(OrderBySpec(field: field, direction: ascending ? "asc" : "desc"))
        return copy
    }

    public func limit(_ count: Int) -> Query {
        var copy = self
        copy.lim = count
        return copy
    }

    public func select(_ fields: [String]) -> Query {
        var copy = self
        copy.selectFields = fields
        return copy
    }

    public func startAt(_ values: [JSONValue]) -> Query {
        var copy = self
        copy.startAt = values
        copy.startAfter = nil
        return copy
    }

    public func startAfter(_ values: [JSONValue]) -> Query {
        var copy = self
        copy.startAfter = values
        copy.startAt = nil
        return copy
    }

    public func endAt(_ values: [JSONValue]) -> Query {
        var copy = self
        copy.endAt = values
        copy.endBefore = nil
        return copy
    }

    public func endBefore(_ values: [JSONValue]) -> Query {
        var copy = self
        copy.endBefore = values
        copy.endAt = nil
        return copy
    }

    // MARK: - Execution

    public func get() async throws(DocsError) -> QuerySnapshot<T> {
        let body = buildQueryBody()
        let path = queryPath()
        let dto: QueryResponseDTO
        do {
            dto = try await http.request(method: "POST", path: path, body: body, headers: [:])
        } catch {
            throw DocsError.from(transport: error)
        }
        let snapshots = dto.documents.map(makeSnapshot)
        let changes = snapshots.map { DocumentChange(type: .added, document: $0) }
        return QuerySnapshot(docs: snapshots, docChanges: changes)
    }

    public func count() async throws(DocsError) -> Int64 {
        let result = try await aggregate([.count(alias: "count")])
        return result.int("count") ?? 0
    }

    public func aggregate(_ aggregates: [Aggregate]) async throws(DocsError) -> AggregateResult {
        let body = AggregateRequestBody(
            where: whereValue(),
            aggregations: aggregates.map { $0.toSpec() }
        )
        let path = aggregatePath()
        let dto: AggregateResponseDTO
        do {
            dto = try await http.request(method: "POST", path: path, body: body, headers: [:])
        } catch {
            throw DocsError.from(transport: error)
        }
        return AggregateResult(values: dto.results)
    }

    // MARK: - Snapshot listener

    /// Subscribe to changes. Returns an `Unsubscribe` closure. See
    /// `SnapshotListener.swift` for implementation details.
    @discardableResult
    public func onSnapshot(_ callback: @escaping @Sendable (QuerySnapshot<T>) -> Void) async -> Unsubscribe {
        await SnapshotListener.start(query: self, callback: callback)
    }

    // MARK: - Internal helpers

    package func queryPath() -> String {
        if isCollectionGroup {
            return "\(pathPrefix)/collectionGroup/\(collectionPath)/query"
        }
        return "\(pathPrefix)/\(collectionPath)/query"
    }

    package func aggregatePath() -> String {
        if isCollectionGroup {
            return "\(pathPrefix)/collectionGroup/\(collectionPath)/aggregate"
        }
        return "\(pathPrefix)/\(collectionPath)/aggregate"
    }

    package func subscribePath() -> String {
        "\(pathPrefix)/\(collectionPath)/subscribe"
    }

    package var rawCollectionPath: String { collectionPath }
    package var rawPathPrefix: String { pathPrefix }
    package var transport: HTTPRequesting { http }

    package func whereValue() -> JSONValue? {
        if wheres.isEmpty { return nil }
        if wheres.count == 1 { return wheres[0] }
        return .array(wheres)
    }

    func buildQueryBody() -> QueryRequestBody {
        QueryRequestBody(
            where: whereValue(),
            orderBy: orders.isEmpty ? nil : orders,
            limit: lim,
            select: selectFields,
            startAt: startAt,
            startAfter: startAfter,
            endAt: endAt,
            endBefore: endBefore
        )
    }

    func buildSubscribeBody() -> SubscribeRequestBody {
        SubscribeRequestBody(
            where: whereValue(),
            orderBy: orders.isEmpty ? nil : orders,
            limit: lim
        )
    }

    func makeSnapshot(_ dto: DocumentDTO) -> DocumentSnapshot<T> {
        let ref = DocumentRef<T>(
            http: http,
            pathPrefix: pathPrefix,
            path: dto.path
        )
        return DocumentSnapshot(
            id: dto.documentId,
            path: dto.path,
            exists: true,
            version: dto.version,
            raw: dto.data,
            ref: ref
        )
    }
}

/// Internal subscribe request body. Kept here so `Query` can build it.
struct SubscribeRequestBody: Encodable, Sendable {
    let `where`: JSONValue?
    let orderBy: [OrderBySpec]?
    let limit: Int?

    enum CodingKeys: String, CodingKey { case `where`, orderBy, limit }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let w = `where` { try c.encode(w, forKey: .where) }
        if let ob = orderBy, !ob.isEmpty { try c.encode(ob, forKey: .orderBy) }
        if let l = limit { try c.encode(l, forKey: .limit) }
    }
}
