import Foundation

// MARK: - Domain types

/// A stored object's metadata as returned by list/info endpoints.
public struct FileObject: Sendable, Equatable {
    public let id: String?
    public let name: String
    public let bucketId: String?
    public let owner: String?
    public let size: Int?
    public let contentType: String?
    public let metadata: [String: String]?
    public let createdAt: Date?
    public let updatedAt: Date?

    package init(
        id: String?,
        name: String,
        bucketId: String?,
        owner: String?,
        size: Int?,
        contentType: String?,
        metadata: [String: String]?,
        createdAt: Date?,
        updatedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.bucketId = bucketId
        self.owner = owner
        self.size = size
        self.contentType = contentType
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Options used when uploading an object.
public struct UploadOptions: Sendable, Equatable {
    public var contentType: String?
    public var upsert: Bool
    public var cacheControl: String?
    public var metadata: [String: String]?

    public init(
        contentType: String? = nil,
        upsert: Bool = false,
        cacheControl: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.contentType = contentType
        self.upsert = upsert
        self.cacheControl = cacheControl
        self.metadata = metadata
    }
}

public enum SortOrder: String, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

public struct SortBy: Sendable, Equatable {
    public var column: String
    public var order: SortOrder

    public init(column: String, order: SortOrder = .ascending) {
        self.column = column
        self.order = order
    }
}

/// Options for listing objects under a prefix.
public struct ListOptions: Sendable, Equatable {
    public var limit: Int?
    public var offset: Int?
    public var sortBy: SortBy?
    public var search: String?

    public init(
        limit: Int? = nil,
        offset: Int? = nil,
        sortBy: SortBy? = nil,
        search: String? = nil
    ) {
        self.limit = limit
        self.offset = offset
        self.sortBy = sortBy
        self.search = search
    }
}

/// Pair of path + signed URL returned from batch signing.
public struct SignedURL: Sendable, Equatable {
    public let path: String
    public let signedURL: URL

    package init(path: String, signedURL: URL) {
        self.path = path
        self.signedURL = signedURL
    }
}

/// Signed URL for a one-shot upload. `token` is present on endpoints that
/// return it as a discrete field.
public struct SignedUploadURL: Sendable, Equatable {
    public let path: String
    public let signedURL: URL
    public let token: String?

    package init(path: String, signedURL: URL, token: String?) {
        self.path = path
        self.signedURL = signedURL
        self.token = token
    }
}

// MARK: - DTOs (internal wire format)

/// Server-shape object record returned by list / info / create endpoints.
struct FileObjectDTO: Decodable, Sendable {
    let id: String?
    let name: String
    let bucketId: String?
    let owner: String?
    let createdAt: Date?
    let updatedAt: Date?
    let lastAccessedAt: Date?
    let metadata: ObjectMetadata?
    let userMetadata: [String: String]?

    struct ObjectMetadata: Decodable, Sendable {
        let size: Int?
        let mimetype: String?
        let cacheControl: String?
    }

    func toFileObject() -> FileObject {
        FileObject(
            id: id,
            name: name,
            bucketId: bucketId,
            owner: owner,
            size: metadata?.size,
            contentType: metadata?.mimetype,
            metadata: userMetadata,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct CreateObjectResponseDTO: Decodable, Sendable {
    let id: String?
    let key: String?
    let name: String?
    let path: String?
    // Server returns `Id`/`Key`; snake_case converter lowercases to `id`/`key`.

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case key = "Key"
        case name
        case path
    }
}

struct SignResponseDTO: Decodable, Sendable {
    let signedURL: String?
    let url: String?
    let token: String?
    let path: String?
    let error: String?
}

struct SignedURLBatchEntryDTO: Decodable, Sendable {
    let path: String?
    let signedURL: String?
    let error: String?
}

struct MoveRequestDTO: Encodable, Sendable {
    let bucketId: String
    let sourceKey: String
    let destinationBucket: String?
    let destinationKey: String
}

struct CopyRequestDTO: Encodable, Sendable {
    let bucketId: String
    let sourceKey: String
    let destinationBucket: String?
    let destinationKey: String
}

struct DeletePrefixesRequestDTO: Encodable, Sendable {
    let prefixes: [String]
}

struct ListRequestDTO: Encodable, Sendable {
    let prefix: String
    let limit: Int?
    let offset: Int?
    let sortBy: SortByDTO?
    let search: String?

    struct SortByDTO: Encodable, Sendable {
        let column: String
        let order: String
    }
}

struct SignURLRequestDTO: Encodable, Sendable {
    let expiresIn: Int
    let transform: TransformDTO?
}

struct SignURLsRequestDTO: Encodable, Sendable {
    let paths: [String]
    let expiresIn: Int
}

struct TransformDTO: Encodable, Sendable {
    let width: Int?
    let height: Int?
    let resize: String?
    let format: String?
    let quality: Int?

    init?(_ options: TransformOptions?) {
        guard let options else { return nil }
        if options == TransformOptions() { return nil }
        self.width = options.width
        self.height = options.height
        self.resize = options.resize?.rawValue
        self.format = options.format?.rawValue
        self.quality = options.quality
    }
}

struct UploadedKeyResponseDTO: Decodable, Sendable {
    let key: String?

    enum CodingKeys: String, CodingKey {
        case key = "Key"
    }
}
