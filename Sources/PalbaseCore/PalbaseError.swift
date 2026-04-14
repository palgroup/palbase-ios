import Foundation

public struct PalbaseError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let status: Int
    public let details: String?
    public let requestId: String?

    public init(
        code: String,
        message: String,
        status: Int = 0,
        details: String? = nil,
        requestId: String? = nil
    ) {
        self.code = code
        self.message = message
        self.status = status
        self.details = details
        self.requestId = requestId
    }
}

extension PalbaseError: LocalizedError {
    public var errorDescription: String? { message }
}

extension PalbaseError {
    public static let networkError = PalbaseError(
        code: "network_error",
        message: "Network request failed"
    )

    public static let invalidResponse = PalbaseError(
        code: "invalid_response",
        message: "Invalid server response"
    )

    public static let timeout = PalbaseError(
        code: "timeout",
        message: "Request timed out"
    )
}
