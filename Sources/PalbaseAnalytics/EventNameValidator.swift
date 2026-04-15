import Foundation

/// Event name validation matching the server-side regex:
/// `^[a-zA-Z][a-zA-Z0-9_.:-]{0,64}$`.
///
/// The `$` built-ins (`$identify`, `$screen`, `$pageview`, `$create_alias`) are
/// allowed because they originate inside the SDK and never need user validation.
enum EventNameValidator {
    static let maxLength = 65  // first char + up to 64 more

    static func validate(_ name: String) throws(AnalyticsError) {
        // SDK-internal event names begin with `$` — skip user regex.
        if name.hasPrefix("$") {
            if name.count > maxLength + 1 {
                throw AnalyticsError.invalidEventName(name)
            }
            return
        }

        guard !name.isEmpty, name.count <= maxLength else {
            throw AnalyticsError.invalidEventName(name)
        }

        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, Self.isAlpha(first) else {
            throw AnalyticsError.invalidEventName(name)
        }
        for scalar in scalars.dropFirst() {
            guard Self.isAllowed(scalar) else {
                throw AnalyticsError.invalidEventName(name)
            }
        }
    }

    private static func isAlpha(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 0x41 && s.value <= 0x5A) || (s.value >= 0x61 && s.value <= 0x7A)
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool {
        s.value >= 0x30 && s.value <= 0x39
    }

    private static func isAllowed(_ s: Unicode.Scalar) -> Bool {
        if isAlpha(s) || isDigit(s) { return true }
        switch s {
        case "_", ".", ":", "-": return true
        default: return false
        }
    }
}
