import Foundation

/// Merged snapshot of user-scoped feature flags as returned by
/// `GET /v1/user-flags`. `values` is the user's effective flag state after
/// system defaults and user overrides are merged server-side.
public struct FlagsSnapshot: Sendable, Codable, Equatable {
    public let values: [String: FlagValue]
    public let fetchedAt: Date

    package init(values: [String: FlagValue], fetchedAt: Date) {
        self.values = values
        self.fetchedAt = fetchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case values
        case fetchedAt = "fetched_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.values = try c.decodeIfPresent([String: FlagValue].self, forKey: .values) ?? [:]
        let raw = try c.decode(String.self, forKey: .fetchedAt)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: raw) {
            self.fetchedAt = d
        } else {
            let fmt2 = ISO8601DateFormatter()
            fmt2.formatOptions = [.withInternetDateTime]
            guard let d = fmt2.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .fetchedAt,
                    in: c,
                    debugDescription: "Invalid ISO8601 timestamp: \(raw)"
                )
            }
            self.fetchedAt = d
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(values, forKey: .values)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try c.encode(fmt.string(from: fetchedAt), forKey: .fetchedAt)
    }
}
