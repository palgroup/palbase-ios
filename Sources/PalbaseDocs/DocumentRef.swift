import Foundation

/// Reference to a single document — similar to Firestore's `DocumentReference`.
/// Documents live at paths with an even number of segments, e.g. `users/user1`
/// or `users/user1/posts/post1`.
public struct DocumentRef<T: Codable & Sendable>: Sendable {
    public let path: String
    let http: HTTPRequesting
    let pathPrefix: String

    /// Document ID — the last path segment.
    public var id: String {
        String(path.split(separator: "/").last ?? "")
    }

    /// Parent collection path.
    public var parentPath: String {
        let segs = path.split(separator: "/").map(String.init)
        return segs.dropLast().joined(separator: "/")
    }

    package init(http: HTTPRequesting, pathPrefix: String, path: String) {
        self.http = http
        self.pathPrefix = pathPrefix
        self.path = path
    }

    /// Obtain a reference to a subcollection under this document.
    public func collection<U: Codable & Sendable>(_ name: String, of: U.Type = U.self) throws(DocsError) -> CollectionRef<U> {
        try DocsValidator.validateSegment(name)
        return CollectionRef<U>(
            http: http,
            pathPrefix: pathPrefix,
            path: "\(path)/\(name)"
        )
    }

    // MARK: - Reads

    /// Fetch the document. If the server returns 404, the returned snapshot has
    /// `exists == false`.
    public func get() async throws(DocsError) -> DocumentSnapshot<T> {
        do {
            let dto: DocumentDTO = try await http.request(
                method: "GET",
                path: "\(pathPrefix)/\(path)",
                body: nil,
                headers: [:]
            )
            return makeSnapshot(dto: dto)
        } catch {
            let mapped = DocsError.from(transport: error)
            if case .documentNotFound = mapped {
                return DocumentSnapshot(
                    id: id,
                    path: path,
                    exists: false,
                    version: 0,
                    raw: nil,
                    ref: self
                )
            }
            throw mapped
        }
    }

    // MARK: - Writes

    /// Create or overwrite the document. When `merge` is `true`, a shallow
    /// merge is performed (top-level fields not in `data` are preserved).
    @discardableResult
    public func set(_ data: T, merge: Bool = false) async throws(DocsError) -> DocumentSnapshot<T> {
        let body = try RawJSON(encodeData(data))
        let suffix = merge ? "?merge=true" : ""
        do {
            let dto: DocumentDTO = try await http.request(
                method: "PUT",
                path: "\(pathPrefix)/\(path)\(suffix)",
                body: body,
                headers: [:]
            )
            return makeSnapshot(dto: dto)
        } catch {
            throw DocsError.from(transport: error)
        }
    }

    /// Partial update using dot-notation. Fails with `documentNotFound` if
    /// the document does not exist. Use `JSONValue.null`-equivalent sentinels
    /// or `"__field_delete__"` to delete a specific field.
    @discardableResult
    public func update(_ data: [String: JSONValue]) async throws(DocsError) -> DocumentSnapshot<T> {
        for key in data.keys { try DocsValidator.validateFieldName(key) }
        let body = JSONValue.object(data)
        do {
            let dto: DocumentDTO = try await http.request(
                method: "PATCH",
                path: "\(pathPrefix)/\(path)",
                body: body,
                headers: [:]
            )
            return makeSnapshot(dto: dto)
        } catch {
            throw DocsError.from(transport: error)
        }
    }

    /// Delete the document. When `recursive` is true, all subcollection
    /// documents are also deleted.
    public func delete(recursive: Bool = false) async throws(DocsError) {
        let suffix = recursive ? "?recursive=true" : ""
        do {
            try await http.requestVoid(
                method: "DELETE",
                path: "\(pathPrefix)/\(path)\(suffix)",
                body: nil,
                headers: [:]
            )
        } catch {
            throw DocsError.from(transport: error)
        }
    }

    /// Apply atomic field transforms — `serverTimestamp`, `increment`, etc.
    @discardableResult
    public func transform(_ transforms: [FieldTransform]) async throws(DocsError) -> DocumentSnapshot<T> {
        if transforms.isEmpty {
            throw DocsError.transformsTooLarge(max: maxTransformsPerRequest)
        }
        if transforms.count > maxTransformsPerRequest {
            throw DocsError.transformsTooLarge(max: maxTransformsPerRequest)
        }
        for t in transforms { try DocsValidator.validateFieldName(t.field) }

        let body = TransformRequestBody(transforms: transforms.map { $0.toDTO() })
        do {
            let dto: DocumentDTO = try await http.request(
                method: "POST",
                path: "\(pathPrefix)/\(path):transform",
                body: body,
                headers: [:]
            )
            return makeSnapshot(dto: dto)
        } catch {
            throw DocsError.from(transport: error)
        }
    }

    /// List the subcollection names under this document.
    public func listCollectionIds() async throws(DocsError) -> [String] {
        do {
            let dto: ListCollectionIdsResponseDTO = try await http.request(
                method: "POST",
                path: "\(pathPrefix)/\(path)/listCollectionIds",
                body: nil,
                headers: [:]
            )
            return dto.collections
        } catch {
            throw DocsError.from(transport: error)
        }
    }

    // MARK: - Internal helpers

    func makeSnapshot(dto: DocumentDTO) -> DocumentSnapshot<T> {
        DocumentSnapshot(
            id: dto.documentId,
            path: dto.path,
            exists: true,
            version: dto.version,
            raw: dto.data,
            ref: self
        )
    }

    func encodeData<U: Encodable>(_ value: U) throws(DocsError) -> Data {
        do {
            return try JSONEncoder.palbaseDefault.encode(value)
        } catch {
            throw DocsError.encoding(error.localizedDescription)
        }
    }
}
