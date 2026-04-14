import Foundation

/// Image resize strategy, mirrors the server's `resize` parameter.
public enum ResizeMode: String, Sendable {
    case cover
    case contain
    case fill
}

/// Output image format.
public enum ImageFormat: String, Sendable {
    case origin
    case avif
    case jpeg
    case png
    case webp
}

/// Transformation parameters accepted by the storage image renderer.
public struct TransformOptions: Sendable, Equatable {
    public var width: Int?
    public var height: Int?
    public var resize: ResizeMode?
    public var format: ImageFormat?
    public var quality: Int?

    public init(
        width: Int? = nil,
        height: Int? = nil,
        resize: ResizeMode? = nil,
        format: ImageFormat? = nil,
        quality: Int? = nil
    ) {
        self.width = width
        self.height = height
        self.resize = resize
        self.format = format
        self.quality = quality
    }

    /// Build the query items in stable order for URL construction.
    func queryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let width { items.append(URLQueryItem(name: "width", value: String(width))) }
        if let height { items.append(URLQueryItem(name: "height", value: String(height))) }
        if let resize { items.append(URLQueryItem(name: "resize", value: resize.rawValue)) }
        if let format { items.append(URLQueryItem(name: "format", value: format.rawValue)) }
        if let quality { items.append(URLQueryItem(name: "quality", value: String(quality))) }
        return items
    }
}
