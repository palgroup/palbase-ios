import Foundation

/// Reference to a collection — similar to Firestore's `CollectionReference`.
/// Collections live at paths with an odd number of segments, e.g. `users` or
/// `users/user1/posts`.
public struct CollectionRef<T: Codable & Sendable>: Sendable {
    public let path: String
    let http: HTTPRequesting
    let pathPrefix: String

    /// Collection ID — the last path segment.
    public var id: String {
        String(path.split(separator: "/").last ?? "")
    }

    package init(http: HTTPRequesting, pathPrefix: String, path: String) {
        self.http = http
        self.pathPrefix = pathPrefix
        self.path = path
    }

    /// Obtain a reference to a document inside this collection.
    public func document(_ id: String) throws(DocsError) -> DocumentRef<T> {
        try DocsValidator.validateSegment(id)
        return DocumentRef<T>(
            http: http,
            pathPrefix: pathPrefix,
            path: "\(path)/\(id)"
        )
    }

    /// Create a new document with a server-generated ID.
    @discardableResult
    public func add(_ data: T) async throws(DocsError) -> DocumentRef<T> {
        let body = try RawJSON(encodeData(data))
        do {
            let dto: DocumentDTO = try await http.request(
                method: "POST",
                path: "\(pathPrefix)/\(path)",
                body: body,
                headers: [:]
            )
            return DocumentRef<T>(
                http: http,
                pathPrefix: pathPrefix,
                path: dto.path
            )
        } catch {
            throw DocsError.from(transport: error)
        }
    }

    // MARK: - Query entrypoints

    public func `where`(_ field: String, _ op: WhereOperator, _ value: JSONValue) -> Query<T> {
        Query(ref: self).where(field, op, value)
    }

    public func orderBy(_ field: String, ascending: Bool = true) -> Query<T> {
        Query(ref: self).orderBy(field, ascending: ascending)
    }

    public func limit(_ count: Int) -> Query<T> {
        Query(ref: self).limit(count)
    }

    /// Fetch all documents in the collection as a `QuerySnapshot`.
    public func get() async throws(DocsError) -> QuerySnapshot<T> {
        try await Query(ref: self).get()
    }

    /// Run an aggregate over a filter.
    public func aggregate(_ aggregates: [Aggregate]) async throws(DocsError) -> AggregateResult {
        try await Query(ref: self).aggregate(aggregates)
    }

    /// Convenience: count documents in the (filtered) collection.
    public func count() async throws(DocsError) -> Int64 {
        try await Query(ref: self).count()
    }

    // MARK: - Internal helpers

    func encodeData<U: Encodable>(_ value: U) throws(DocsError) -> Data {
        do {
            return try JSONEncoder.palbaseDefault.encode(value)
        } catch {
            throw DocsError.encoding(error.localizedDescription)
        }
    }
}
