import Foundation

/// Maximum number of operations in a single batch or transaction commit.
public let maxBatchOperations = 500

/// One operation within a batch write or transaction commit.
public enum BatchOperation<T: Codable & Sendable>: Sendable {
    case set(ref: DocumentRef<T>, data: T)
    case setMerge(ref: DocumentRef<T>, data: T)
    case update(ref: DocumentRef<T>, data: [String: JSONValue])
    case delete(ref: DocumentRef<T>)
    case transform(ref: DocumentRef<T>, transforms: [FieldTransform])

    var path: String {
        switch self {
        case .set(let r, _), .setMerge(let r, _), .update(let r, _),
             .delete(let r), .transform(let r, _):
            return r.path
        }
    }

    func toDTO() throws(DocsError) -> BatchOperationDTO {
        switch self {
        case .set(_, let data):
            let value = try encodeValue(data)
            return BatchOperationDTO(op: "set", path: path, data: value, transforms: nil)
        case .setMerge(_, let data):
            let value = try encodeValue(data)
            return BatchOperationDTO(op: "setMerge", path: path, data: value, transforms: nil)
        case .update(_, let data):
            return BatchOperationDTO(op: "update", path: path, data: .object(data), transforms: nil)
        case .delete:
            return BatchOperationDTO(op: "delete", path: path, data: nil, transforms: nil)
        case .transform(_, let transforms):
            if transforms.count > maxTransformsPerRequest {
                throw DocsError.transformsTooLarge(max: maxTransformsPerRequest)
            }
            return BatchOperationDTO(
                op: "transform",
                path: path,
                data: nil,
                transforms: transforms.map { $0.toDTO() }
            )
        }
    }
}

func encodeValue<T: Encodable>(_ value: T) throws(DocsError) -> JSONValue {
    let data: Data
    do {
        data = try JSONEncoder.palbaseDefault.encode(value)
    } catch {
        throw DocsError.encoding(error.localizedDescription)
    }
    do {
        return try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
        throw DocsError.encoding(error.localizedDescription)
    }
}
