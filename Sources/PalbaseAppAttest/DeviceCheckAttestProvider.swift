import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Real `DCAppAttestService`-backed provider. Wraps the completion-handler
/// DeviceCheck API in async. Reports `isSupported == false` on platforms
/// or devices where App Attest is unavailable (Simulator, macOS without
/// the entitlement, older hardware), so the caller degrades cleanly.
package struct DeviceCheckAttestProvider: DeviceAttestProvider {
    package init() {}

    package var isSupported: Bool {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, tvOS 15.0, macOS 11.0, *) {
            return DCAppAttestService.shared.isSupported
        }
        return false
        #else
        return false
        #endif
    }

    package func generateKey() async throws -> String {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, tvOS 15.0, macOS 11.0, *) {
            return try await withCheckedThrowingContinuation { cont in
                DCAppAttestService.shared.generateKey { keyId, error in
                    if let error { cont.resume(throwing: error); return }
                    guard let keyId else {
                        cont.resume(throwing: AppAttestError.attestationFailed(reason: "nil keyId"))
                        return
                    }
                    cont.resume(returning: keyId)
                }
            }
        }
        #endif
        throw AppAttestError.unsupported(reason: "DeviceCheck unavailable")
    }

    package func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, tvOS 15.0, macOS 11.0, *) {
            return try await withCheckedThrowingContinuation { cont in
                DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) { attestation, error in
                    if let error { cont.resume(throwing: error); return }
                    guard let attestation else {
                        cont.resume(throwing: AppAttestError.attestationFailed(reason: "nil attestation"))
                        return
                    }
                    cont.resume(returning: attestation)
                }
            }
        }
        #endif
        throw AppAttestError.unsupported(reason: "DeviceCheck unavailable")
    }

    package func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, tvOS 15.0, macOS 11.0, *) {
            return try await withCheckedThrowingContinuation { cont in
                DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) { assertion, error in
                    if let error { cont.resume(throwing: error); return }
                    guard let assertion else {
                        cont.resume(throwing: AppAttestError.attestationFailed(reason: "nil assertion"))
                        return
                    }
                    cont.resume(returning: assertion)
                }
            }
        }
        #endif
        throw AppAttestError.unsupported(reason: "DeviceCheck unavailable")
    }
}

/// Keychain-backed key-id store. Stores only the opaque keyId; the private
/// key stays in the Secure Enclave. Uses a generic-password item keyed by
/// `service`.
package struct KeychainAttestKeyStore: AttestKeyStore {
    private let service: String
    private let account = "app-attest-key-id"

    package init(service: String) {
        self.service = service
    }

    package func loadKeyId() async -> String? {
        var query: [String: Any] = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    package func saveKeyId(_ keyId: String) async {
        let data = Data(keyId.utf8)
        var query = baseQuery()
        // Replace any existing value.
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    package func clear() async {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
