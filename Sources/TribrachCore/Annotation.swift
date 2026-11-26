/// One `//tribrach:` directive read from a comment line.
///
/// The grammar is shared by every Tribrach instrument and pinned by the core
/// conformance cases (`tests/conformance/annotations.json`):
///
///     //tribrach:link <LeanName>
///     //tribrach:pure
///     //tribrach:stamp <16 lowercase hex digits>
///
/// A directive has no space after the `//`; with a space it is prose.
public enum Directive: Equatable, Sendable {
    case link(lean: String)
    case pure
    case stamp(String)
    case problem(Problem)

    /// Why a directive couldn't be read; the values are the conformance names.
    public enum Problem: String, Equatable, Sendable {
        case missingArgument = "missing-argument"
        case extraArgument = "extra-argument"
        case badStamp = "bad-stamp"
        case unknownDirective = "unknown-directive"
    }

    /// Whether a string is a well-formed stamp: 16 lowercase hex digits.
    public static func isStamp(_ s: String) -> Bool {
        s.utf8.count == 16 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Split on runs of spaces and tabs, keeping «...» groups whole.
    static func splitArguments(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quoted = false
        for ch in s {
            if ch == "«" { quoted = true }
            if ch == "»" { quoted = false }
            if (ch == " " || ch == "\t") && !quoted {
                if !current.isEmpty { args.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    /// Read one comment line, including its `//` marker. Returns nil when the
    /// line isn't a directive.
    public static func parse(_ line: String) -> Directive? {
        guard line.hasPrefix("//") else { return nil }
        let body = line.dropFirst(2)
        let prefix = "tribrach:"
        guard body.hasPrefix(prefix) else { return nil }
        var rest = String(body.dropFirst(prefix.count))
        while let last = rest.last, last == " " || last == "\t" { rest.removeLast() }
        guard let first = rest.first, first != " ", first != "\t" else {
            return .problem(.unknownDirective)
        }
        let words = splitArguments(rest)
        let name = words[0]
        let args = Array(words.dropFirst())
        let arity: [String: Int] = ["link": 1, "pure": 0, "stamp": 1]
        guard let n = arity[name] else { return .problem(.unknownDirective) }
        if args.count < n { return .problem(.missingArgument) }
        if args.count > n { return .problem(.extraArgument) }
        switch name {
        case "link": return .link(lean: args[0])
        case "stamp": return isStamp(args[0]) ? .stamp(args[0]) : .problem(.badStamp)
        default: return .pure
        }
    }
}
