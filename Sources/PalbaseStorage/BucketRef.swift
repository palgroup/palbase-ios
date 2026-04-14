import Foundation
@_exported import PalbaseCore

/// Reference to a bucket. All file operations hang off this.
///
/// ```swift
/// let avatars = try PalbaseStorage.shared.bucket("avatars")
/// _ = try await avatars.upload(path: "me.png", data: pngData)
/// ```
public struct BucketRef: Sendable {
    public let name: String
    let http: HTTPRequesting
    let pathPrefix: String // "/storage/v1"

    package init(name: String, http: HTTPRequesting, pathPrefix: String) {
        self.name = name
        self.http = http
        self.pathPrefix = pathPrefix
    }

    // MARK: - Upload (multipart)

    /// Upload raw data at `path`. Creates a new object or replaces an existing
    /// one when `options.upsert == true`.
    @discardableResult
    public func upload(
        path: String,
        data: Data,
        options: UploadOptions = .init()
    ) async throws(StorageError) -> FileObject {
        try PathValidator.validatePath(path)
        let body = try MultipartBody.build(filename: path, data: data, options: options)
        let headers = multipartHeaders(boundary: body.boundary, options: options)
        let objectPath = "\(pathPrefix)/object/\(name)/\(PathValidator.encodePath(path))"

        let raw: (data: Data, status: Int, headers: [String: String])
        do {
            raw = try await http.requestRawBody(
                method: "POST",
                path: objectPath,
                body: body.data,
                headers: headers
            )
        } catch {
            throw StorageError.from(transport: error)
        }

        // Server returns { Id, Key } — fetch info to materialize a full FileObject.
        _ = try? JSONDecoder.palbaseDefault.decode(CreateObjectResponseDTO.self, from: raw.data)
        return try await info(path: path)
    }

