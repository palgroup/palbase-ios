import Foundation

extension JSONDecoder {
    /// Pre-configured decoder used by the SDK. Converts snake_case → camelCase automatically,
    /// so DTOs don't need explicit `CodingKeys` for casing.
    package static let palbaseDefault: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    /// Pre-configured encoder used by the SDK. Converts camelCase → snake_case automatically.
    package static let palbaseDefault: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
