import Foundation
import Testing
@testable import PalbaseFlags

@Suite("FlagsSnapshot decoding")
struct FlagsSnapshotDecodingTests {
    @Test func decodesSnakeCaseFetchedAt() throws {
        let json = #"""
        {
          "values": { "ai_features": true, "max_upload_mb": 100, "dark_mode": false },
          "fetched_at": "2026-04-14T10:30:00Z"
        }
        """#
        let snap = try JSONDecoder().decode(FlagsSnapshot.self, from: Data(json.utf8))
        #expect(snap.values["ai_features"] == .bool(true))
        #expect(snap.values["max_upload_mb"] == .int(100))
        #expect(snap.values["dark_mode"] == .bool(false))
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        #expect(snap.fetchedAt == fmt.date(from: "2026-04-14T10:30:00Z"))
    }

    @Test func decodesFetchedAtWithFractionalSeconds() throws {
        let json = #"""
        {
          "values": {},
          "fetched_at": "2026-04-14T10:30:00.123Z"
        }
        """#
        let snap = try JSONDecoder().decode(FlagsSnapshot.self, from: Data(json.utf8))
        #expect(snap.values.isEmpty)
        #expect(snap.fetchedAt.timeIntervalSince1970 > 0)
    }

    @Test func decodesNestedObjectsAndArraysAndNulls() throws {
        let json = #"""
        {
          "values": {
            "profile": { "theme": "dark", "fontSize": 14 },
            "rollout": [1, 2, 3],
            "experimental": null
          },
          "fetched_at": "2026-04-14T10:30:00Z"
        }
        """#
        let snap = try JSONDecoder().decode(FlagsSnapshot.self, from: Data(json.utf8))
        guard case .object(let obj) = snap.values["profile"] else {
            Issue.record("profile should decode as object"); return
        }
        #expect(obj["theme"] == .string("dark"))
        #expect(obj["fontSize"] == .int(14))
        #expect(snap.values["rollout"] == .array([.int(1), .int(2), .int(3)]))
        #expect(snap.values["experimental"] == .null)
    }

    @Test func preservesOriginalFlagKeyCasing() throws {
        // Key names must NOT be snake_case-converted — they are arbitrary.
        let json = #"""
        { "values": { "darkMode": true, "max_upload_mb": 100 }, "fetched_at": "2026-04-14T10:30:00Z" }
        """#
        let snap = try JSONDecoder().decode(FlagsSnapshot.self, from: Data(json.utf8))
        #expect(snap.values["darkMode"] == .bool(true))
        #expect(snap.values["max_upload_mb"] == .int(100))
    }

    @Test func rejectsInvalidTimestamp() throws {
        let json = #"""
        { "values": {}, "fetched_at": "not-a-date" }
        """#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FlagsSnapshot.self, from: Data(json.utf8))
        }
    }
}
