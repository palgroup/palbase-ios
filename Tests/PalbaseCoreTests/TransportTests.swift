import Testing
import Foundation
@testable import PalbaseCore

// MARK: - URLProtocol mock

/// A URLProtocol that serves scripted responses, optionally after a delay,
/// so tests can drive a real `HttpClient` through `PalbaseConfig.urlSession`
/// (the pattern CLAUDE.md prescribes for HTTP-level tests). Thread-safe
/// because URLProtocol instances are created per-request on arbitrary
/// queues.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: @unchecked Sendable {
        var status: Int = 200
        var body: Data = Data("{}".utf8)
        var headers: [String: String] = [:]
        /// When set, `startLoading` fails the request with this error
        /// immediately instead of delivering a response.
        var failWith: Error? = nil
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _stub = Stub()
    nonisolated(unsafe) private static var _requestCount = 0
    nonisolated(unsafe) private static var _lastBody: Data?

    static func setStub(_ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        _stub = stub
        _requestCount = 0
        _lastBody = nil
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestCount
    }

    static var lastBody: Data? {
        lock.lock(); defer { lock.unlock() }
        return _lastBody
    }

    private static func nextStub(capturing request: URLRequest) -> Stub {
        lock.lock(); defer { lock.unlock() }
        _requestCount += 1
        _lastBody = request.httpBody ?? request.bodyData
        return _stub
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.nextStub(capturing: request)

        // Always deliver synchronously — either an immediate error or an
        // immediate response. No delays, no deferred work: a stub that
        // can't reliably complete is the one way a URLProtocol hangs the
        // whole suite, so we never defer.
        if let failure = stub.failWith {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLProtocol can receive the body as a stream; capture either form.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Helpers

private func makeClient(maxRetries: Int = 3, timeout: TimeInterval = 5) async -> HttpClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: cfg)
    let config = PalbaseConfig(
        apiKey: "pb_abc123_cxxxxxxxxxxxxxxxxxxx",
        urlSession: session,
        requestTimeout: timeout,
        maxRetries: maxRetries,
        initialBackoffMs: 10
    )
    let tokens = TokenManager()
    // HttpClient's pre-flight refresh awaits `waitUntilReady()`, which
    // only returns after boot is marked complete. In production
    // `Palbase.configure` does this; here we must do it ourselves or the
    // first request suspends forever.
    await tokens.markBootComplete()
    return HttpClient(config: config, tokens: tokens)
}

// MARK: - Tests

/// All transport tests share a single global `StubURLProtocol` (URLSession
/// instantiates the protocol, so per-test state can only live in statics).
/// They must therefore run **serially** — `.serialized` keeps one test's
/// stub from racing another's. Combined into one suite so serialization
/// spans every transport test, not just those in one struct.
@Suite("HttpClient transport", .serialized)
struct TransportTests {
    @Test("non-2xx is returned, not thrown")
    func nonThrowingOnError() async throws {
        StubURLProtocol.setStub(.init(status: 404, body: Data(#"{"error":"x"}"#.utf8)))
        let client = await makeClient()
        let result = try await client.requestRawBodyResult(method: "POST", path: "/backend/x", body: Data("{}".utf8), headers: ["Content-Type": "application/json"])
        #expect(result.status == 404)
        #expect(String(data: result.data, encoding: .utf8)?.contains("\"error\"") == true)
    }

    @Test("Retry-After header is preserved")
    func retryAfterPreserved() async throws {
        StubURLProtocol.setStub(.init(status: 503, body: Data("{}".utf8), headers: ["Retry-After": "7"]))
        let client = await makeClient(maxRetries: 1)
        let result = try await client.requestRawBodyResult(method: "POST", path: "/backend/x", body: Data("{}".utf8), headers: [:])
        #expect(result.status == 503)
        #expect(result.headers["Retry-After"] == "7")
    }

    @Test("raw body bytes are sent verbatim")
    func bodyVerbatim() async throws {
        StubURLProtocol.setStub(.init(status: 200))
        let client = await makeClient()
        let payload = Data(#"{"items":["a","b"]}"#.utf8)
        _ = try await client.requestRawBodyResult(method: "POST", path: "/backend/checkout", body: payload, headers: ["Content-Type": "application/json"])
        #expect(StubURLProtocol.lastBody == payload)
    }

    /// Verifies retry-suppression deterministically: a `.cancelled`
    /// transport error must surface immediately, never retried. The stub
    /// fails every attempt with `.cancelled`; a wrongly-retrying loop
    /// would push the request count past 1. This isolates the cancellation
    /// guard in `executeResult` from the timing of real `Task.cancel()`,
    /// which can't be made reliable against a custom URLProtocol without
    /// risking a hung test.
    @Test("a .cancelled transport error is not retried")
    func cancellationNotRetried() async {
        StubURLProtocol.setStub(.init(failWith: URLError(.cancelled)))
        let client = await makeClient(maxRetries: 3)

        var threw = false
        do {
            _ = try await client.requestRawBodyResult(method: "POST", path: "/backend/slow", body: Data("{}".utf8), headers: [:])
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(StubURLProtocol.requestCount == 1)
    }

    @Test("a genuine network error IS retried up to maxRetries")
    func networkErrorIsRetried() async {
        StubURLProtocol.setStub(.init(failWith: URLError(.networkConnectionLost)))
        let client = await makeClient(maxRetries: 3)

        var threw = false
        do {
            _ = try await client.requestRawBodyResult(method: "POST", path: "/backend/x", body: Data("{}".utf8), headers: [:])
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(StubURLProtocol.requestCount == 3)
    }
}
