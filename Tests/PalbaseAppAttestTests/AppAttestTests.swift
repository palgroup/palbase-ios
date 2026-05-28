import Testing
import Foundation
@testable import PalbaseAppAttest

// MARK: - Fakes

actor CallLog {
    private(set) var paths: [String] = []
    private(set) var enrollBodies: [Data] = []
    func record(path: String, body: Data?) {
        paths.append(path)
        if path.hasSuffix("/enroll"), let body { enrollBodies.append(body) }
    }
    func all() -> [String] { paths }
}

/// Mock HTTP that answers the challenge + enroll endpoints.
struct AttestMockHTTP: HTTPRequesting {
    let log: CallLog
    let challenge: String
    let enrollOK: Bool

    func request<T: Decodable & Sendable>(
        method: String, path: String, body: (any Encodable & Sendable)?, headers: [String: String]
    ) async throws(PalbaseCoreError) -> T {
        let bodyData: Data? = body.flatMap { try? JSONEncoder.palbaseDefault.encode(RawEnc($0)) }
        await log.record(path: path, body: bodyData)
        let json: String
        if path.hasSuffix("/challenge") {
            json = "{\"challenge\":\"\(challenge)\"}"
        } else if path.hasSuffix("/enroll") {
            json = "{\"ok\":\(enrollOK)}"
        } else {
            json = "{}"
        }
        do {
            return try JSONDecoder.palbaseDefault.decode(T.self, from: Data(json.utf8))
        } catch {
            throw PalbaseCoreError.decoding(message: error.localizedDescription)
        }
    }

    func requestVoid(method: String, path: String, body: (any Encodable & Sendable)?, headers: [String: String]) async throws(PalbaseCoreError) {}
    func requestRaw(method: String, path: String, body: (any Encodable & Sendable)?, headers: [String: String]) async throws(PalbaseCoreError) -> (data: Data, status: Int) { (Data(), 200) }
}

struct RawEnc: Encodable {
    let fn: (Encoder) throws -> Void
    init(_ w: any Encodable) { fn = w.encode }
    func encode(to encoder: Encoder) throws { try fn(encoder) }
}

/// Fake device that simulates Secure Enclave behavior deterministically.
/// An `actor` so its counters stay safe across the async protocol calls
/// without using a lock from an async context.
actor FakeDevice: DeviceAttestProvider {
    let supported: Bool
    private(set) var keyGenCount = 0
    private(set) var assertionCount = 0

    init(supported: Bool = true) { self.supported = supported }

    nonisolated var isSupported: Bool { supported }

    func generateKey() async throws -> String {
        keyGenCount += 1
        return "key-\(keyGenCount)"
    }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        Data("attestation-for-\(keyId)".utf8)
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        assertionCount += 1
        // Bind to the hash so different requests yield different assertions.
        return Data("assert-\(keyId)-".utf8) + clientDataHash
    }
}

actor MemKeyStore: AttestKeyStore {
    private var keyId: String?
    func loadKeyId() async -> String? { keyId }
    func saveKeyId(_ keyId: String) async { self.keyId = keyId }
    func clear() async { keyId = nil }
}

// MARK: - Tests

@Suite("App Attest enrollment + assertion")
struct AppAttestTests {
    @Test func enrollsOnceThenAssertsPerRequest() async throws {
        let log = CallLog()
        let device = FakeDevice(supported: true)
        let store = MemKeyStore()
        let http = AttestMockHTTP(log: log, challenge: "chal-123", enrollOK: true)
        let provider = AppAttestProvider(device: device, store: store, http: http)

        let h1 = try await provider.assertionHeaders(method: "POST", path: "/checkout", body: Data("{}".utf8))
        #expect(h1["X-Palbase-Attest-KeyId"] == "key-1")
        #expect(h1["X-Palbase-Attest-Assertion"] != nil)
        #expect(h1["X-Palbase-Attest-Challenge"] == "chal-123")

        let h2 = try await provider.assertionHeaders(method: "POST", path: "/other", body: Data("{}".utf8))
        #expect(h2["X-Palbase-Attest-KeyId"] == "key-1") // same enrolled key

        // Key generated once; assertion generated per call.
        #expect(await device.keyGenCount == 1)
        #expect(await device.assertionCount == 2)

        let paths = await log.all()
        // enroll happens once (during first ensureEnrolled); challenge per call + one for enroll.
        #expect(paths.contains("/attest/enroll"))
        #expect(paths.filter { $0 == "/attest/enroll" }.count == 1)
    }

    @Test func reusesPersistedKeyWithoutReenrolling() async throws {
        let log = CallLog()
        let device = FakeDevice(supported: true)
        let store = MemKeyStore()
        await store.saveKeyId("pre-enrolled-key")
        let http = AttestMockHTTP(log: log, challenge: "c", enrollOK: true)
        let provider = AppAttestProvider(device: device, store: store, http: http)

        let h = try await provider.assertionHeaders(method: "POST", path: "/x", body: nil)
        #expect(h["X-Palbase-Attest-KeyId"] == "pre-enrolled-key")
        #expect(await device.keyGenCount == 0)
        let paths = await log.all()
        #expect(!paths.contains("/attest/enroll")) // no enrollment needed
    }

    @Test func unsupportedDeviceThrows() async {
        let log = CallLog()
        let device = FakeDevice(supported: false)
        let store = MemKeyStore()
        let http = AttestMockHTTP(log: log, challenge: "c", enrollOK: true)
        let provider = AppAttestProvider(device: device, store: store, http: http)

        await #expect(throws: AppAttestError.self) {
            _ = try await provider.assertionHeaders(method: "POST", path: "/x", body: nil)
        }
    }

    @Test func enrollmentRejectionThrows() async {
        let log = CallLog()
        let device = FakeDevice(supported: true)
        let store = MemKeyStore()
        let http = AttestMockHTTP(log: log, challenge: "c", enrollOK: false)
        let provider = AppAttestProvider(device: device, store: store, http: http)

        await #expect(throws: AppAttestError.self) {
            _ = try await provider.assertionHeaders(method: "POST", path: "/x", body: nil)
        }
    }

    @Test func clientDataBindsRequest() {
        let a = AppAttestProvider.clientData(challenge: "c", method: "POST", path: "/a", body: Data("1".utf8))
        let b = AppAttestProvider.clientData(challenge: "c", method: "POST", path: "/b", body: Data("1".utf8))
        let c = AppAttestProvider.clientData(challenge: "c2", method: "POST", path: "/a", body: Data("1".utf8))
        #expect(a != b) // different path
        #expect(a != c) // different challenge
    }
}
