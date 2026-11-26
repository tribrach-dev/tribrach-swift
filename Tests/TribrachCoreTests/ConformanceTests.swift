import Foundation
import TribrachCore
import TribrachReplay
import XCTest

/// The core conformance cases, copied from tribrach/tests/conformance at the
/// commit in CORE_REV (CI checks the copy).
final class ConformanceTests: XCTestCase {
    func load(_ name: String) throws -> [String: JSONValue] {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "core", withExtension: nil))
        let value = try JSONValue.parse(Data(contentsOf: dir.appendingPathComponent(name)))
        return try XCTUnwrap(value.object)
    }

    func testAnnotations() throws {
        for c in try load("annotations.json")["cases"]?.array ?? [] {
            let line = c.object?["line"]?.string ?? ""
            let got: JSONValue
            switch Directive.parse(line) {
            case nil: got = .null
            case let .link(lean)?: got = .object(["directive": .string("link"), "lean": .string(lean)])
            case let .stamp(s)?: got = .object(["directive": .string("stamp"), "stamp": .string(s)])
            case .pure?: got = .object(["directive": .string("pure")])
            case let .problem(p)?: got = .object(["error": .string(p.rawValue)])
            }
            XCTAssertEqual(got, c.object?["expect"], line)
        }
    }

    func testDrift() throws {
        let file = try load("drift.json")
        let owner = try XCTUnwrap(file["owner"]?.string)
        XCTAssertEqual(owner, "tribrach.go", "the drift cases are written for one owner; the outcomes don't depend on which")
        for c in file["cases"]?.array ?? [] {
            let o = try XCTUnwrap(c.object)
            let links = try XCTUnwrap(o["manifest"]).decode([Link].self)
            let host = (o["host"]?.array ?? []).map { h in
                Drift.Host(symbol: h.object?["symbol"]?.string ?? "", lean: h.object?["lean"]?.string ?? "",
                           stamp: h.object?["stamp"]?.string)
            }
            let got = JSONValue.array(Drift.compare(owner: owner, links: links, host: host).map { f in
                var fo: [String: JSONValue] = [
                    "lean": .string(f.lean), "symbol": .string(f.symbol), "outcome": .string(f.outcome.rawValue)]
                if let w = f.want { fo["want"] = .string(w) }
                return .object(fo)
            })
            XCTAssertEqual(got, o["expect"], o["id"]?.string ?? "")
        }
    }

    /// Replays states given in advance, as the conformance file's host.
    final class Fixed: ReplayHarness {
        let states: [JSONValue]
        var current: JSONValue = .null
        var step = 0
        init(_ states: [JSONValue]) { self.states = states }
        func start(_ state: JSONValue) throws { current = state }
        func apply(_ op: ReplayOp) throws { current = states[step]; step += 1 }
        func state() throws -> JSONValue { current }
    }

    func testReplay() throws {
        let file = try load("replay.json")
        let vectors = try Vectors(value: XCTUnwrap(file["vectors"]))
        let host = try XCTUnwrap(file["host"]?.object)
        var results: [JSONValue] = []
        for c in vectors.cases {
            let one = Vectors(model: vectors.model, cases: [c])
            results += Replay.check(one) { Fixed(host[c.id]?.array ?? []) }.map(\.json)
        }
        XCTAssertEqual(JSONValue.array(results), file["expect"])
    }

    func testVectorsRejectStateCountMismatch() {
        let json = #"{"format": "tribrach.vectors.v1", "model": "m", "cases": [{"id": "x", "start": 0, "ops": [{"op": "a"}], "states": []}]}"#
        XCTAssertThrowsError(try Vectors(json: Data(json.utf8)))
    }
}
