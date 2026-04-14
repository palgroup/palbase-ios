# PalbaseStorage

File and image storage — upload, download, signed URLs, image transforms, and
resumable (TUS) uploads.

## Setup

```swift
import PalbaseStorage

Palbase.configure(apiKey: "pb_abc123_xxx")
let storage = try PalbaseStorage.shared
```

All per-bucket operations go through a `BucketRef`:

```swift
let avatars = try storage.bucket("avatars")
```

## Upload & download

```swift
// Upload raw data
let obj = try await avatars.upload(
    path: "me.png",
    data: pngData,
    options: UploadOptions(contentType: "image/png", upsert: true)
)

// Upload a file on disk (Content-Type guessed from extension)
try await avatars.upload(path: "doc.pdf", fileURL: localURL)

// Download
let data = try await avatars.download(path: "me.png")

// Range download (HTTP 206)
let head = try await avatars.download(path: "big.bin", range: 0...4095)
```

## Info, move, copy, remove

```swift
let meta = try await avatars.info(path: "me.png")        // FileObject
try await avatars.move(from: "me.png", to: "profile.png")
try await avatars.copy(from: "profile.png", to: "archive/profile.png")
try await avatars.remove(paths: ["old.png", "older.png"])
```

## List

```swift
let page = try await avatars.list(
    prefix: "folder/",
    options: ListOptions(
        limit: 100,
        offset: 0,
        sortBy: SortBy(column: "created_at", order: .descending)
    )
)
```

## Signed URLs (read)

```swift
let url = try await avatars.createSignedURL(path: "me.png", expiresIn: 3600)

// Batch
let urls = try await avatars.createSignedURLs(
    paths: ["a.png", "b.png", "c.png"],
    expiresIn: 3600
)
// -> [SignedURL(path:, signedURL:)]
```

## Signed upload URLs

```swift
let signed = try await avatars.createSignedUploadURL(path: "me.png", expiresIn: 600)

// Later (possibly from a different device):
try await avatars.uploadToSignedURL(signed, data: pngData)
// Or from a file:
try await avatars.uploadToSignedURL(signed, fileURL: localURL)
```

## Public URLs & image rendering

```swift
// Client-side URL construction (no round trip):
let url = avatars.publicURL(path: "me.png")

// With on-the-fly transform (cdn-rendered):
let thumb = avatars.publicURL(
    path: "me.png",
    transform: TransformOptions(
        width: 200, height: 200,
        resize: .cover,
        format: .webp,
        quality: 80
    )
)

// Server-side render, returns bytes:
let bytes = try await avatars.renderImage(
    path: "me.png",
    transform: TransformOptions(width: 512, height: 512, format: .avif),
    authenticated: true
)
```

## Resumable (TUS) upload

```swift
let upload = avatars.resumableUpload(
    path: "movies/lecture.mp4",
    fileURL: big,
    options: UploadOptions(contentType: "video/mp4", upsert: true)
)

// Observe progress
Task { [weak upload] in
    guard let upload else { return }
    for await tick in await upload.progress {
        print("\(tick.uploadedBytes)/\(tick.totalBytes) \(Int(tick.fraction * 100))%")
    }
}

// Kick it off (returns the final FileObject on success)
let file = try await upload.start()

// Or control mid-flight
await upload.pause()
_ = try await upload.resume()
await upload.cancel()
```

Default chunk size is 5 MB. Each `PATCH` is retried up to 3 times on transient
failure. `pause()` requests a stop at the next chunk boundary; `resume()`
re-syncs the offset from the server with `HEAD` before sending more chunks.

## Public Types

| Type | Purpose |
|------|---------|
| `PalbaseStorage` | Module entry point — `shared`, `bucket(_:)` |
| `BucketRef` | All file operations for a single bucket |
| `FileObject` | Metadata for a stored object |
| `UploadOptions` | `contentType`, `upsert`, `cacheControl`, `metadata` |
| `ListOptions` | `limit`, `offset`, `sortBy`, `search` |
| `SortBy` / `SortOrder` | List sorting |
| `SignedURL` / `SignedUploadURL` | Signed-URL response structures |
| `TransformOptions` | `width`, `height`, `resize`, `format`, `quality` |
| `ResizeMode` | `.cover`, `.contain`, `.fill` |
| `ImageFormat` | `.origin`, `.avif`, `.jpeg`, `.png`, `.webp` |
| `ResumableUpload` | TUS upload actor — `start`, `pause`, `resume`, `cancel`, `progress` |
| `UploadProgress` | `uploadedBytes`, `totalBytes`, `fraction` |
| `UploadStatus` | `.pending`, `.uploading`, `.paused`, `.completed`, `.failed` |

## Errors — `StorageError`

| Case | Meaning |
|------|---------|
| `.notConfigured` | `Palbase.configure` not called |
| `.invalidBucketName(String)` | Bucket name failed `^[a-zA-Z0-9_-]+$` |
| `.invalidPath(String)` | Path failed `^[a-zA-Z0-9_./-]+$`, or contained `..` |
| `.fileNotFound(path:)` | 404 on object operations |
| `.bucketNotFound(name:)` | 404 when the server indicates a missing bucket |
| `.quotaExceeded(message:)` | Tenant/project quota exceeded |
| `.fileTooLarge(maxBytes:)` | 413 Payload Too Large |
| `.invalidContentType(message:)` | Content type rejected |
| `.uploadFailed(message:)` | TUS / multipart upload failed |
| `.uploadCancelled` | Caller invoked `cancel()` |
| `.network(String)` | Transport-level failure |
| `.decoding(String)` | Server response could not be decoded |
| `.rateLimited(retryAfter:)` | 429 |
| `.serverError(status:message:)` | 5xx |
| `.http(status:code:message:requestId:)` | Other non-2xx with envelope |
| `.server(code:message:requestId:)` | Server-shaped error wrapper |

## Limits

- Path length: 1024 characters
- Bucket name: 1..100 characters, `[a-zA-Z0-9_-]`
- Resumable upload chunk: 5 MB default; 3 retries per chunk
- Multipart upload body is built in memory — for files > ~100 MB prefer
  `resumableUpload(path:fileURL:)`

## Out of scope (deferred)

- Vector / iceberg bucket endpoints
- Bucket admin (create/delete bucket)
