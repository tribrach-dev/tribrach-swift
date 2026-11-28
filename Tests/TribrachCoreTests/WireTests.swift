import Foundation
import TribrachGen
@testable import TribrachWire
import XCTest

func coreFile(_ name: String) throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: "core", withExtension: nil)).appendingPathComponent(name)
}

final class WireTests: XCTestCase {
    /// The patterns compiled in are core's.
    func testEmbeddedPatterns() throws {
        let text = try String(contentsOf: coreFile("patterns.json"), encoding: .utf8)
        XCTAssertTrue(patternsJSON + "\n" == text,
                      "TRS0403 Sources/TribrachWire/PatternsData.swift differs from core's patterns.json; fix: Scripts/embed-patterns.sh")
    }

    /// Every pattern against core's cases (core/patterns.json): the regex
    /// must be core's byte for byte, and both the tree matcher and the
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
                XCTFail("TRS0403 core has pattern \(name), which TribrachWire doesn't know; fix: Scripts/embed-patterns.sh")
                continue
            }
            XCTAssertEqual(p.regex, regex, "TRS0403 \(name): regex differs from core's")
            XCTAssertEqual(WirePattern.byRegex(regex)?.name, name)
            // ECMA-262's final $ is \z in ICU.
            let re = try NSRegularExpression(pattern: String(regex.dropLast()) + #"\z"#)
            // A calendar pattern's regex checks the shape; the day is checked apart.
            let calendar = k["calendar"] == .bool(true)
            XCTAssertEqual(p.calendar, calendar, "\(name): calendar differs from core's")
            func matches(_ s: String) -> Bool {
                re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil && (!calendar || WirePattern.realDate(s))
            }
            for s in strings(k["accept"]) {
                XCTAssertTrue(p.check(s), "\(name): the tree rejects \(s.debugDescription), core accepts it")
                XCTAssertTrue(matches(s), "\(name): regex rejects \(s.debugDescription), core accepts it")
            }
            for s in strings(k["reject"]) {
                XCTAssertFalse(p.check(s), "\(name): the tree accepts \(s.debugDescription), core rejects it")
                XCTAssertFalse(matches(s), "\(name): regex accepts \(s.debugDescription), core rejects it")
            }
        }
        for p in WirePattern.all where !seen.contains(p.name) {
            XCTFail("TRS0403 TribrachWire has pattern \(p.name), which core doesn't; core defines patterns")
        }
    }

    /// Core's wire cases (core/wire.json): parse each input, read it with
    /// WireReader as its schema says, write it back and compare, or check
    /// that reading fails.
    func testWireConformance() throws {
        let file = try WireValue.parse(Data(contentsOf: coreFile("wire.json")))
        guard case let .object(o) = file, case let .array(cases)? = o["cases"] else { return XCTFail("bad wire.json") }
        XCTAssertEqual(o["format"], .string("tribrach.conformance.wire.v1"))
        XCTAssertGreaterThan(cases.count, 100)
        for c in cases {
            guard case let .object(k) = c, case let .string(id)? = k["id"], case let .object(schema)? = k["schema"],
                  case let .string(input)? = k["input"]
            else { return XCTFail("bad case \(c.text)") }
            let r = WireReader(schema: "wire.json")
            var got: WireValue?
            var why = ""
            do {
                got = try readWire(r, schema, r.parse(Data(input.utf8)), "")
            } catch {
                why = "\(error)"
            }
            if k["error"] == .bool(true) {
                XCTAssertNil(got, "\(id): reads \(input.debugDescription) as \(got?.text ?? ""), core rejects it")
            } else {
                XCTAssertEqual(got, k["output"], "\(id): \(input.debugDescription) gives \(got?.text ?? why), core writes \(k["output"]?.text ?? "")")
            }
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
        XCTAssertThrowsError(try r.instant(.string("2026-02-30T00:00:00Z"), "t"))
        XCTAssertThrowsError(try r.instant(.string("2026-02-29T00:00:00Z"), "t"))
        XCTAssertEqual(WireInstant.format(try r.instant(.string("2028-02-29T00:00:00Z"), "t")), "2028-02-29T00:00:00Z")
        XCTAssertEqual(WireInstant.format(Date(timeIntervalSince1970: -1)), "1969-12-31T23:59:59Z")
        XCTAssertEqual(WireInstant.format(Date(timeIntervalSince1970: -62_135_596_800)), "0001-01-01T00:00:00Z")
        XCTAssertThrowsError(try r.instant(.string("2026-11-26T19:30:00.5Z"), "t"))
        XCTAssertThrowsError(try r.instant(.string("2026-11-26 19:30:00Z"), "t"))
    }

    func testParse() throws {
        XCTAssertEqual(try WireValue.parse(Data(#"{"a":[1,2.50,"é😀"],"b":null}"#.utf8)),
                       .object(["a": .array([.number("1"), .number("2.50"), .string("é😀")]), "b": .null]))
        for bad in ["", "{", "[1,]", "01", "1.", "{\"a\":1} x", "\"\u{01}\"", "nul", "{\"a\":1,\"a\":2}"] {
            XCTAssertThrowsError(try WireValue.parse(Data(bad.utf8)), bad)
        }
        let v = WireValue.object(["b": .string("\u{2028}\"x"), "a": .number("1")])
        XCTAssertEqual(v.text, #"{"a":1,"b":"\u2028\"x"}"#)
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

private func bound(_ m: [String: WireValue]?, _ k: String) -> Int64? {
    if case let .number(n)? = m?[k] { return Int64(n) }
    return nil
}

/// Follows a schema with WireReader's primitives, as generated code does,
/// and returns what generated code writes.
private func readWire(_ r: WireReader, _ s: [String: WireValue], _ v: WireValue, _ path: String) throws -> WireValue {
    func bad(_ why: String) -> WireError { WireError(schema: "wire.json", path: path, reason: why) }
    if case let .string(c)? = s["const"] { return .string(try r.oneOf(v, path, [c])) }
    if case let .array(vals)? = s["enum"] {
        let names = vals.compactMap { x -> String? in
            if case let .string(n) = x { return n }
            return nil
        }
        return .string(try r.oneOf(v, path, names))
    }
    if case let .array(alts)? = s["oneOf"] {
        // A tagged union: each alternative is an object with one constant field.
        var tag = ""
        var byName: [String: [String: WireValue]] = [:]
        for case let .object(alt) in alts {
            guard case let .object(props)? = alt["properties"] else { continue }
            for (key, p) in props {
                if case let .object(pm) = p, case let .string(c)? = pm["const"] {
                    tag = key
                    byName[c] = alt
                }
            }
        }
        let name = try r.tag(v, path, tag, byName.keys.sorted())
        guard let alt = byName[name] else { throw bad("no alternative \(name)") }
        return try readWire(r, alt, v, path)
    }
    switch s["type"] {
    case .string("boolean")?:
        return .bool(try r.bool(v, path))
    case .string("integer")?:
        let n = try r.int(v, path, min: bound(s, "minimum"), max: bound(s, "maximum"), multipleOf: bound(s, "multipleOf") ?? 0)
        return WireWrite.int(n)
    case .string("string")?:
        var pat: WirePattern?
        if case let .string(re)? = s["pattern"] {
            guard let p = WirePattern.byRegex(re) else { throw bad("unknown pattern \(re)") }
            pat = p
        }
        if pat?.name == "decimal" {
            var x: [String: WireValue]?
            if case let .object(o)? = s["x-tribrach"] { x = o }
            return WireWrite.decimal(try r.decimal(v, path, min: bound(x, "minimum"), max: bound(x, "maximum")))
        }
        if pat?.name == "instant" {
            return WireWrite.instant(try r.instant(v, path))
        }
        let lo = bound(s, "minLength").map { Int($0) }
        let hi = bound(s, "maxLength").map { Int($0) }
        return .string(try r.string(v, path, minLength: lo, maxLength: hi, pattern: pat?.name))
    case .string("array")?:
        guard case let .array(xs) = v else { throw bad("want an array") }
        if let lo = bound(s, "minItems"), Int64(xs.count) < lo { throw bad("too few items") }
        if let hi = bound(s, "maxItems"), Int64(xs.count) > hi { throw bad("too many items") }
        guard case let .object(item)? = s["items"] else { throw bad("no items schema") }
        var out: [WireValue] = []
        for (i, x) in xs.enumerated() {
            out.append(try readWire(r, item, x, "\(path)[\(i)]"))
        }
        return .array(out)
    case .string("object")?:
        guard case let .object(props)? = s["properties"] else { throw bad("no properties") }
        var required = Set<String>()
        if case let .array(rs)? = s["required"] {
            for case let .string(k) in rs { required.insert(k) }
        }
        let m = try r.object(v, path, Array(props.keys))
        var out: [String: WireValue] = [:]
        for (key, p) in props {
            guard case let .object(pm) = p else { continue }
            if required.contains(key) {
                out[key] = try readWire(r, pm, try r.field(m, path, key), WireReader.join(path, key))
            } else if let x = m[key] {
                out[key] = try readWire(r, pm, x, WireReader.join(path, key))
            }
        }
        return .object(out)
    default:
        throw bad("schema not covered: \(WireValue.object(s).text)")
    }
}
