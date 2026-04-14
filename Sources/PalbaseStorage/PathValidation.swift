import Foundation

enum PathValidator {
    static let bucketRegex: NSRegularExpression = {
        // Require explicit no-newline in source; force-try is safe — the literal is fixed.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^[a-zA-Z0-9_\\-]+$")
    }()

    static let pathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^[a-zA-Z0-9_./\\-]+$")
    }()

    static func validateBucket(_ name: String) throws(StorageError) {
        guard !name.isEmpty, name.count <= 100 else {
            throw StorageError.invalidBucketName(name)
        }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard bucketRegex.firstMatch(in: name, range: range) != nil else {
            throw StorageError.invalidBucketName(name)
        }
    }

    static func validatePath(_ path: String) throws(StorageError) {
        guard !path.isEmpty, path.count <= 1024 else {
            throw StorageError.invalidPath(path)
        }
        // Forbid traversal segments.
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        for segment in segments {
            if segment == ".." {
                throw StorageError.invalidPath(path)
            }
        }
        // No leading/trailing slash — must be a relative object key.
        if path.hasPrefix("/") || path.hasSuffix("/") {
            throw StorageError.invalidPath(path)
        }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        guard pathRegex.firstMatch(in: path, range: range) != nil else {
            throw StorageError.invalidPath(path)
        }
    }

    /// Percent-encode an object path for inclusion in a URL (preserves `/`).
    static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}
