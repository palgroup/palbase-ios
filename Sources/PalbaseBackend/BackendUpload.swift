import Foundation
@_exported import PalbaseCore

/// A send-progress tick for a backend multipart upload.
public struct BackendUploadProgress: Sendable, Equatable {
    public let sentBytes: Int64
    public let totalBytes: Int64

    public init(sentBytes: Int64, totalBytes: Int64) {
        self.sentBytes = sentBytes
        self.totalBytes = totalBytes
    }

    /// 0.0 … 1.0; 0 when the total is unknown.
    public var fraction: Double {
        totalBytes > 0 ? Double(sentBytes) / Double(totalBytes) : 0
    }
}

/// Constraints a backend `upload` endpoint declares (mirrors the
/// `defineEndpoint({ upload: { maxSize, allowedTypes } })` config). When
/// known — e.g. supplied from the generated client or the OpenAPI doc —
/// the SDK enforces them client-side and refuses an oversize or
/// wrong-type file *before* sending, saving the round-trip.
public struct UploadConstraints: Sendable, Equatable {
    /// Maximum file size in bytes. `nil` = no client-side size check.
    public let maxSize: Int?
    /// Allowed MIME types. Empty = no client-side type check.
    public let allowedTypes: [String]

    public init(maxSize: Int? = nil, allowedTypes: [String] = []) {
        self.maxSize = maxSize
        self.allowedTypes = allowedTypes
    }
}

