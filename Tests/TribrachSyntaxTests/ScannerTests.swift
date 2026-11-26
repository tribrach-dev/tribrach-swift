import Foundation
import TribrachCore
import TribrachSyntax
import XCTest

final class ScannerTests: XCTestCase {
    func scan(_ source: String, allow: Set<String> = []) -> FileScan {
        let decls = Scanner.declarations([(path: "t.swift", source: source)])
        return Scanner.scan(path: "t.swift", source: source, declarations: decls, allow: allow)
    }

    func codes(_ s: FileScan) -> [String] { s.diagnostics.map(\.code) }

    func testSymbolsAndStamps() {
        let s = scan("""
        import Foundation

        enum Counter {
            /// Applies one operation.
            //tribrach:link Counter.counterStep
            //tribrach:stamp 0123456789abcdef
            static func step(_ op: Op, max: Int, _ n: Int) -> Int { n }
        }

        extension Cart {
            //tribrach:link Shop.add
            mutating func add(item: Int) {}
        }

        //tribrach:pure
        func helper(x: Int) -> Int { x }
        """)
        XCTAssertEqual(codes(s), [])
        XCTAssertEqual(s.functions.map(\.symbol), ["Counter.step(_:max:_:)", "Cart.add(item:)", "helper(x:)"])
        XCTAssertEqual(s.functions[0].lean, "Counter.counterStep")
        XCTAssertEqual(s.functions[0].stamp, "0123456789abcdef")
        XCTAssertNil(s.functions[1].stamp)
        XCTAssertEqual(s.functions[2].lean, nil)
        XCTAssertTrue(s.functions[2].pure)
    }

    func testDirectiveProblems() {
        let s = scan("""
        //tribrach:link A.b C.d
        func bad() {}

        func inside() {
            //tribrach:pure
            let x = 1
        }

        //tribrach:link A.one
        //tribrach:link A.two
        func twice() {}

        //tribrach:stamp 0123456789abcdef
        func orphan() {}
        """)
        XCTAssertEqual(codes(s), ["TRS0101", "TRS0102", "TRS0103", "TRS0104"])
    }

    func testPurity() {
        let s = scan("""
        import Foundation
        import UIKit

        var counter = 0
        enum Store { static var cache = 0 }
        func unmarked() -> Int { 1 }

        //tribrach:pure
        func clock() -> Date { Date() }

        //tribrach:pure
        func dice() -> Int { Int.random(in: 1...6) }

        //tribrach:pure
        func log() { print("x") }

        //tribrach:pure
        func bump() -> Int { counter += 1; return Store.cache }

        //tribrach:pure
        func work() async { await Task.yield() }

        //tribrach:pure
        func keys(_ d: [String: Int]) -> [String] {
            var out: [String] = []
            for k in d.keys { out.append(k) }
            return out.sorted()
        }

        //tribrach:pure
        func calls() -> Int { unmarked() + clock().hashValue }
        """)
        XCTAssertEqual(codes(s), [
            "TRS0308",            // import UIKit
            "TRS0301",            // Date()
            "TRS0302",            // .random
            "TRS0303",            // print
            "TRS0304", "TRS0304", // counter, Store.cache
            "TRS0305", "TRS0305", // async, await
            "TRS0306",            // d.keys
            "TRS0307",            // unmarked()
        ])
        let message = s.diagnostics.first { $0.code == "TRS0301" }?.message ?? ""
        XCTAssertTrue(message.contains("the model has no clock"), message)
        XCTAssertEqual(codes(scan("//tribrach:pure\nfunc f() { print(1) }", allow: ["print"])), [])
    }

    func testCheckAndStamp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = """
        enum Counter {
            //tribrach:link Counter.counterStep
            static func step(_ n: Int, max: Int) -> Int { n < max ? n + 1 : n }

            //tribrach:link Counter.reset
            //tribrach:stamp 1111111111111111
            static func reset() -> Int { 0 }
        }
        """
        let manifest = """
        {"format": "tribrach.manifest.v1", "package": "counter", "links": [
          {"lean": "Counter.counterStep", "owner": "tribrach.swift", "symbol": "Counter.step(_:max:)", "stamp": "0123456789abcdef"},
          {"lean": "Counter.reset", "owner": "tribrach.swift", "symbol": "Counter.reset()", "stamp": "2222222222222222"},
          {"lean": "Counter.other", "owner": "tribrach.swift", "symbol": "Counter.other()", "stamp": "3333333333333333"},
          {"lean": "Counter.counterStep", "owner": "tribrach.go", "symbol": "example.com/counter.Step", "stamp": "0123456789abcdef"}]}
        """
        let file = dir.appendingPathComponent("Counter.swift").path
        let manifestPath = dir.appendingPathComponent("tribrach.manifest.json").path
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let diags = try Check.run(files: [file], manifestPath: manifestPath, allow: [], missing: true)
        XCTAssertEqual(diags.map(\.code), ["TRS0202", "TRS0205", "TRS0201"])
        let partial = try Check.run(files: [file], manifestPath: manifestPath, allow: [], missing: false)
        XCTAssertEqual(partial.map(\.code), ["TRS0202", "TRS0201"])

        XCTAssertEqual(try Check.stamp(files: [file], manifestPath: manifestPath, dryRun: true).count, 2)
        XCTAssertEqual(try Check.stamp(files: [file], manifestPath: manifestPath, dryRun: false).count, 2)
        let stamped = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertTrue(stamped.contains("    //tribrach:link Counter.counterStep\n    //tribrach:stamp 0123456789abcdef\n"), stamped)
        XCTAssertTrue(stamped.contains("//tribrach:stamp 2222222222222222"), stamped)
        XCTAssertEqual(try Check.stamp(files: [file], manifestPath: manifestPath, dryRun: true).count, 0)
        XCTAssertEqual(try Check.run(files: [file], manifestPath: manifestPath, allow: [], missing: false).map(\.code), [])
    }
}
