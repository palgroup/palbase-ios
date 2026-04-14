import Foundation

/// Server-side atomic field transform applied via
/// `POST /v1/docs/{path}:transform` or inside a batch/transaction.
public enum FieldTransform: Sendable {
    /// Set the field to the server's clock time at apply.
    case serverTimestamp(field: String)
    /// Atomically increment a numeric field by `by`.
    case increment(field: String, by: Double)
    /// Set the field to `max(current, value)`.
    case maximum(field: String, value: Double)
    /// Set the field to `min(current, value)`.
    case minimum(field: String, value: Double)
    /// Append new elements to an array field (deduping).
    case arrayUnion(field: String, values: [JSONValue])
    /// Remove elements from an array field.
    case arrayRemove(field: String, values: [JSONValue])

    var field: String {
        switch self {
        case .serverTimestamp(let f),
             .increment(let f, _),
             .maximum(let f, _),
             .minimum(let f, _),
             .arrayUnion(let f, _),
             .arrayRemove(let f, _):
            return f
        }
    }

    func toDTO() -> FieldTransformDTO {
        switch self {
        case .serverTimestamp(let f):
            return FieldTransformDTO(field: f, type: "serverTimestamp", value: nil)
        case .increment(let f, let n):
            return FieldTransformDTO(field: f, type: "increment", value: .double(n))
        case .maximum(let f, let n):
            return FieldTransformDTO(field: f, type: "maximum", value: .double(n))
        case .minimum(let f, let n):
            return FieldTransformDTO(field: f, type: "minimum", value: .double(n))
        case .arrayUnion(let f, let values):
            return FieldTransformDTO(field: f, type: "arrayUnion", value: .array(values))
        case .arrayRemove(let f, let values):
            return FieldTransformDTO(field: f, type: "arrayRemove", value: .array(values))
        }
    }
}

/// Maximum number of transforms per request.
package let maxTransformsPerRequest = 20
