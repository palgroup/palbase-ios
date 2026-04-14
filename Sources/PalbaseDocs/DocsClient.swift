import Foundation
@_exported import PalbaseCore

/// Palbase Docs module entry point. Use `PalbaseDocs.shared` after
/// `Palbase.configure(_:)`.
///
/// ```swift
/// struct Todo: Codable, Sendable { let id: String; let title: String; let done: Bool }
///
/// let docs = try PalbaseDocs.shared
/// let todos = try docs.collection("todos", of: Todo.self)
/// try await todos.document("t1").set(Todo(id: "t1", title: "Hi", done: false))
/// let snap = try await todos.where("done", .equalTo, .bool(false)).get()
/// ```
public struct PalbaseDocs: Sendable {
    let http: HTTPRequesting
    let tokens: TokenManager
    let pathPrefix: String

    package init(
        http: HTTPRequesting,
        tokens: TokenManager,
        pathPrefix: String = "/v1/docs"
    ) {
        self.http = http
        self.tokens = tokens
        self.pathPrefix = pathPrefix
    }

    /// Shared Docs client backed by the global SDK configuration. Throws
    /// `DocsError.notConfigured` if `Palbase.configure(_:)` was not called.
    public static var shared: PalbaseDocs {
        get throws(DocsError) {
            guard let http = Palbase.http, let tokens = Palbase.tokens else {
                throw DocsError.notConfigured
            }
            return PalbaseDocs(http: http, tokens: tokens)
        }
    }

    // MARK: - Refs

    /// Reference a top-level collection.
    public func collection<T: Codable & Sendable>(
        _ name: String,
        of: T.Type = T.self
    ) throws(DocsError) -> CollectionRef<T> {
        try DocsValidator.validateSegment(name)
        return CollectionRef<T>(http: http, pathPrefix: pathPrefix, path: name)
    }

    /// Reference a top-level document at `collection/documentId/...`.
    public func document<T: Codable & Sendable>(
        _ path: String,
        of: T.Type = T.self
    ) throws(DocsError) -> DocumentRef<T> {
        try DocsValidator.validateDocumentPath(path)
        return DocumentRef<T>(http: http, pathPrefix: pathPrefix, path: path)
    }

    /// Build a collection group query — queries across all subcollections
    /// sharing `id`, regardless of their parent path.
    public func collectionGroup<T: Codable & Sendable>(
        _ id: String,
        of: T.Type = T.self
    ) throws(DocsError) -> Query<T> {
        try DocsValidator.validateSegment(id)
        return Query<T>(
            http: http,
            pathPrefix: pathPrefix,
            collectionPath: id,
            isCollectionGroup: true
        )
    }

    // MARK: - Batch

    /// Commit up to `maxBatchOperations` writes atomically in a single server
    /// round-trip. Operations execute in order within the backend transaction.
    public func batch<T: Codable & Sendable>(_ operations: [BatchOperation<T>]) async throws(DocsError) {
        if operations.isEmpty { return }
        if operations.count > maxBatchOperations {
            throw DocsError.batchTooLarge(max: maxBatchOperations)
        }
        var dtos: [BatchOperationDTO] = []
        dtos.reserveCapacity(operations.count)
        for op in operations {
            dtos.append(try op.toDTO())
        }
        let body = BatchWriteRequestBody(operations: dtos)
        do {
            let _: BatchWriteResponseDTO = try await http.request(
                method: "POST",
                path: "\(pathPrefix)/batch",
                body: body,
                headers: [:]
            )
        } catch {
            throw DocsError.from(transport: error)
        }
    }

    // MARK: - Batch get

    /// Fetch multiple documents in a single request. Missing documents are
    /// returned with `exists == false`.
    public func batchGet<T: Codable & Sendable>(
        _ refs: [DocumentRef<T>]
    ) async throws(DocsError) -> [DocumentSnapshot<T>] {
        if refs.isEmpty { return [] }
        if refs.count > maxBatchOperations {
            throw DocsError.batchTooLarge(max: maxBatchOperations)
        }
        let paths = refs.map { $0.path }
        let body = BatchGetRequestBody(paths: paths)
        let dto: BatchGetResponseDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "\(pathPrefix)/batchGet",
                body: body,
                headers: [:]
            )
        } catch {
            throw DocsError.from(transport: error)
        }

        // Server may reorder; build a lookup and return snapshots in the caller's order.
        let byPath: [String: BatchGetResultDTO] = Dictionary(
            uniqueKeysWithValues: dto.results.map { ($0.path, $0) }
        )
        return refs.map { ref in
            guard let result = byPath[ref.path], result.found, let doc = result.document else {
                return DocumentSnapshot<T>(
                    id: ref.id,
                    path: ref.path,
                    exists: false,
                    version: 0,
                    raw: nil,
                    ref: ref
                )
            }
            return DocumentSnapshot<T>(
                id: doc.documentId,
                path: doc.path,
                exists: true,
                version: doc.version,
                raw: doc.data,
                ref: ref
            )
        }
    }

    // MARK: - Transactions

    /// Execute `block` inside a server-side transaction. Reads within the
    /// block see a consistent snapshot; writes queued via `tx.set/update/...`
    /// are applied atomically on successful return. A thrown error triggers
    /// rollback.
    public func transaction(
        _ block: @Sendable @escaping (PalbaseDocsTransaction) async throws -> Void
    ) async throws(DocsError) {
        // Begin
        let begin: TransactionBeginResponseDTO
        do {
            begin = try await http.request(
                method: "POST",
                path: "\(pathPrefix)/transaction/begin",
                body: nil,
                headers: [:]
            )
        } catch {
            throw DocsError.from(transport: error)
        }

        let tx = PalbaseDocsTransaction(http: http, pathPrefix: pathPrefix, txId: begin.transactionId)
        let pathPrefix = self.pathPrefix
        let httpRef = http

        do {
            try await block(tx)
        } catch {
            try? await httpRef.requestVoid(
                method: "POST",
                path: "\(pathPrefix)/transaction/rollback",
                body: TransactionRollbackRequestBody(transactionId: begin.transactionId),
                headers: [:]
            )
            if let docsErr = error as? DocsError { throw docsErr }
            if let core = error as? PalbaseCoreError { throw DocsError.from(transport: core) }
            throw DocsError.transactionFailed(error.localizedDescription)
        }

        let commitBody = TransactionCommitRequestBody(
            transactionId: begin.transactionId,
            operations: tx.operations
        )
        do {
            try await httpRef.requestVoid(
                method: "POST",
                path: "\(pathPrefix)/transaction/commit",
                body: commitBody,
                headers: [:]
            )
        } catch {
            try? await httpRef.requestVoid(
                method: "POST",
                path: "\(pathPrefix)/transaction/rollback",
                body: TransactionRollbackRequestBody(transactionId: begin.transactionId),
                headers: [:]
            )
            throw DocsError.from(transport: error)
        }
    }
}
