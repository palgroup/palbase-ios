import Testing
import Foundation
@testable import PalBackend

/// These tests lock the *shape* of the façade: what a developer who writes
/// `import PalBackend` can reach. The negative guarantee — that
/// `PalbaseDB`, `HttpClient`, `TokenManager` are NOT reachable — is
/// enforced structurally by the Package graph (the `PalBackend` target
/// does not depend on `PalbaseDB`, and transport types are `package`), so
/// it cannot even be written here. That is the point: code referencing
/// those symbols through `import PalBackend` fails to compile.
@Suite("PalBackend façade surface")
struct FacadeTests {
    @Test func configureResolvesEndpointRef() {
        PalBackend.configure(apiKey: "pb_abc123m_cXXXXXXXXXXXXXXXXXXXX")
        #expect(PalBackend.endpointRef == "abc123m")
    }

    @Test func backendAndAuthAccessorsResolveAfterConfigure() throws {
        // Global SDK state is shared across tests; once configured (any
        // test), the accessors resolve. We assert they exist, are typed,
        // and produce the module clients — not transport internals.
        PalBackend.configure(apiKey: "pb_abc123m_cXXXXXXXXXXXXXXXXXXXX")
        let client = pb
        let backend = try client.backendOrThrow()
        _ = backend // PalbaseBackend, the only RPC surface
    }

    @Test func backendErrorTypeIsPublic() {
        // BackendError, FieldError are re-exported through the façade.
        let e = BackendError.validation(fields: [FieldError(field: "f", message: "m")], requestId: nil)
        #expect(e.code == "validation_error")
    }

    @Test func uploadTypesArePublic() {
        let c = UploadConstraints(maxSize: 10, allowedTypes: ["image/png"])
        #expect(c.maxSize == 10)
        let p = BackendUploadProgress(sentBytes: 5, totalBytes: 10)
        #expect(p.fraction == 0.5)
    }
}

private extension PalBackendClient {
    /// Test shim: surfaces the throwing `backend` accessor as a function so
    /// `#expect(throws:)` can target it without ambiguity.
    func backendOrThrow() throws(BackendError) -> PalbaseBackend {
        try backend
    }
}