    /// Upload from a file URL on disk.
    @discardableResult
    public func upload(
        path: String,
        fileURL: URL,
        options: UploadOptions = .init()
    ) async throws(StorageError) -> FileObject {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw StorageError.uploadFailed(message: "Could not read \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
        var opts = options
        if opts.contentType == nil {
            opts.contentType = MimeTypes.guess(from: fileURL.pathExtension)
        }
        return try await upload(path: path, data: data, options: opts)
    }

    // MARK: - Download

    /// Download the full object body.
    public func download(path: String) async throws(StorageError) -> Data {
        try PathValidator.validatePath(path)
        let url = "\(pathPrefix)/object/authenticated/\(name)/\(PathValidator.encodePath(path))"
        do {
            let resp = try await http.requestRawBody(method: "GET", path: url, body: nil, headers: [:])
            return resp.data
        } catch {
            throw StorageError.from(transport: error)
        }
    }

    /// Download a byte range (inclusive) via HTTP 206.
    public func download(path: String, range: ClosedRange<Int>) async throws(StorageError) -> Data {
        try PathValidator.validatePath(path)
        let url = "\(pathPrefix)/object/authenticated/\(name)/\(PathValidator.encodePath(path))"
        let rangeHeader = "bytes=\(range.lowerBound)-\(range.upperBound)"
        do {
            let resp = try await http.requestRawBody(
                method: "GET",
                path: url,
                body: nil,
                headers: ["Range": rangeHeader]
            )
            return resp.data
        } catch {
            throw StorageError.from(transport: error)
        }
    }

    // MARK: - Info / remove / move / copy

    /// Fetch metadata for an object without downloading the body.
    public func info(path: String) async throws(StorageError) -> FileObject {
        try PathValidator.validatePath(path)
        let url = "\(pathPrefix)/object/info/authenticated/\(name)/\(PathValidator.encodePath(path))"
        let dto: FileObjectDTO
        do {
            dto = try await http.request(method: "GET", path: url, body: nil, headers: [:])
        } catch {
            throw StorageError.from(transport: error)
        }
        return dto.toFileObject()
    }

    /// Delete a batch of objects. Returns the server's view of each removed
    /// object (may be empty if none existed).
    @discardableResult
    public func remove(paths: [String]) async throws(StorageError) -> [FileObject] {
        guard !paths.isEmpty else { return [] }
        for p in paths { try PathValidator.validatePath(p) }
        let body = DeletePrefixesRequestDTO(prefixes: paths)
        let url = "\(pathPrefix)/object/\(name)"
        let dtos: [FileObjectDTO]
        do {
            dtos = try await http.request(method: "DELETE", path: url, body: body, headers: [:])
        } catch {
            throw StorageError.from(transport: error)
        }
        return dtos.map { $0.toFileObject() }
    }

    /// Move an object within the bucket (or across buckets via fully-qualified
    /// destination). For cross-bucket, encode as `"bucket/path"` — not yet
    /// exposed on this API; use `move(from:to:)` for same-bucket moves.
    public func move(from source: String, to destination: String) async throws(StorageError) {
        try PathValidator.validatePath(source)
        try PathValidator.validatePath(destination)
        let body = MoveRequestDTO(
            bucketId: name,
            sourceKey: source,
            destinationBucket: nil,
            destinationKey: destination
        )
        do {
            try await http.requestVoid(
                method: "POST",
                path: "\(pathPrefix)/object/move",
                body: body,
                headers: [:]
            )
        } catch {
            throw StorageError.from(transport: error)
        }
    }

    /// Copy an object within the bucket.
    public func copy(from source: String, to destination: String) async throws(StorageError) {
        try PathValidator.validatePath(source)
        try PathValidator.validatePath(destination)
        let body = CopyRequestDTO(
            bucketId: name,
            sourceKey: source,
            destinationBucket: nil,
            destinationKey: destination
        )
        do {
            try await http.requestVoid(
                method: "POST",
                path: "\(pathPrefix)/object/copy",
                body: body,
                headers: [:]
            )
        } catch {
            throw StorageError.from(transport: error)
        }
    }

    // MARK: - List

    /// List objects under `prefix` (defaults to bucket root).
    public func list(
        prefix: String? = nil,
        options: ListOptions = .init()
    ) async throws(StorageError) -> [FileObject] {
        let body = ListRequestDTO(
            prefix: prefix ?? "",
            limit: options.limit,
            offset: options.offset,
            sortBy: options.sortBy.map {
                ListRequestDTO.SortByDTO(column: $0.column, order: $0.order.rawValue)
            },
            search: options.search
        )
        let dtos: [FileObjectDTO]
        do {
            dtos = try await http.request(
                method: "POST",
                path: "\(pathPrefix)/object/list/\(name)",
                body: body,
                headers: [:]
            )
        } catch {
            throw StorageError.from(transport: error)
        }
        return dtos.map { $0.toFileObject() }
    }

    // MARK: - Signed URLs (read)

    /// Create a short-lived read URL for `path`.
    public func createSignedURL(
        path: String,
        expiresIn: TimeInterval
    ) async throws(StorageError) -> URL {
        try PathValidator.validatePath(path)
        let body = SignURLRequestDTO(expiresIn: Int(expiresIn), transform: nil)
        let dto: SignResponseDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "\(pathPrefix)/object/sign/\(name)/\(PathValidator.encodePath(path))",
                body: body,
                headers: [:]
            )
        } catch {
            throw StorageError.from(transport: error)
        }
        guard let signed = dto.signedURL, let url = resolveURL(signed) else {
            throw StorageError.uploadFailed(message: "Server did not return a signed URL.")
        }
        return url
    }

    /// Batch: sign many paths at once. Order of results matches input order
    /// best-effort; unsigned paths are dropped.
    public func createSignedURLs(
        paths: [String],
        expiresIn: TimeInterval
    ) async throws(StorageError) -> [SignedURL] {
        guard !paths.isEmpty else { return [] }
        for p in paths { try PathValidator.validatePath(p) }
        let body = SignURLsRequestDTO(paths: paths, expiresIn: Int(expiresIn))
        let entries: [SignedURLBatchEntryDTO]
        do {
            entries = try await http.request(
                method: "POST",
                path: "\(pathPrefix)/object/sign/\(name)",
                body: body,
                headers: [:]
            )
        } catch {
            throw StorageError.from(transport: error)
        }
        return entries.compactMap { entry in
            guard let p = entry.path, let signed = entry.signedURL, let url = resolveURL(signed) else {
                return nil
            }
            return SignedURL(path: p, signedURL: url)
        }
    }

    // MARK: - Signed URLs (upload)

    /// Create a signed upload URL for `path`. Callers can later invoke
    /// `uploadToSignedURL(_:data:)` to PUT content.
    public func createSignedUploadURL(
        path: String,
        expiresIn: TimeInterval
    ) async throws(StorageError) -> SignedUploadURL {
        try PathValidator.validatePath(path)
        _ = expiresIn // server currently uses a configured default; parameter reserved for future.
        let dto: SignResponseDTO
        do {
            dto = try await http.request(
                method: "POST",
                path: "\(pathPrefix)/object/upload/sign/\(name)/\(PathValidator.encodePath(path))",
                body: nil,
                headers: [:]
            )
        } catch {
            throw StorageError.from(transport: error)
        }
        let urlString = dto.url ?? dto.signedURL
        guard let urlString, let url = resolveURL(urlString) else {
            throw StorageError.uploadFailed(message: "Server did not return an upload URL.")
        }
        return SignedUploadURL(path: path, signedURL: url, token: dto.token)
    }

    /// Upload `data` using a previously issued signed upload URL.
    @discardableResult
    public func uploadToSignedURL(
        _ signed: SignedUploadURL,
        data: Data,
        options: UploadOptions = .init()
    ) async throws(StorageError) -> FileObject {
        let body = try MultipartBody.build(filename: signed.path, data: data, options: options)
        let headers = multipartHeaders(boundary: body.boundary, options: options)

        // Signed URL path includes query string with token — extract path + query.
        let (path, query) = splitSignedURL(signed.signedURL)
        let fullPath = query.map { "\(path)?\($0)" } ?? path

        do {
            _ = try await http.requestRawBody(
                method: "PUT",
                path: fullPath,
                body: body.data,
                headers: headers
            )
        } catch {
            throw StorageError.from(transport: error)
        }
        return try await info(path: signed.path)
    }

    /// Upload a file on disk using a signed upload URL.
    @discardableResult
    public func uploadToSignedURL(
        _ signed: SignedUploadURL,
        fileURL: URL,
        options: UploadOptions = .init()
    ) async throws(StorageError) -> FileObject {
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch {
            throw StorageError.uploadFailed(message: "Could not read \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
        var opts = options
        if opts.contentType == nil {
            opts.contentType = MimeTypes.guess(from: fileURL.pathExtension)
        }
        return try await uploadToSignedURL(signed, data: data, options: opts)
    }

    // MARK: - Public URL (client-side construction)

    /// Synchronously build the public URL for `path`. Adds a transform query
    /// string when provided. No server round-trip.
    public func publicURL(
        path: String,
        transform: TransformOptions? = nil
    ) -> URL {
        let base = baseURLString ?? "https://storage"
        let encoded = PathValidator.encodePath(path)
        let isTransform = (transform != nil && transform != TransformOptions())
        let root = isTransform
            ? "\(base)\(pathPrefix)/render/image/public/\(name)/\(encoded)"
            : "\(base)\(pathPrefix)/object/public/\(name)/\(encoded)"

        guard var comps = URLComponents(string: root) else {
            // Fallback — can't construct; return best-effort literal URL.
            return URL(string: root) ?? URL(fileURLWithPath: "/")
        }
        if isTransform, let t = transform {
            comps.queryItems = t.queryItems()
        }
        return comps.url ?? URL(string: root) ?? URL(fileURLWithPath: "/")
    }

    // MARK: - Image rendering (server-side)

    /// Render `path` with `transform`, returning the image bytes. When
    /// `authenticated == true`, uses the authenticated endpoint — otherwise the
    /// public render endpoint (bucket must be public).
    public func renderImage(
        path: String,
        transform: TransformOptions,
        authenticated: Bool = false
    ) async throws(StorageError) -> Data {
        try PathValidator.validatePath(path)
        let segment = authenticated ? "authenticated" : "public"
        var comps = URLComponents()
        comps.path = "\(pathPrefix)/render/image/\(segment)/\(name)/\(PathValidator.encodePath(path))"
        comps.queryItems = transform.queryItems()
        let full = (comps.path) + (comps.query.map { "?\($0)" } ?? "")
        do {
            let resp = try await http.requestRawBody(
                method: "GET",
                path: full,
                body: nil,
                headers: [:]
            )
            return resp.data
        } catch {
            throw StorageError.from(transport: error)
        }
    }

    // MARK: - Resumable (TUS)

    /// Build a TUS resumable upload. Call `start()` to kick it off. Pause, resume
    /// or cancel through the returned actor.
    public func resumableUpload(
        path: String,
        data: Data,
        options: UploadOptions = .init()
    ) -> ResumableUpload {
        ResumableUpload(
            http: http,
            pathPrefix: pathPrefix,
            bucket: name,
            path: path,
            source: .memory(data),
            totalBytes: data.count,
            options: options
        )
    }

    /// Build a TUS resumable upload from a file on disk.
    public func resumableUpload(
        path: String,
        fileURL: URL,
        options: UploadOptions = .init()
    ) -> ResumableUpload {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var opts = options
        if opts.contentType == nil {
            opts.contentType = MimeTypes.guess(from: fileURL.pathExtension)
        }
        return ResumableUpload(
            http: http,
            pathPrefix: pathPrefix,
            bucket: name,
            path: path,
            source: .file(fileURL),
            totalBytes: size,
            options: opts
        )
    }

    // MARK: - Internal helpers

    private var baseURLString: String? {
        // We don't own the base URL here (it's inside HttpClient). For public URLs
        // we best-effort derive from `PalbaseConfig.url` or the apiKey project ref.
        guard let cfg = Palbase.config else { return nil }
        if let explicit = cfg.url { return explicit }
        let parts = cfg.apiKey.split(separator: "_")
        guard parts.count >= 3, parts[0] == "pb" else { return nil }
        return "https://\(parts[1]).palbase.studio"
    }

    private func multipartHeaders(
        boundary: String,
        options: UploadOptions
    ) -> [String: String] {
        var h: [String: String] = [
            "Content-Type": "multipart/form-data; boundary=\(boundary)",
            "x-upsert": options.upsert ? "true" : "false"
        ]
        if let cache = options.cacheControl {
            h["cache-control"] = cache
        }
        if let meta = options.metadata,
           let json = try? JSONSerialization.data(withJSONObject: meta),
           let s = String(data: json, encoding: .utf8) {
            h["x-metadata"] = s
        }
        return h
    }

    private func resolveURL(_ raw: String) -> URL? {
        if let u = URL(string: raw), u.scheme != nil {
            return u
        }
        // Server returns path-only signed URLs (e.g. "/object/sign/...?token=...").
        guard let base = baseURLString, let u = URL(string: "\(base)\(raw)") else {
            return URL(string: raw)
        }
        return u
    }

    private func splitSignedURL(_ url: URL) -> (path: String, query: String?) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (url.path, nil)
        }
        return (comps.path, comps.query)
    }
}

