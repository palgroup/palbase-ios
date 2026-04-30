import Foundation
import Testing
@testable import PalbaseBackend

@Suite("BackendEnvironment")
struct BackendEnvironmentTests {

    @Test("`.localhost` resolves to http://localhost:4003")
    func localhostShortcut() {
        guard case .custom(let url) = BackendEnvironment.localhost else {
            Issue.record("expected .custom(URL)")
            return
        }
        #expect(url.absoluteString == "http://localhost:4003")
    }

    @Test("`.custom` round-trips the URL")
    func customRoundTrip() {
        let url = URL(string: "http://192.168.1.42:4003")!
        guard case .custom(let got) = BackendEnvironment.custom(url) else {
            Issue.record("expected .custom(URL)")
            return
        }
        #expect(got == url)
    }

    #if DEBUG
    @Test("`.autoDiscover(.remote)` is reachable in DEBUG builds")
    func autoDiscoverDebugOnly() {
        let env = BackendEnvironment.autoDiscover(fallback: .remote)
        guard case .autoDiscover(let fallback) = env else {
            Issue.record("expected .autoDiscover")
            return
        }
        guard case .remote = fallback else {
            Issue.record("expected fallback=.remote")
            return
        }
    }
    #endif
}
