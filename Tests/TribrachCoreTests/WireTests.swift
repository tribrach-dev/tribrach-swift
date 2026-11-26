import Foundation
import TribrachGen
import TribrachWire
import XCTest

final class WireTests: XCTestCase {
    /// Every pattern against core's cases (core/patterns.json): the regex
    /// must be core's byte for byte, and both the Swift checker and the
    /// regex must accept and reject exactly what core says.
    func testPatternsConformance() throws {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "core", withExtension: nil))
        let file = try WireValue.parse(Data(contentsOf: dir.appendingPathComponent("patterns.json")))
        guard case let .object(o) = file, case let .array(cases)? = o["cases"] else { return XCTFail("bad patterns.json") }
        XCTAssertEqual(o["format"], .string("tribrach.conformance.patterns.v1"))
        var seen = Set<String>()
        func strings(_ v: WireValue?) -> [String] {
            guard case let .array(a)? = v else { return [] }
            return a.compactMap { if case let .string(s) = $0 { return s } else { return nil } }
        }
        for c in cases {
            guard case let .object(k) = c, case let .string(name)? = k["name"], case let .string(regex)? = k["regex"] else {
                return XCTFail("bad case")
            }
            seen.insert(name)
            guard let p = WirePattern.byName(name) else {
                XCTFail("TRS0403 core has pattern \(name), which TribrachWire doesn't know; add it to WirePattern.all")
                continue
            }
            XCTAssertEqual(p.regex, regex, "TRS0403 \(name): regex differs from core's")
            XCTAssertEqual(WirePattern.byRegex(regex)?.name, name)
            // ECMA-262's final $ is \z in ICU.
            let re = try NSRegularExpression(pattern: String(regex.dropLast()) + #"\z"#)
            func matches(_ s: String) -> Bool {
                re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            }
            for s in strings(k["accept"]) {
                XCTAssertTrue(p.check(s), "\(name): check rejects \(s.debugDescription), core accepts it")
                XCTAssertTrue(matches(s), "\(name): regex rejects \(s.debugDescription), core accepts it")
            }
            for s in strings(k["reject"]) {
                XCTAssertFalse(p.check(s), "\(name): check accepts \(s.debugDescription), core rejects it")
                XCTAssertFalse(matches(s), "\(name): regex accepts \(s.debugDescription), core rejects it")
            }
        }
        for p in WirePattern.all where !seen.contains(p.name) {
            XCTFail("TRS0403 TribrachWire has pattern \(p.name), which core doesn't; core defines patterns")
        }
    }

    func testWholeNumbers() throws {
        let r = WireReader(schema: "t")
        let ok: [(String, Int64)] = [
            ("0", 0), ("-0", 0), ("15", 15), ("15.0", 15), ("1.5e1", 15), ("150e-1", 15), ("2E0", 2),
            ("9223372036854775807", .max), ("-9223372036854775808", .min), ("0.0e5", 0),
        ]
        for (text, want) in ok {
            XCTAssertEqual(try r.int(.number(text), "n"), want, text)
        }
        for text in ["1.5", "9223372036854775808", "-9223372036854775809", "1e19", "15.0000000000000001", "1e-1"] {
            XCTAssertThrowsError(try r.int(.number(text), "n"), text)
        }
        XCTAssertThrowsError(try r.int(.string("15"), "n"))
        XCTAssertThrowsError(try r.int(.number("30"), "n", multipleOf: 15 + 1))
    }

    func testInstants() throws {
        let r = WireReader(schema: "t")
        let t = try r.instant(.string("2026-11-26T19:30:00Z"), "t")
        XCTAssertEqual(t.timeIntervalSince1970, 1_795_721_400)
        XCTAssertEqual(try r.instant(.string("2026-11-26T14:30:00-05:00"), "t"), t)
        XCTAssertEqual(WireInstant.format(t), "2026-11-26T19:30:00Z")
        XCTAssertEqual(WireInstant.format(try r.instant(.string("2026-02-30T00:00:00Z"), "t")), "2026-03-02T00:00:00Z")
        XCTAssertEqual(WireInstant.format(Date(timeIntervalSince1970: -1)), "1969-12-31T23:59:59Z")
        XCTAssertEqual(WireInstant.format(Date(timeIntervalSince1970: -62_135_596_800)), "0001-01-01T00:00:00Z")
        XCTAssertThrowsError(try r.instant(.string("2026-11-26T19:30:00.5Z"), "t"))
        XCTAssertThrowsError(try r.instant(.string("2026-11-26 19:30:00Z"), "t"))
    }

    func testParse() throws {
        XCTAssertEqual(try WireValue.parse(Data(#"{"a":[1,2.50,"é😀"],"b":null}"#.utf8)),
                       .object(["a": .array([.number("1"), .number("2.50"), .string("é😀")]), "b": .null]))
        for bad in ["", "{", "[1,]", "01", "1.", "{\"a\":1} x", "\"\u{01}\"", "nul"] {
            XCTAssertThrowsError(try WireValue.parse(Data(bad.utf8)), bad)
        }
        let v = WireValue.object(["b": .string("\u{2028}\"x"), "a": .number("1")])
        XCTAssertEqual(v.text, #"{"a":1,"b":" \"x"}"#)
        XCTAssertEqual(try WireValue.parse(v.data), v)
    }

    func testGenRefuses() {
        func obj(_ field: String) -> String {
            #"{"$id":"x","title":"t","type":"object","additionalProperties":false,"required":["a"],"properties":{"a":"# + field + "}}"
        }
        let cases: [(String, String)] = [
            (#"{"type":"object","properties":{}}"#, "closed"),
            (obj(#"{"type":"string","pattern":"^a+$"}"#), "TRS0403"),
            (obj(#"{"type":"object"}"#), "unsupported"),
            (obj(#"{"type":"string","contentEncoding":"base64"}"#), "contentEncoding"),
            (#"{"oneOf":[{"type":"object","properties":{}}]}"#, "tag"),
            (obj(#"{"type":"string","format":"date-time"}"#), "format"),
        ]
        for (schema, want) in cases {
            XCTAssertThrowsError(try Gen.generate([Gen.Spec(name: "T", source: "s", schema: Data(schema.utf8))])) { e in
                XCTAssertTrue("\(e)".contains(want), "\(e) should mention \(want)")
            }
        }
    }

    func testNames() {
        XCTAssertEqual(Gen.memberName("evCharging"), "evCharging")
        XCTAssertEqual(Gen.memberName("ev-charging"), "evCharging")
        XCTAssertEqual(Gen.memberName("default"), "`default`")
        XCTAssertEqual(Gen.typeName("started"), "Started")
    }
}
