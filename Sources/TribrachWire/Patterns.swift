import Foundation

/// One of core's closed list of string patterns (Tribrach.Schema.Pat).
/// Schemas carry each one's regex; generated code finds the pattern by that
/// regex and checks strings with its tree, so no regex is compiled or run
/// here.
public struct WirePattern: Sendable {
    public let name: String
    public let regex: String
    public let tree: WireTree
    /// The YYYY-MM-DD the string starts with must be a day that exists,
    /// which no tree or regex says (core's Pat.calendar).
    public let calendar: Bool

    /// Whether `s` matches the pattern.
    public func check(_ s: String) -> Bool { tree.matches(s) && (!calendar || WirePattern.realDate(s)) }

    /// Whether the YYYY-MM-DD at the start of `s` is a day that exists in the
    /// proleptic Gregorian calendar.
    public static func realDate(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count >= 10, u[4] == UInt8(ascii: "-"), u[7] == UInt8(ascii: "-") else { return false }
        func num(_ a: Int, _ b: Int) -> Int? {
            var n = 0
            for c in u[a..<b] {
                guard c >= 48, c <= 57 else { return nil }
                n = n * 10 + Int(c - 48)
            }
            return n
        }
        guard let y = num(0, 4), let m = num(5, 7), let d = num(8, 10), (1...12).contains(m), d >= 1 else { return false }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        return d <= days
    }

    /// The patterns this version knows, read from core's
    /// tests/conformance/patterns.json (embedded in PatternsData.swift).
    public static let all: [WirePattern] = {
        do {
            return try load(Data(patternsJSON.utf8))
        } catch {
            fatalError("TribrachWire: the embedded patterns.json doesn't read: \(error)")
        }
    }()

    static func load(_ data: Data) throws -> [WirePattern] {
        guard case let .object(o) = try WireValue.parse(data), o["format"] == .string("tribrach.conformance.patterns.v1"),
              case let .array(cases)? = o["cases"]
        else { throw WireTree.Malformed(description: "not a tribrach.conformance.patterns.v1 file") }
        return try cases.map { c in
            guard case let .object(k) = c, case let .string(name)? = k["name"], case let .string(regex)? = k["regex"],
                  let tree = k["tree"]
            else { throw WireTree.Malformed(description: "a case without name, regex or tree") }
            return WirePattern(name: name, regex: regex, tree: try WireTree(json: tree), calendar: k["calendar"] == .bool(true))
        }
    }

    public static func byRegex(_ regex: String) -> WirePattern? { all.first { $0.regex == regex } }
    public static func byName(_ name: String) -> WirePattern? { all.first { $0.name == name } }

    static let decimal = byName("decimal")!
    static let instant = byName("instant")!
}

