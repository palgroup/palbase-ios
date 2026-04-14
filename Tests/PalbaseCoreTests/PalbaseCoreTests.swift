import XCTest
@testable import PalbaseCore

final class PalbaseCoreTests: XCTestCase {
    func testParseProjectRef_validKey() {
        XCTAssertEqual(HttpClient.parseProjectRef(from: "pb_abc123_xxxxxxxxxxx"), "abc123")
    }

    func testParseProjectRef_invalidKey() {
        XCTAssertNil(HttpClient.parseProjectRef(from: "invalid"))
        XCTAssertNil(HttpClient.parseProjectRef(from: "pb_"))
        XCTAssertNil(HttpClient.parseProjectRef(from: "pk_abc_xxx"))
    }

    func testPalbaseError_equatable() {
        let a = PalbaseError(code: "x", message: "y")
        let b = PalbaseError(code: "x", message: "y")
        XCTAssertEqual(a, b)
    }

    func testSession_isExpired() {
        let expired = Session(accessToken: "a", refreshToken: "b", expiresAt: 0)
        XCTAssertTrue(expired.isExpired)

        let valid = Session(accessToken: "a", refreshToken: "b", expiresAt: Int64(Date().timeIntervalSince1970) + 3600)
        XCTAssertFalse(valid.isExpired)
    }

    func testTokenManager_setClearSession() async {
        let tm = TokenManager()
        let session = Session(accessToken: "a", refreshToken: "r", expiresAt: Int64(Date().timeIntervalSince1970) + 3600)

        await tm.setSession(session)
        let stored = await tm.accessToken
        XCTAssertEqual(stored, "a")

        await tm.clearSession()
        let cleared = await tm.accessToken
        XCTAssertNil(cleared)
    }
}
