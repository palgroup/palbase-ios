import Foundation

/// Handle for reads performed inside a transaction. Obtain from
/// `PalbaseDocs.shared.transaction { tx in ... }`. Queued writes are applied
/// on commit; reads are served by the transaction's snapshot and locked
/// (SELECT ... FOR UPDATE on the backend).
public final class PalbaseDocsTransaction: @unchecked Sendable {
    private let http: HTTPRequesting
    private let pathPrefix: String
    private let txId: String
    private let opsLock = NSLock()
    private var _operations: [BatchOperationDTO] = []

    package init(http: HTTPRequesting, pathPrefix: String, txId: String) {
        self.http = http
        self.pathPrefix = pathPrefix
        self.txId = txId
    }

    var operations: [BatchOperationDTO] {
        opsLock.lock(); defer { opsLock.unlock() }
        return _operations
    }

    var transactionId: String { txId }

    // MARK: - Reads

    /// Read a document inside the transaction. Subsequent writes in the same
    /// transaction will see this snapshot.
    public func get<T: Codable & Sendable>(_ ref: DocumentRef<T>) async throws(DocsError) -> DocumentSnapshot<T> {
        let body = TransactionGetRequestBody(transactionId: txId, path: ref.path)
        do {
            let dto: DocumentDTO = try await http.request(
                method: "POST",
                path: "\(pathPrefix)/transaction/get",
                body: body,
                headers: [:]
            )
            return DocumentSnapshot(
                id: dto.documentId,
                path: dto.path,
                exists: true,
                version: dto.version,
                raw: dto.data,
                ref: ref
            )
        } catch {
            let mapped = DocsError.from(transport: error)
            if case .documentNotFound = mapped {
                return DocumentSnapshot(
                    id: ref.id,
                    path: ref.path,
                    exists: false,
                    version: 0,
                    raw: nil,
                    ref: ref
                )
            }
            throw mapped
        }
    }

    // MARK: - Queued writes

    public func set<T: Codable & Sendable>(_ ref: DocumentRef<T>, data: T, merge: Bool = false) throws(DocsError) {
        let value = try encodeValue(data)
        enqueue(BatchOperationDTO(
            op: merge ? "setMerge" : "set",
            path: ref.path,
            data: value,
            transforms: nil
        ))
    }

    public func update<T: Codable & Sendable>(_ ref: DocumentRef<T>, data: [String: JSONValue]) throws(DocsError) {
        for key in data.keys { try DocsValidator.validateFieldName(key) }
        enqueue(BatchOperationDTO(
            op: "update",
            path: ref.path,
            data: .object(data),
            transforms: nil
        ))
    }

    public func delete<T: Codable & Sendable>(_ ref: DocumentRef<T>) {
        enqueue(BatchOperationDTO(op: "delete", path: ref.path, data: nil, transforms: nil))
    }

    public func transform<T: Codable & Sendable>(_ ref: DocumentRef<T>, transforms: [FieldTransform]) throws(DocsError) {
        if transforms.count > maxTransformsPerRequest {
            throw DocsError.transformsTooLarge(max: maxTransformsPerRequest)
        }
        for t in transforms { try DocsValidator.validateFieldName(t.field) }
        enqueue(BatchOperationDTO(
            op: "transform",
            path: ref.path,
            data: nil,
            transforms: transforms.map { $0.toDTO() }
        ))
    }

    private func enqueue(_ op: BatchOperationDTO) {
        opsLock.lock(); defer { opsLock.unlock() }
        _operations.append(op)
    }
}