/// A pattern tree from core's tests/conformance/patterns.json
/// (Tribrach.Re):
///
///     {"lit": s}                         s itself
///     {"set": items} / {"notSet": items} one scalar in (or not in) the set
///     {"seq": [..]}                      each in turn
///     {"alt": [..]}                      any one
///     {"rep": t, "min": m, "max": n}     t from m to n times (null: no limit)
///     {"without": t, "bans": [..]}       t, refusing what a ban matches
public indirect enum WireTree: Sendable, Equatable {
    case lit([Unicode.Scalar])
    /// Inclusive ranges of scalar values.
    case set([ClosedRange<UInt32>], negated: Bool)
    case seq([WireTree])
    case alt([WireTree])
    case rep(WireTree, min: Int, max: Int?)
    case without(WireTree, bans: [WireBan])

    struct Malformed: Error, CustomStringConvertible {
        let description: String
    }

    public init(json: WireValue) throws {
        let kinds = ["lit", "set", "notSet", "seq", "alt", "rep", "without"]
        guard case let .object(o) = json, let key = kinds.first(where: { o[$0] != nil }), let body = o[key]
        else { throw Malformed(description: "not a pattern tree: \(json.text)") }
        func trees(_ v: WireValue) throws -> [WireTree] {
            guard case let .array(a) = v else { throw Malformed(description: "\(key) wants a list") }
            return try a.map(WireTree.init(json:))
        }
        func scalar(_ v: WireValue) throws -> UInt32 {
            guard case let .string(s) = v, s.unicodeScalars.count == 1 else { throw Malformed(description: "a set member isn't one character") }
            return s.unicodeScalars.first!.value
        }
        func nat(_ v: WireValue?) throws -> Int? {
            switch v {
            case nil, .null?: return nil
            case let .number(n)?:
                guard let i = Int(n), i >= 0 else { throw Malformed(description: "a count isn't a whole number") }
                return i
            default: throw Malformed(description: "a count isn't a number")
            }
        }
        switch key {
        case "lit":
            guard case let .string(s) = body else { throw Malformed(description: "lit wants a string") }
            self = .lit(Array(s.unicodeScalars))
        case "set", "notSet":
            guard case let .array(items) = body else { throw Malformed(description: "\(key) wants a list") }
            let ranges = try items.map { item -> ClosedRange<UInt32> in
                if case let .array(pair) = item {
                    guard pair.count == 2 else { throw Malformed(description: "a set range isn't a pair") }
                    let lo = try scalar(pair[0]), hi = try scalar(pair[1])
                    guard lo <= hi else { throw Malformed(description: "a set range is backwards") }
                    return lo...hi
                }
                let c = try scalar(item)
                return c...c
            }
            self = .set(ranges, negated: key == "notSet")
        case "seq": self = .seq(try trees(body))
        case "alt": self = .alt(try trees(body))
        case "rep":
            guard let min = try nat(o["min"]) else { throw Malformed(description: "rep wants a min") }
            self = .rep(try WireTree(json: body), min: min, max: try nat(o["max"]))
        default:
            guard case let .array(bans)? = o["bans"] else { throw Malformed(description: "without wants bans") }
            self = .without(try WireTree(json: body), bans: try bans.map(WireBan.init(json:)))
        }
    }

    /// Whether the tree matches all of `s`.
    public func matches(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        return steps(u, 0).contains(u.count)
    }

    /// Every position the tree can stop at, starting from s[i].
    func steps(_ s: [Unicode.Scalar], _ i: Int) -> Set<Int> {
        switch self {
        case let .lit(l):
            return i + l.count <= s.count && s[i..<(i + l.count)].elementsEqual(l) ? [i + l.count] : []
        case let .set(ranges, negated):
            guard i < s.count else { return [] }
            let hit = ranges.contains { $0.contains(s[i].value) }
            return hit != negated ? [i + 1] : []
        case let .seq(ts):
            var front: Set<Int> = [i]
            for t in ts {
                front = Set(front.flatMap { t.steps(s, $0) })
            }
            return front
        case let .alt(ts):
            return Set(ts.flatMap { $0.steps(s, i) })
        case let .rep(t, min, max):
            var out = Set<Int>()
            var front: Set<Int> = [i]
            var n = 0
            while !front.isEmpty {
                if n >= min { out.formUnion(front) }
                if let max, n == max { break }
                var next = Set<Int>()
                for j in front {
                    // A round that consumes nothing adds nothing once min is met.
                    for e in t.steps(s, j) where e > j || n < min { next.insert(e) }
                }
                front = next
                n += 1
            }
            return out
        case let .without(t, bans):
            let rest = s[i...]
            return bans.contains { $0.hits(rest) } ? [] : t.steps(s, i)
        }
    }
}

/// What a `without` node refuses, judged on the rest of the string.
public enum WireBan: Sendable, Equatable {
    /// The rest starts with these scalars.
    case startsWith([Unicode.Scalar])
    /// Split on `sep`, some part equals `segment`.
    case segment([Unicode.Scalar], sep: Unicode.Scalar)

    init(json: WireValue) throws {
        guard case let .object(o) = json else { throw WireTree.Malformed(description: "a ban isn't an object") }
        if case let .string(s)? = o["startsWith"] {
            self = .startsWith(Array(s.unicodeScalars))
        } else if case let .string(seg)? = o["segment"], case let .string(sep)? = o["sep"], sep.unicodeScalars.count == 1 {
            self = .segment(Array(seg.unicodeScalars), sep: sep.unicodeScalars.first!)
        } else {
            throw WireTree.Malformed(description: "unknown ban \(json.text)")
        }
    }

    func hits(_ rest: ArraySlice<Unicode.Scalar>) -> Bool {
        switch self {
        case let .startsWith(p): return rest.starts(with: p)
        case let .segment(seg, sep):
            return rest.split(separator: sep, omittingEmptySubsequences: false).contains { $0.elementsEqual(seg) }
        }
    }
}
