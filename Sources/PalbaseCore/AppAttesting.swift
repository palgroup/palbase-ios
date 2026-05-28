import Foundation

/// Abstraction over App Attest, kept in Core so the wiring
/// (`Palbase.configure`) and the consumer (`PalbaseBackend`) can reference
/// an attestor without importing the concrete `DCAppAttestService`-backed
/// implementation — which lives in its own module and is only available
/// on devices.
///
/// When a project enforces App Attest, the SDK attaches a fresh assertion
/// to every backend RPC proving the request came from a genuine instance
/// of the app on real Apple hardware. A `nil` attestor means enforcement
/// is off — the all-or-nothing flag is modeled by the *presence* of an
/// attestor, not a boolean inside it.
package protocol AppAttesting: Sendable {
    /// Produce the headers to attach to a request, generating (and, on
    /// first use, enrolling) an App Attest assertion bound to the given
    /// request. Throws when the device cannot attest (Simulator, missing
    /// Secure Enclave) or enrollment fails.
    ///
    /// - Parameters:
    ///   - method: HTTP method of the outgoing request.
    ///   - path: request path (e.g. `/checkout`).
    ///   - body: request body bytes, if any, so the assertion can bind to
    ///     the payload hash.
    /// - Returns: headers to merge into the request
    ///   (`X-Palbase-Attest-KeyId`, `X-Palbase-Attest-Assertion`, …).
    func assertionHeaders(
        method: String,
        path: String,
        body: Data?
    ) async throws -> [String: String]
}
