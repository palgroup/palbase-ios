import Foundation
@_exported import PalbaseCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Errors specific to App Attest enrollment / assertion.
public enum AppAttestError: Error, Sendable, Equatable {
    /// The device cannot perform App Attest (Simulator, no Secure Enclave,
    /// or `DeviceCheck` unavailable on the platform).
    case unsupported(reason: String)
    /// Apple's attestation service or our binding step failed.
    case attestationFailed(reason: String)
    /// The backend rejected enrollment or did not return a challenge.
    case enrollmentFailed(reason: String)
    /// Could not obtain a challenge to bind the assertion to.
    case challengeUnavailable(reason: String)
}

/// Abstracts Apple's `DCAppAttestService` so the flow is unit-testable
/// without a device (tests inject a fake). The real implementation is
/// `DeviceCheckAttestProvider`.
package protocol DeviceAttestProvider: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// Persists the enrolled keyId across launches. The Secure-Enclave private
/// key itself never leaves the device — only its opaque identifier is
/// stored here. Backed by the Keychain in production.
package protocol AttestKeyStore: Sendable {
    func loadKeyId() async -> String?
    func saveKeyId(_ keyId: String) async
    func clear() async
}

/// Client-side App Attest provider. Conforms to `AppAttesting` so the
/// façade can install it on `Palbase` when a project enforces attestation.
///
/// Flow:
///   1. First use → generate a Secure-Enclave key, fetch an enrollment
///      challenge, attest the key with Apple, register keyId+attestation
///      with the backend. Persist keyId.
///   2. Each request → fetch a fresh challenge (anti-replay nonce), bind
///      it to a hash of the request (method + path + body), generate an
///      assertion, and return the headers the backend verifies.
///
/// A `nil` attestor (this type never installed) means enforcement is off.
public actor AppAttestProvider: AppAttesting {
    private let device: DeviceAttestProvider
    private let store: AttestKeyStore
    private let http: HTTPRequesting

    private var enrolledKeyId: String?
    private var didLoadFromStore = false

    /// Paths on the per-tenant gateway the attestor uses. Kept here so the
    /// backend contract is in one place.
    static let challengePath = "/attest/challenge"
    static let enrollPath = "/attest/enroll"

    package init(device: DeviceAttestProvider, store: AttestKeyStore, http: HTTPRequesting) {
        self.device = device
        self.store = store
        self.http = http
    }

    /// Convenience initializer used by the façade in production: real
    /// DeviceCheck + Keychain-backed key store. `package`, not `public`,
    /// because `HTTPRequesting` is a package type — only the façade (in
    /// this package) constructs the provider; apps never touch it.
    package init(http: HTTPRequesting, keychainService: String = "studio.palbase.appattest") {
        self.device = DeviceCheckAttestProvider()
        self.store = KeychainAttestKeyStore(service: keychainService)
        self.http = http
    }

    // MARK: - AppAttesting

    public func assertionHeaders(
        method: String,
        path: String,
        body: Data?
    ) async throws -> [String: String] {
        guard device.isSupported else {
            throw AppAttestError.unsupported(reason: "App Attest is not available on this device.")
        }

        let keyId = try await ensureEnrolled()

        // Bind the assertion to a fresh server challenge AND the request,
        // so a captured assertion can't be replayed against a different
        // request or after the nonce expires.
        let challenge = try await fetchChallenge()
        let clientData = Self.clientData(challenge: challenge, method: method, path: path, body: body)
        let hash = Self.sha256(clientData)

        let assertion: Data
        do {
            assertion = try await device.generateAssertion(keyId, clientDataHash: hash)
        } catch {
            throw AppAttestError.attestationFailed(reason: error.localizedDescription)
        }

        return [
            "X-Palbase-Attest-KeyId": keyId,
            "X-Palbase-Attest-Challenge": challenge,
            "X-Palbase-Attest-Assertion": assertion.base64EncodedString(),
        ]
    }

    // MARK: - Enrollment

    private func ensureEnrolled() async throws -> String {
        if let keyId = enrolledKeyId { return keyId }
        if !didLoadFromStore {
            enrolledKeyId = await store.loadKeyId()
            didLoadFromStore = true
            if let keyId = enrolledKeyId { return keyId }
        }

        // Generate a Secure-Enclave key.
        let keyId: String
        do {
            keyId = try await device.generateKey()
        } catch {
            throw AppAttestError.attestationFailed(reason: "Key generation failed: \(error.localizedDescription)")
        }

        // Attest it against an enrollment challenge and register with the backend.
        let challenge = try await fetchChallenge()
        let clientDataHash = Self.sha256(Data(challenge.utf8))
        let attestation: Data
        do {
            attestation = try await device.attestKey(keyId, clientDataHash: clientDataHash)
        } catch {
            throw AppAttestError.attestationFailed(reason: "Attestation failed: \(error.localizedDescription)")
        }

        try await register(keyId: keyId, challenge: challenge, attestation: attestation)

        enrolledKeyId = keyId
        await store.saveKeyId(keyId)
        return keyId
    }

    private func register(keyId: String, challenge: String, attestation: Data) async throws {
        struct EnrollBody: Encodable, Sendable {
            let keyId: String
            let challenge: String
            let attestation: String
        }
        struct EnrollResponse: Decodable, Sendable {
            let ok: Bool
        }
        do {
            let resp: EnrollResponse = try await http.request(
                method: "POST",
                path: Self.enrollPath,
                body: EnrollBody(keyId: keyId, challenge: challenge, attestation: attestation.base64EncodedString()),
                headers: [:]
            )
            guard resp.ok else {
                throw AppAttestError.enrollmentFailed(reason: "Backend rejected enrollment.")
            }
        } catch let err as AppAttestError {
            throw err
        } catch {
            throw AppAttestError.enrollmentFailed(reason: error.localizedDescription)
        }
    }

    private func fetchChallenge() async throws -> String {
        struct ChallengeResponse: Decodable, Sendable {
            let challenge: String
        }
        do {
            let resp: ChallengeResponse = try await http.request(
                method: "POST",
                path: Self.challengePath,
                body: Optional<EmptyBody>.none,
                headers: [:]
            )
            guard !resp.challenge.isEmpty else {
                throw AppAttestError.challengeUnavailable(reason: "Empty challenge.")
            }
            return resp.challenge
        } catch let err as AppAttestError {
            throw err
        } catch {
            throw AppAttestError.challengeUnavailable(reason: error.localizedDescription)
        }
    }

    // MARK: - Hashing

    /// The bytes the assertion is computed over: a stable concatenation of
    /// the server challenge and a canonical request descriptor. The
    /// backend recomputes this and compares.
    static func clientData(challenge: String, method: String, path: String, body: Data?) -> Data {
        var data = Data()
        data.append(Data(challenge.utf8))
        data.append(Data("|".utf8))
        data.append(Data(method.uppercased().utf8))
        data.append(Data("|".utf8))
        data.append(Data(path.utf8))
        data.append(Data("|".utf8))
        if let body { data.append(Data(Self.sha256(body))) }
        return data
    }

    static func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data))
        #else
        // CryptoKit is available on all Apple platforms the SDK targets.
        fatalError("SHA256 requires CryptoKit")
        #endif
    }
}

struct EmptyBody: Encodable, Sendable {}
