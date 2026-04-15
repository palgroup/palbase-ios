import Foundation
import Testing
@testable import PalbaseFlags

@Suite("FlagValue — literal conformances")
struct FlagValueLiteralTests {
    @Test func boolLiteral() {
        let v: FlagValue = true
        #expect(v == .bool(true))
    }

    @Test func intLiteral() {
        let v: FlagValue = 42
        #expect(v == .int(42))
    }

    @Test func doubleLiteral() {
        let v: FlagValue = 9.99
        #expect(v == .double(9.99))
    }

    @Test func stringLiteral() {
        let v: FlagValue = "hello"
        #expect(v == .string("hello"))
    }

    @Test func nilLiteral() {
        let v: FlagValue = nil
        #expect(v == .null)
    }

    @Test func arrayLiteral() {
        let v: FlagValue = [1, "a", true]
        if case .array(let arr) = v {
            #expect(arr.count == 3)
            #expect(arr[0] == .int(1))
            #expect(arr[1] == .string("a"))
            #expect(arr[2] == .bool(true))
        } else { Issue.record("expected array") }
    }

    @Test func dictionaryLiteral() {
        let v: FlagValue = ["k": 1, "s": "x"]
        if case .object(let obj) = v {
            #expect(obj["k"] == .int(1))
            #expect(obj["s"] == .string("x"))
        } else { Issue.record("expected object") }
    }
}

@Suite("FlagValue — typed accessors")
struct FlagValueAccessorTests {
    @Test func boolValueMatches() {
        let v: FlagValue = .bool(true)
        #expect(v.boolValue == true)
        #expect(v.intValue == nil)
        #expect(v.stringValue == nil)
    }

    @Test func intValueCoversBothIntAndDouble() {
        let i: FlagValue = .int(7)
        #expect(i.intValue == 7)

        let d: FlagValue = .double(12.0)
        #expect(d.intValue == 12)
        #expect(d.doubleValue == 12.0)

        let s: FlagValue = .string("nope")
        #expect(s.intValue == nil)
    }

    @Test func doubleValueCoversBothIntAndDouble() {
        let i: FlagValue = .int(3)
        #expect(i.doubleValue == 3.0)

        let d: FlagValue = .double(3.14)
        #expect(d.doubleValue == 3.14)
    }

    @Test func objectAndArrayAccessors() {
        let o: FlagValue = ["k": 1]
        #expect(o.objectValue?["k"] == .int(1))
        #expect(o.arrayValue == nil)

        let a: FlagValue = [1, 2]
        #expect(a.arrayValue?.count == 2)
        #expect(a.objectValue == nil)
    }

    @Test func isNullFlag() {
        let n: FlagValue = .null
        #expect(n.isNull)
        let s: FlagValue = .string("x")
        #expect(!s.isNull)
    }
}

@Suite("FlagValue — Codable roundtrip")
struct FlagValueCodableTests {
    @Test func roundTripPrimitives() throws {
        let cases: [FlagValue] = [
            .bool(true), .bool(false),
            .int(0), .int(-5), .int(1_000_000),
            .double(3.14),
            .string(""), .string("hello"),
            .null
        ]
        for original in cases {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(FlagValue.self, from: data)
            #expect(decoded == original)
        }
    }

    @Test func roundTripObject() throws {
        let original: FlagValue = ["a": 1, "b": "x", "c": [true, false]]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FlagValue.self, from: data)
        #expect(decoded == original)
    }

    @Test func roundTripArrayOfMixedTypes() throws {
        let original: FlagValue = [.int(1), .string("two"), .bool(true), .null, ["k": 2]]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FlagValue.self, from: data)
        #expect(decoded == original)
    }
}
