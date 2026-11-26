/// An operation on the counter.
public enum Op: String, Sendable {
    case incr
    case reset
}

public enum Counter {
    /// Applies one operation, never going above `max`.
    //tribrach:link Counter.counterStep
    //tribrach:stamp c5f9ea973150248a
    public static func step(_ op: Op, in n: Int, max: Int) -> Int {
        switch op {
        case .reset: return 0
        case .incr: return n < max ? n + 1 : n
        }
    }
}
