import Foundation

/// Read-only snapshot of a single document at a point in time.
public struct DocumentSnapshot<T: Codable & Sendable>: Sendable {
    public let id: String
    public let path: String
    public let exists: Bool
    public let version: Int64
    public let ref: DocumentRef<T>
    private let raw: JSONValue?

    package init(id: String, path: String, exists: Bool, version: Int64, raw: JSONValue?, ref: DocumentRef<T>) {
        self.id = id
        self.path = path
        self.exists = exists
        self.version = version
        self.raw = raw
        self.ref = ref
    }

    /// Decoded document data, or `nil` if the document does not exist or cannot
    /// be decoded as `T`.
    public func data() -> T? {
        guard exists, let raw = raw else { return nil }
        do {
            let bytes = try JSONEncoder.palbaseDefault.encode(raw)
            return try JSONDecoder.palbaseDefault.decode(T.self, from: bytes)
        } catch {
            return nil
        }
    }

    /// Raw JSON for the document data, or `nil` if the document does not exist.
    public func rawData() -> JSONValue? { raw }
}

/// Snapshot of a query result — a collection of documents plus computed change
/// information for listeners.
public struct QuerySnapshot<T: Codable & Sendable>: Sendable {
    public let docs: [DocumentSnapshot<T>]
    public let docChanges: [DocumentChange<T>]

    public var size: Int { docs.count }
    public var empty: Bool { docs.isEmpty }

    package init(docs: [DocumentSnapshot<T>], docChanges: [DocumentChange<T>]) {
        self.docs = docs
        self.docChanges = docChanges
    }
}

/// Type of a document change within a `QuerySnapshot`.
public enum ChangeType: Sendable, Equatable {
    case added
    case modified
    case removed
}

/// Single document change within a `QuerySnapshot`.
public struct DocumentChange<T: Codable & Sendable>: Sendable {
    public let type: ChangeType
    public let document: DocumentSnapshot<T>

    package init(type: ChangeType, document: DocumentSnapshot<T>) {
        self.type = type
        self.document = document
    }
}
