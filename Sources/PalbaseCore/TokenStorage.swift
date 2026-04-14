import Foundation
import Security

/// Persists `Session` across app launches. Internal to the SDK — users do not configure this.
package protocol TokenStorage: Sendable {
    func load() async -> Session?
    func save(_ session: Session) async
    func clear() async
}

/// In-memory storage. Used when Keychain is unavailable (rare) or in tests.
package actor InMemoryTokenStorage: TokenStorage {
    private var session: Session?

    package init() {}

    package func load() async -> Session? { session }
    package func save(_ session: Session) async { self.session = session }
    package func clear() async { self.session = nil }
}

/// Keychain-backed storage. Default for production. Survives app reinstalls
/// (depending on iCloud Keychain) and is encrypted at rest by iOS.
package actor KeychainTokenStorage: TokenStorage {
    private let service: String
    private let account: String

    package init(service: String = "io.palbase.sdk", account: String = "session") {
        self.service = service
        self.account = account
    }

    package func load() async -> Session? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(Session.self, from: data)
    }

    package func save(_ session: Session) async {
        guard let data = try? JSONEncoder().encode(session) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Try update first
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            // Not found → add
            var addQuery = query
            for (k, v) in attrs { addQuery[k] = v }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    package func clear() async {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
