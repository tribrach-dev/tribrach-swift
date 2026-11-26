import Counter
import Foundation
import TribrachReplay
import XCTest

/// Drives a step function through the exported vectors.
final class CounterHarness: ReplayHarness {
    let max: Int
    let step: (Op, Int, Int) -> Int
    var n = 0

    init(max: Int, step: @escaping (Op, Int, Int) -> Int) {
        self.max = max
        self.step = step
    }

    func start(_ state: JSONValue) throws { n = try state.decode(Int.self) }
    func state() throws -> JSONValue { .number(Double(n)) }
    func apply(_ op: ReplayOp) throws {
        guard let o = Op(rawValue: op.name) else { throw ReplayError.unknownOperation(op.name) }
        n = step(o, n, max)
    }
}

final class CounterTests: XCTestCase {
    func vectors() throws -> Vectors {
        try Vectors.load(XCTUnwrap(Bundle.module.url(forResource: "counter.vectors", withExtension: "json")))
    }

    func testStepMatchesModel() throws {
        for result in try Replay.check(vectors(), harness: { CounterHarness(max: 3) { Counter.step($0, in: $1, max: $2) } }) {
            XCTAssertTrue(result.passed, result.description)
        }
    }

    /// The vectors must catch a plausible bug: letting the counter reach max + 1.
    func testVectorsCatchOffByOne() throws {
        let buggy: (Op, Int, Int) -> Int = { op, n, max in
            op == .incr && n <= max ? n + 1 : Counter.step(op, in: n, max: max)
        }
        let failures = try Replay.check(vectors(), harness: { CounterHarness(max: 3, step: buggy) }).filter { !$0.passed }
        XCTAssertFalse(failures.isEmpty, "the vectors don't catch the off-by-one")
    }
}
