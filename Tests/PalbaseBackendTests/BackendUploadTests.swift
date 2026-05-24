import Testing
import Foundation
@testable import PalbaseBackend

struct UploadOut: Decodable, Sendable, Equatable { let url: String }

/// Collects progress ticks for assertions.
actor ProgressLog {
    private(set) var ticks: [BackendUploadProgress] = []
    func append(_ p: BackendUploadProgress) { ticks.append(p) }
    func all() -> [BackendUploadProgress] { ticks }
}

@Suite("Multipart upload")
struct UploadTests {
    private func backend(_ recorder: RecordedCall, _ responder: @escaping @Sendable (Int) -> StubResponse) -> PalbaseBackend {
        PalbaseBackend(http: MockBackendHTTP(recorder: recorder, responder: responder), tokens: TokenManager())
    }

    @Test func buildsMultipartWithFileAndFields() async throws {
        let recorder = RecordedCall()
        let be = backend(recorder, { _ in StubResponse(status: 200, body: Data(#"{"url":"u"}"#.utf8)) })

        let out: UploadOut = try await be.upload(
            "avatars.put",
            fileData: Data("PNGDATA".utf8),
            filename: "me.png",
            fields: ["caption": "hello"]
        )
        #expect(out == UploadOut(url: "u"))

        let snap = await recorder.snapshot()
        #expect(snap.method == "POST")
        #expect(snap.path == "/rpc/avatars.put")
        #expect(snap.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(snap.headers["Idempotency-Key"] != nil)

        let bodyStr = snap.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(bodyStr.contains(#"name="file"; filename="me.png""#))
        #expect(bodyStr.contains("Content-Type: image/png"))
        #expect(bodyStr.contains(#"name="caption""#))
        #expect(bodyStr.contains("hello"))
        #expect(bodyStr.contains("PNGDATA"))
    }

    @Test func reportsProgress() async throws {
        let recorder = RecordedCall()
        let be = backend(recorder, { _ in StubResponse(status: 200, body: Data(#"{"url":"u"}"#.utf8)) })
        let log = ProgressLog()

        let _: UploadOut = try await be.upload(
            "avatars.put",
            fileData: Data(repeating: 0, count: 100),
            filename: "f.bin",
            onProgress: { p in Task { await log.append(p) } }
        )
        // Allow the detached append tasks to land.
        try await Task.sleep(nanoseconds: 50_000_000)
        let ticks = await log.all()
        #expect(ticks.count == 2)
        #expect(ticks.last?.fraction == 1.0)
    }

    @Test func refusesOversizeBeforeSending() async {
        let recorder = RecordedCall()
        let be = backend(recorder, { _ in StubResponse(status: 200) })
        do {
            let _: UploadOut = try await be.upload(
                "avatars.put",
                fileData: Data(repeating: 0, count: 1000),
                filename: "big.png",
                constraints: UploadConstraints(maxSize: 100)
            )
            Issue.record("expected throw")
        } catch let error as BackendError {
            guard case .validation(let fields, _) = error else {
                Issue.record("expected .validation, got \(error)"); return
            }
            #expect(fields.first?.field == "file")
        } catch {
            Issue.record("unexpected error")
        }
        // Nothing should have been sent.
        let snap = await recorder.snapshot()
        #expect(snap.count == 0)
    }

    @Test func refusesDisallowedTypeBeforeSending() async {
        let recorder = RecordedCall()
        let be = backend(recorder, { _ in StubResponse(status: 200) })
        do {
            let _: UploadOut = try await be.upload(
                "avatars.put",
                fileData: Data("x".utf8),
                filename: "doc.pdf",
                constraints: UploadConstraints(allowedTypes: ["image/png"])
            )
            Issue.record("expected throw")
        } catch let error as BackendError {
            guard case .validation = error else { Issue.record("expected .validation, got \(error)"); return }
        } catch {
            Issue.record("unexpected error")
        }
        let snap = await recorder.snapshot()
        #expect(snap.count == 0)
    }

    @Test func mimeGuessing() {
        #expect(PalbaseBackend.guessMimeType(forExtension: "png") == "image/png")
        #expect(PalbaseBackend.guessMimeType(forExtension: "JPEG") == "image/jpeg")
        #expect(PalbaseBackend.guessMimeType(forExtension: "unknown") == nil)
    }
}
