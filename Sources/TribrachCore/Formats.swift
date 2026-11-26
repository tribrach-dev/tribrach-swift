import Foundation

/// The instrument id whose links this package checks.
public let swiftOwner = "tribrach.swift"

/// A link from a Lean definition to a host symbol.
public struct Link: Codable, Equatable, Sendable {
    public var lean: String
    public var owner: String
    public var symbol: String
    public var stamp: String

    public init(lean: String, owner: String, symbol: String, stamp: String) {
        self.lean = lean
        self.owner = owner
        self.symbol = symbol
        self.stamp = stamp
    }
}

public enum FormatError: Error, CustomStringConvertible {
    case wrongFormat(path: String, found: String, want: String)
    case stateCount(caseID: String, ops: Int, states: Int)

    public var description: String {
        switch self {
        case let .wrongFormat(path, found, want):
            return "\(path): format \"\(found)\", want \"\(want)\" (re-export it with this Tribrach version)"
        case let .stateCount(id, ops, states):
            return "case \(id) has \(ops) operations but \(states) states"
        }
    }
}

/// A `tribrach.manifest.v1` file.
public struct Manifest: Codable, Sendable {
    public static let format = "tribrach.manifest.v1"
    public var format: String
    public var package: String
    public var links: [Link]

    public func owned(by owner: String = swiftOwner) -> [Link] {
        links.filter { $0.owner == owner }
    }

    public static func load(_ url: URL) throws -> Manifest {
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard m.format == format else {
            throw FormatError.wrongFormat(path: url.path, found: m.format, want: format)
        }
        return m
    }
}

/// A `tribrach.vectors.v1` file. States and operations stay as JSON values.
public struct Vectors: Sendable {
    public static let format = "tribrach.vectors.v1"

    public struct Case: Sendable {
        public var id: String
        public var start: JSONValue
        public var ops: [JSONValue]
        public var states: [JSONValue]

        public init(id: String, start: JSONValue, ops: [JSONValue], states: [JSONValue]) {
            self.id = id
            self.start = start
            self.ops = ops
            self.states = states
        }
    }

    public var model: String
    public var cases: [Case]

    public init(model: String, cases: [Case]) {
        self.model = model
        self.cases = cases
    }

    public init(json: Data, path: String = "vectors") throws {
        try self.init(value: JSONValue.parse(json), path: path)
    }

    public init(value: JSONValue, path: String = "vectors") throws {
        guard case let .object(o) = value else { throw FormatError.wrongFormat(path: path, found: "?", want: Vectors.format) }
        let format = o["format"]?.string ?? "?"
        guard format == Vectors.format else { throw FormatError.wrongFormat(path: path, found: format, want: Vectors.format) }
        model = o["model"]?.string ?? ""
        cases = []
        for c in o["cases"]?.array ?? [] {
            guard case let .object(co) = c else { continue }
            let id = co["id"]?.string ?? ""
            let ops = co["ops"]?.array ?? []
            let states = co["states"]?.array ?? []
            guard ops.count == states.count else {
                throw FormatError.stateCount(caseID: id, ops: ops.count, states: states.count)
            }
            cases.append(Case(id: id, start: co["start"] ?? .null, ops: ops, states: states))
        }
    }

    public static func load(_ url: URL) throws -> Vectors {
        try Vectors(json: Data(contentsOf: url), path: url.path)
    }
}
