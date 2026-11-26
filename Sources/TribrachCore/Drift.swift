/// Comparing the links found in Swift code with the manifest. The outcomes
/// are the core conformance names (`tests/conformance/drift.json`).
public enum Drift {
    public enum Outcome: String, Sendable {
        case ok
        case drift
        case unstamped
        case unknown
        case symbolMismatch = "symbol-mismatch"
        case missing
    }

    /// One annotated host symbol; `stamp` is nil when none is recorded.
    public struct Host: Equatable, Sendable {
        public var symbol: String
        public var lean: String
        public var stamp: String?

        public init(symbol: String, lean: String, stamp: String?) {
            self.symbol = symbol
            self.lean = lean
            self.stamp = stamp
        }
    }

    /// `want` is the manifest's stamp for drift and unstamped, and the
    /// manifest's symbol for symbol-mismatch.
    public struct Finding: Equatable, Sendable {
        public var lean: String
        public var symbol: String
        public var outcome: Outcome
        public var want: String?
    }

    /// Compare host links with the manifest links owned by `owner`, sorted by
    /// Lean name then symbol.
    public static func compare(owner: String, links: [Link], host: [Host]) -> [Finding] {
        struct Key: Hashable { var lean: String; var symbol: String }
        var mine: [Key: Link] = [:]
        var symbols: [String: [String]] = [:]
        for l in links where l.owner == owner {
            mine[Key(lean: l.lean, symbol: l.symbol)] = l
            symbols[l.lean, default: []].append(l.symbol)
        }
        var out: [Finding] = []
        var seen = Set<Key>()
        for h in host {
            let k = Key(lean: h.lean, symbol: h.symbol)
            if let l = mine[k] {
                seen.insert(k)
                if h.stamp == nil {
                    out.append(Finding(lean: h.lean, symbol: h.symbol, outcome: .unstamped, want: l.stamp))
                } else if h.stamp != l.stamp {
                    out.append(Finding(lean: h.lean, symbol: h.symbol, outcome: .drift, want: l.stamp))
                } else {
                    out.append(Finding(lean: h.lean, symbol: h.symbol, outcome: .ok, want: nil))
                }
            } else if let syms = symbols[h.lean], let first = syms.sorted().first {
                out.append(Finding(lean: h.lean, symbol: h.symbol, outcome: .symbolMismatch, want: first))
            } else {
                out.append(Finding(lean: h.lean, symbol: h.symbol, outcome: .unknown, want: nil))
            }
        }
        for (k, l) in mine where !seen.contains(k) {
            out.append(Finding(lean: l.lean, symbol: l.symbol, outcome: .missing, want: nil))
        }
        return out.sorted { ($0.lean, $0.symbol) < ($1.lean, $1.symbol) }
    }
}
