import Foundation
@_exported import TribrachCore

/// Drives the implementation under test through exported vectors.
///
///     final class CounterHarness: ReplayHarness {
///         var n = 0
///         func start(_ state: JSONValue) throws { n = try state.decode(Int.self) }
///         func apply(_ op: ReplayOp) throws { n = Counter.step(op.name == "incr" ? .incr : .reset, n, max: 3) }
///         func state() throws -> JSONValue { .number(Double(n)) }
///     }
///
///     for result in try Replay.check(Vectors.load(url), harness: CounterHarness.init) {
///         XCTAssertTrue(result.passed, result.description)
///     }
public protocol ReplayHarness {
    /// Reset the implementation to the given state.
    func start(_ state: JSONValue) throws
    /// Perform one operation.
    func apply(_ op: ReplayOp) throws
    /// The current state in the model's JSON encoding.
    func state() throws -> JSONValue
}

/// One operation: its name (the `op` field) and the whole object.
public struct ReplayOp: Sendable {
    public var name: String
    public var value: JSONValue

    /// A field of the operation, decoded.
    public func field<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
        guard let v = value.object?[key] else { throw ReplayError.missingField(op: name, field: key) }
        return try v.decode(type)
    }
}

public enum ReplayError: Error, CustomStringConvertible {
    case missingField(op: String, field: String)
    case unknownOperation(String)

    public var description: String {
        switch self {
        case let .missingField(op, field): return "operation \(op) has no field \(field)"
        case let .unknownOperation(op): return "unknown operation \(op)"
        }
    }
}

/// The outcome of one case.
public struct ReplayResult: CustomStringConvertible, Sendable {
    public enum Outcome: String, Sendable { case ok, differs, error }

    public var caseID: String
    public var outcome: Outcome
    public var step: Int?
    public var op: JSONValue?
    public var want: JSONValue?
    public var got: JSONValue?
    public var error: String?

    public var passed: Bool { outcome == .ok }

    public var description: String {
        switch outcome {
        case .ok:
            return "case \(caseID): ok"
        case .differs:
            return "case \(caseID), step \(step ?? 0) (\(op?.description ?? "?")): the model has \(want?.description ?? "?"), the code has \(got?.description ?? "?")"
        case .error:
            return "case \(caseID), step \(step ?? 0): \(error ?? "error")"
        }
    }

    /// The result as the conformance files write it.
    public var json: JSONValue {
        var o: [String: JSONValue] = ["case": .string(caseID), "outcome": .string(outcome.rawValue)]
        if let step { o["step"] = .number(Double(step)) }
        if let op { o["op"] = op }
        if let want { o["want"] = want }
        if let got { o["got"] = got }
        if let error { o["error"] = .string(error) }
        return .object(o)
    }
}

public enum Replay {
    /// Run every case with a fresh harness. A case stops at the first step
    /// whose state differs from the model's.
    public static func check(_ vectors: Vectors, harness make: () -> any ReplayHarness) -> [ReplayResult] {
        vectors.cases.map { run($0, make()) }
    }

    static func run(_ c: Vectors.Case, _ h: any ReplayHarness) -> ReplayResult {
        do {
            try h.start(c.start)
        } catch {
            return ReplayResult(caseID: c.id, outcome: .error, error: "start: \(error)")
        }
        for (i, op) in c.ops.enumerated() {
            guard let name = op.object?["op"]?.string else {
                return ReplayResult(caseID: c.id, outcome: .error, step: i + 1, error: "operation has no op field")
            }
            let got: JSONValue
            do {
                try h.apply(ReplayOp(name: name, value: op))
                got = try h.state()
            } catch {
                return ReplayResult(caseID: c.id, outcome: .error, step: i + 1, op: op, error: "\(error)")
            }
            if got != c.states[i] {
                return ReplayResult(caseID: c.id, outcome: .differs, step: i + 1, op: op, want: c.states[i], got: got)
            }
        }
        return ReplayResult(caseID: c.id, outcome: .ok)
    }
}