extension PalbaseBackend {
    /// Upload a file to a backend `defineEndpoint` that declares an
    /// `upload` config, with optional send-progress reporting.
    ///
    /// The file is sent as `multipart/form-data` with the binary under
    /// the `file` part; any `fields` are added as additional typed parts.
    /// The response body is decoded into `O`.
    ///
    /// ```swift
    /// struct PutAvatarOut: Decodable, Sendable { let url: String }
    /// let out: PutAvatarOut = try await PalbaseBackend.shared.upload(
    ///     "avatars.put",
    ///     fileURL: localURL,
    ///     fields: ["caption": "me"]
    /// ) { progress in
    ///     print(progress.fraction)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - name: endpoint operationId (e.g. `avatars.put`).
    ///   - fileURL: local file to upload.
    ///   - filename: name sent in the part; defaults to the URL's last
    ///     component.
    ///   - contentType: MIME type; guessed from the extension when nil.
    ///   - fields: extra string form fields.
    ///   - constraints: optional client-side size/type guard.
    ///   - headers: extra request headers.
    ///   - onProgress: called as bytes are sent (on a background queue).
    @discardableResult
    public func upload<O: Decodable & Sendable>(
        _ name: String,
        fileURL: URL,
        filename: String? = nil,
        contentType: String? = nil,
        fields: [String: String] = [:],
        constraints: UploadConstraints? = nil,
        headers: [String: String] = [:],
        as: O.Type = O.self,
        onProgress: (@Sendable (BackendUploadProgress) -> Void)? = nil
    ) async throws(BackendError) -> O {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw BackendError.transport(message: "Could not read file: \(error.localizedDescription)")
        }
        let name0 = filename ?? fileURL.lastPathComponent
        return try await upload(
            name,
            fileData: data,
            filename: name0,
            contentType: contentType,
            fields: fields,
            constraints: constraints,
            headers: headers,
            as: O.self,
            onProgress: onProgress
        )
    }

    /// In-memory variant of `upload(_:fileURL:...)`.
    @discardableResult
    public func upload<O: Decodable & Sendable>(
        _ name: String,
        fileData: Data,
        filename: String,
        contentType: String? = nil,
        fields: [String: String] = [:],
        constraints: UploadConstraints? = nil,
        headers: [String: String] = [:],
        as: O.Type = O.self,
        onProgress: (@Sendable (BackendUploadProgress) -> Void)? = nil
    ) async throws(BackendError) -> O {
        let resolvedType = contentType
            ?? Self.guessMimeType(forExtension: (filename as NSString).pathExtension)
            ?? "application/octet-stream"

        // Client-side guard: refuse before sending when constraints known.
        if let constraints {
            if let maxSize = constraints.maxSize, fileData.count > maxSize {
                throw BackendError.validation(
                    fields: [FieldError(field: "file", message: "File exceeds maximum size of \(maxSize) bytes.")],
                    requestId: nil
                )
            }
            if !constraints.allowedTypes.isEmpty, !constraints.allowedTypes.contains(resolvedType) {
                throw BackendError.validation(
                    fields: [FieldError(field: "file", message: "Content type \(resolvedType) is not allowed.")],
                    requestId: nil
                )
            }
        }

        let built = BackendMultipart.build(filename: filename, contentType: resolvedType, data: fileData, fields: fields)
        let path = "/rpc/\(name)"

        var reqHeaders = headers
        reqHeaders["Content-Type"] = "multipart/form-data; boundary=\(built.boundary)"
        // Uploads mutate — attach an idempotency key (reused on a caller retry).
        if reqHeaders["Idempotency-Key"] == nil {
            reqHeaders["Idempotency-Key"] = Self.newIdempotencyKey()
        }

        // App Attest binds to the multipart payload when enforced.
        if let attestor {
            do {
                let attestHeaders = try await attestor.assertionHeaders(method: "POST", path: path, body: built.data)
                for (k, v) in attestHeaders { reqHeaders[k] = v }
            } catch let err as BackendError {
                throw err
            } catch {
                throw BackendError.attestationUnavailable(reason: error.localizedDescription)
            }
        }

        let progressBridge: (@Sendable (Int64, Int64) -> Void)?
        if let onProgress {
            progressBridge = { (sent: Int64, total: Int64) in
                onProgress(BackendUploadProgress(sentBytes: sent, totalBytes: total))
            }
        } else {
            progressBridge = nil
        }

        let result: (data: Data, status: Int, headers: [String: String])
        do {
            result = try await http.uploadRawBodyResult(
                method: "POST",
                path: path,
                body: built.data,
                headers: reqHeaders,
                onProgress: progressBridge
            )
        } catch {
            throw BackendError.from(transport: error)
        }

        guard (200..<300).contains(result.status) else {
            let retryAfter = result.headers["Retry-After"].flatMap { Int($0) }
            throw BackendError.from(status: result.status, body: result.data, retryAfter: retryAfter)
        }

        do {
            return try JSONDecoder.palbaseDefault.decode(O.self, from: result.data)
        } catch {
            throw BackendError.decode(message: error.localizedDescription)
        }
    }

    /// Minimal extension→MIME map (Foundation only; no UTI/UniformTypeIdentifiers
    /// so the SDK stays buildable on every platform).
    static func guessMimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "txt": return "text/plain"
        case "csv": return "text/csv"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "zip": return "application/zip"
        default: return nil
        }
    }
}

/// Builds a `multipart/form-data` body: the binary under the `file` part,
/// plus any string `fields`. Matches the convention used by
/// `PalbaseStorage`'s multipart builder.
enum BackendMultipart {
    struct Built {
        let data: Data
        let boundary: String
    }

    static func build(
        filename: String,
        contentType: String,
        data: Data,
        fields: [String: String]
    ) -> Built {
        let boundary = "Palbase-\(UUID().uuidString)"
        let line = "\r\n"
        let safeName = filename.replacingOccurrences(of: "\"", with: "_")

        var body = Data()
        // Deterministic field order so tests and signatures are stable.
        for key in fields.keys.sorted() {
            let value = fields[key] ?? ""
            let safeKey = key.replacingOccurrences(of: "\"", with: "_")
            body.append(Data("--\(boundary)\(line)".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(safeKey)\"\(line)\(line)".utf8))
            body.append(Data("\(value)\(line)".utf8))
        }

        body.append(Data("--\(boundary)\(line)".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\(line)".utf8))
        body.append(Data("Content-Type: \(contentType)\(line)\(line)".utf8))
        body.append(data)
        body.append(Data("\(line)--\(boundary)--\(line)".utf8))

        return Built(data: body, boundary: boundary)
    }
}
