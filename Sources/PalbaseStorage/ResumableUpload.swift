import Foundation
@_exported import PalbaseCore

/// Status of a resumable upload.
public enum UploadStatus: Sendable, Equatable {
    case pending
    case uploading
    case paused
    case completed
    case failed
}

/// Progress tick emitted by ``ResumableUpload/progress``.
public struct UploadProgress: Sendable, Equatable {
    public let uploadedBytes: Int
    public let totalBytes: Int
    public var fraction: Double {
        totalBytes > 0 ? Double(uploadedBytes) / Double(totalBytes) : 0
    }
}

/// TUS resumable upload state machine. Defaults to 5 MB chunks; pause/resume
/// use a HEAD to re-read the server's upload offset.
///
/// > Warning: When iterating `progress`, capture `self` weakly to avoid retain
/// > cycles:
/// > ```swift
/// > for await tick in upload.progress {
/// >     [weak self] in
/// >     self?.render(tick)
/// > }
/// > ```
public actor ResumableUpload {
    // Internal sources the body can come from.
    package enum Source: Sendable {
        case memory(Data)
        case file(URL)
    }

    private static let defaultChunkSize = 5 * 1024 * 1024
    private static let maxChunkRetries = 3

    public let path: String
    public let totalBytes: Int

    private let http: HTTPRequesting
    private let pathPrefix: String
    private let bucket: String
    private let source: Source
    private let options: UploadOptions
    private let chunkSize: Int

    private var _uploadedBytes: Int = 0
    private var _status: UploadStatus = .pending
    private var uploadPath: String? // server-issued upload resource path
    private var continuations: [Int: AsyncStream<UploadProgress>.Continuation] = [:]
    private var continuationCounter: Int = 0
    private var pauseRequested: Bool = false

    package init(
        http: HTTPRequesting,
        pathPrefix: String,
        bucket: String,
        path: String,
        source: Source,
        totalBytes: Int,
        options: UploadOptions,
        chunkSize: Int = ResumableUpload.defaultChunkSize
    ) {
        self.http = http
        self.pathPrefix = pathPrefix
        self.bucket = bucket
        self.path = path
        self.source = source
        self.totalBytes = totalBytes
        self.options = options
        self.chunkSize = chunkSize
    }

    public var uploadedBytes: Int { _uploadedBytes }
    public var status: UploadStatus { _status }

    /// Progress stream; each subscriber gets its own continuation. The stream
    /// finishes when the upload completes, fails, or is cancelled.
    public var progress: AsyncStream<UploadProgress> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                let id = await self.register(continuation: continuation)
                continuation.onTermination = { _ in
                    Task { [weak self] in await self?.unregister(id: id) }
                }
            }
        }
    }

    // MARK: - Public operations

    /// Kick off (or restart after failure) the upload. Returns the final
    /// `FileObject` on success.
    @discardableResult
    public func start() async throws(StorageError) -> FileObject {
        try PathValidator.validatePath(path)
        try PathValidator.validateBucket(bucket)
        _status = .uploading
        pauseRequested = false

        // Create upload resource on server if we don't have one.
        if uploadPath == nil {
            uploadPath = try await createUpload()
        }

        return try await runChunks()
    }

    /// Request pause at the next chunk boundary.
    public func pause() async {
        if _status == .uploading {
            pauseRequested = true
        }
    }

    /// Resume after a pause — re-reads the server's offset then continues.
    @discardableResult
    public func resume() async throws(StorageError) -> FileObject {
        guard let _ = uploadPath else {
            return try await start()
        }
        _status = .uploading
        pauseRequested = false
        // Re-sync offset from server.
        _uploadedBytes = try await fetchOffset()
        return try await runChunks()
    }

    /// Cancel permanently. Informs the server and tears down the stream.
    public func cancel() async {
        if let upload = uploadPath {
            _ = try? await http.requestRawBody(
                method: "DELETE",
                path: upload,
                body: nil,
                headers: tusBaseHeaders()
            )
        }
        _status = .failed
        finishAll()
    }

    // MARK: - Internals

    private func register(continuation: AsyncStream<UploadProgress>.Continuation) -> Int {
        continuationCounter += 1
        let id = continuationCounter
        continuations[id] = continuation
        // Emit current state so subscribers see something even after start.
        continuation.yield(UploadProgress(uploadedBytes: _uploadedBytes, totalBytes: totalBytes))
        return id
    }

    private func unregister(id: Int) {
        continuations.removeValue(forKey: id)
    }

    private func emit(_ tick: UploadProgress) {
        for (_, c) in continuations {
            c.yield(tick)
        }
    }

    private func finishAll() {
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
    }

    private func tusBaseHeaders() -> [String: String] {
        [
            "Tus-Resumable": "1.0.0"
        ]
    }

    private func metadataHeader() -> String {
        // TUS Upload-Metadata: comma-separated "key base64(value)" pairs.
        var pairs: [String] = []
        let bucketName = bucket
        let objectName = path
        let pair1 = "bucketName " + Data(bucketName.utf8).base64EncodedString()
        let pair2 = "objectName " + Data(objectName.utf8).base64EncodedString()
        pairs.append(pair1); pairs.append(pair2)
        if let ct = options.contentType {
            pairs.append("contentType " + Data(ct.utf8).base64EncodedString())
        }
        if let cache = options.cacheControl {
            pairs.append("cacheControl " + Data(cache.utf8).base64EncodedString())
        }
        return pairs.joined(separator: ",")
    }

    private func createUpload() async throws(StorageError) -> String {
        var headers = tusBaseHeaders()
        headers["Upload-Length"] = String(totalBytes)
        headers["Upload-Metadata"] = metadataHeader()
        if options.upsert {
            headers["x-upsert"] = "true"
        }
        let resp: (data: Data, status: Int, headers: [String: String])
        do {
            resp = try await http.requestRawBody(
                method: "POST",
                path: "/upload/resumable",
                body: nil,
                headers: headers
            )
        } catch {
            _status = .failed
            finishAll()
            throw StorageError.from(transport: error)
        }
        // Location may be absolute or relative; strip the scheme/host if present.
        let location = resp.headers["Location"] ?? resp.headers["location"] ?? ""
        guard !location.isEmpty else {
            _status = .failed
            finishAll()
            throw StorageError.uploadFailed(message: "TUS server did not return Location header.")
        }
        if let u = URL(string: location), u.host != nil {
            var p = u.path
            if let q = u.query { p += "?\(q)" }
            return p
        }
        return location
    }

    private func fetchOffset() async throws(StorageError) -> Int {
        guard let upload = uploadPath else { return 0 }
        var headers = tusBaseHeaders()
        headers["accept"] = "*/*"
        let resp: (data: Data, status: Int, headers: [String: String])
        do {
            resp = try await http.requestRawBody(
                method: "HEAD",
                path: upload,
                body: nil,
                headers: headers
            )
        } catch {
            throw StorageError.from(transport: error)
        }
        let raw = resp.headers["Upload-Offset"] ?? resp.headers["upload-offset"] ?? "0"
        return Int(raw) ?? 0
    }

    private func runChunks() async throws(StorageError) -> FileObject {
        guard let upload = uploadPath else {
            _status = .failed; finishAll()
            throw StorageError.uploadFailed(message: "Upload not initialized.")
        }

        while _uploadedBytes < totalBytes {
            if pauseRequested {
                _status = .paused
                emit(UploadProgress(uploadedBytes: _uploadedBytes, totalBytes: totalBytes))
                return try await info() // best-effort; caller will call resume()
            }

            let end = min(_uploadedBytes + chunkSize, totalBytes)
            let chunk = try readChunk(start: _uploadedBytes, end: end)
            let newOffset = try await sendChunk(uploadPath: upload, chunk: chunk, offset: _uploadedBytes)
            _uploadedBytes = newOffset
            emit(UploadProgress(uploadedBytes: _uploadedBytes, totalBytes: totalBytes))
        }

        _status = .completed
        emit(UploadProgress(uploadedBytes: _uploadedBytes, totalBytes: totalBytes))
        finishAll()

        return try await info()
    }

    private func readChunk(start: Int, end: Int) throws(StorageError) -> Data {
        switch source {
        case .memory(let data):
            return data.subdata(in: start..<end)
        case .file(let url):
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(start))
                let data = try handle.read(upToCount: end - start) ?? Data()
                return data
            } catch {
                throw StorageError.uploadFailed(message: "Failed to read chunk: \(error.localizedDescription)")
            }
        }
    }

    private func sendChunk(
        uploadPath: String,
        chunk: Data,
        offset: Int
    ) async throws(StorageError) -> Int {
        var attempt = 0
        var lastError: StorageError?
        while attempt < Self.maxChunkRetries {
            var headers = tusBaseHeaders()
            headers["Upload-Offset"] = String(offset)
            headers["Content-Type"] = "application/offset+octet-stream"
            do {
                let resp = try await http.requestRawBody(
                    method: "PATCH",
                    path: uploadPath,
                    body: chunk,
                    headers: headers
                )
                let newOffsetRaw = resp.headers["Upload-Offset"] ?? resp.headers["upload-offset"]
                let newOffset = newOffsetRaw.flatMap { Int($0) } ?? (offset + chunk.count)
                return newOffset
            } catch {
                let mapped = StorageError.from(transport: error)
                lastError = mapped
                attempt += 1
                if attempt < Self.maxChunkRetries {
                    try? await Task.sleep(nanoseconds: UInt64(200_000_000 * attempt))
                    continue
                }
            }
        }
        _status = .failed
        finishAll()
        throw lastError ?? StorageError.uploadFailed(message: "Chunk upload failed.")
    }

    private func info() async throws(StorageError) -> FileObject {
        let url = "\(pathPrefix)/object/info/authenticated/\(bucket)/\(PathValidator.encodePath(path))"
        let dto: FileObjectDTO
        do {
            dto = try await http.request(method: "GET", path: url, body: nil, headers: [:])
        } catch {
            throw StorageError.from(transport: error)
        }
        return dto.toFileObject()
    }
}