// MARK: - Multipart body builder

enum MultipartBody {
    struct Built {
        let data: Data
        let boundary: String
    }

    static func build(
        filename: String,
        data: Data,
        options: UploadOptions
    ) throws(StorageError) -> Built {
        let boundary = "Palbase-\(UUID().uuidString)"
        let contentType = options.contentType ?? MimeTypes.guess(from: (filename as NSString).pathExtension) ?? "application/octet-stream"

        var body = Data()
        let line = "\r\n"
        let safeName = filename.replacingOccurrences(of: "\"", with: "_")

        body.append("--\(boundary)\(line)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\(line)".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\(line)\(line)".data(using: .utf8)!)
        body.append(data)
        body.append("\(line)--\(boundary)--\(line)".data(using: .utf8)!)

        return Built(data: body, boundary: boundary)
    }
}

// MARK: - Minimal MIME type guesser (no UTI dependency for Linux compatibility)

enum MimeTypes {
    static let byExtension: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "bmp": "image/bmp",
        "svg": "image/svg+xml",
        "pdf": "application/pdf",
        "json": "application/json",
        "txt": "text/plain",
        "csv": "text/csv",
        "html": "text/html",
        "mp4": "video/mp4",
        "mov": "video/quicktime",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "zip": "application/zip",
        "bin": "application/octet-stream"
    ]

    static func guess(from pathExtension: String) -> String? {
        guard !pathExtension.isEmpty else { return nil }
        return byExtension[pathExtension.lowercased()]
    }
}
