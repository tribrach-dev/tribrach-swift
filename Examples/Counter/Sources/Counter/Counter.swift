/// An operation on the counter.
public enum Op: String, Sendable {
    case incr
    case reset
}

public enum Counter {
    /// Applies one operation, never going above `max`.
    //tribrach:link Counter.counterStep
    //tribrach:stamp d91fe8d3ff87445f
    public static func step(_ op: Op, in n: Int, max: Int) -> Int {
        switch op {
        case .reset: return 0
        case .incr: return n < max ? n + 1 : n
        }
    }
}
