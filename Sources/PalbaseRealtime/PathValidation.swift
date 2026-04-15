import Foundation

enum ChannelNameValidator {
    static let regex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^[a-zA-Z0-9_\\-:]+$")
    }()

    static func validate(_ name: String) throws(RealtimeError) {
        guard !name.isEmpty, name.count <= 255 else {
            throw RealtimeError.invalidChannelName(name)
        }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard regex.firstMatch(in: name, range: range) != nil else {
            throw RealtimeError.invalidChannelName(name)
        }
    }
}
