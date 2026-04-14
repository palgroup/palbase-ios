import Foundation

/// Hook into the HTTP request pipeline. Modify headers, log, attach signatures, etc.
package protocol RequestInterceptor: Sendable {
    /// Called before each request is dispatched. Modify `request` in place.
    /// Throw to abort the request.
    func intercept(_ request: inout URLRequest) async throws
}
