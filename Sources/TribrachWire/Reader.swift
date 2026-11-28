import Foundation

/// Where a document breaks its schema.
public struct WireError: Error, Equatable, CustomStringConvertible {
    public let schema: String  // the schema's $id
    public let path: String  // such as "minutes"
    public let reason: String

    public init(schema: String, path: String, reason: String) {
        self.schema = schema
        self.path = path
        self.reason = reason
    }

    public var description: String { path.isEmpty ? "\(schema): \(reason)" : "\(schema): \(path): \(reason)" }
}

/// Reads a parsed document the way core's Lean decoders do (Tribrach.Wire):
/// objects are closed, null is not absent, whole numbers may be written
/// 2.0, money travels as decimal strings, and instants are RFC 3339 read at
/// any offset. Generated decoders call it; each method throws at the first
/// problem.
public struct WireReader: Sendable {
    public let schema: String

    public init(schema: String) { self.schema = schema }

    func fail(_ path: String, _ reason: String) -> WireError { WireError(schema: schema, path: path, reason: reason) }

    public static func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : path + "." + key }

    public func parse(_ data: Data) throws -> WireValue {
        do { return try WireValue.parse(data) } catch { throw fail("", "\(error)") }
    }

    /// A closed object: only the listed keys may appear.
    public func object(_ v: WireValue, _ path: String, _ keys: [String]) throws -> [String: WireValue] {
        guard case let .object(m) = v else { throw fail(path, "want an object") }
        for k in m.keys.sorted() where !keys.contains(k) { throw fail(WireReader.join(path, k), "unknown field") }
        return m
    }

    public func field(_ m: [String: WireValue], _ path: String, _ key: String) throws -> WireValue {
        guard let v = m[key] else { throw fail(WireReader.join(path, key), "missing") }
        return v
    }

    public func bool(_ v: WireValue, _ path: String) throws -> Bool {
        guard case let .bool(b) = v else { throw fail(path, "want true or false") }
        return b
    }

    /// A whole JSON number within bounds; 2.0 and 2e0 count.
    public func int(_ v: WireValue, _ path: String, min: Int64? = nil, max: Int64? = nil, multipleOf: Int64 = 0) throws -> Int64 {
        guard case let .number(text) = v else { throw fail(path, "want a whole number") }
        guard let n = WireReader.wholeNumber(text) else { throw fail(path, "\(text) is not a whole number in range") }
        try bounds(n, path, min: min, max: max, multipleOf: multipleOf)
        return n
    }

    func bounds(_ n: Int64, _ path: String, min: Int64?, max: Int64?, multipleOf: Int64) throws {
        if let min, n < min { throw fail(path, "\(n) is below \(min)") }
        if let max, n > max { throw fail(path, "\(n) is above \(max)") }
        if multipleOf != 0, n % multipleOf != 0 { throw fail(path, "\(n) is not a multiple of \(multipleOf)") }
    }

    /// The exact value of a JSON number literal, if it is whole and fits in
    /// Int64.
    static func wholeNumber(_ text: String) -> Int64? {
        var s = Substring(text)
        let negative = s.hasPrefix("-")
        if negative { s = s.dropFirst() }
        var exponent = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let x = Int(s[s.index(after: e)...].replacingOccurrences(of: "+", with: "")), abs(x) < 100_000 else {
                return nil
            }
            exponent = x
            s = s[..<e]
        }
        var digits = String(s)
        if let dot = digits.firstIndex(of: ".") {
            exponent -= digits.distance(from: dot, to: digits.endIndex) - 1
            digits.remove(at: dot)
        }
        digits = String(digits.drop { $0 == "0" })
        if digits.isEmpty { return 0 }
        while exponent < 0, digits.hasSuffix("0") {
            digits.removeLast()
            exponent += 1
        }
        guard exponent >= 0, digits.count + exponent <= 19 else { return nil }
        digits += String(repeating: "0", count: exponent)
        guard let magnitude = UInt64(digits) else { return nil }
        if negative {
            return magnitude <= UInt64(Int64.max) + 1 ? Int64(truncatingIfNeeded: 0 &- magnitude) : nil
        }
        return magnitude <= UInt64(Int64.max) ? Int64(magnitude) : nil
    }

    /// A string; lengths count Unicode scalars, as Lean's String.length does.
    public func string(_ v: WireValue, _ path: String, minLength: Int? = nil, maxLength: Int? = nil, pattern: String? = nil) throws -> String {
        guard case let .string(s) = v else { throw fail(path, "want a string") }
        let n = s.unicodeScalars.count
        if let minLength, n < minLength { throw fail(path, "shorter than \(minLength)") }
        if let maxLength, n > maxLength { throw fail(path, "longer than \(maxLength)") }
        if let pattern {
            guard let p = WirePattern.byName(pattern), p.check(s) else { throw fail(path, "\"\(s)\" is not a valid \(pattern)") }
        }
        return s
    }

    public func oneOf(_ v: WireValue, _ path: String, _ values: [String]) throws -> String {
        guard case let .string(s) = v, values.contains(s) else {
            throw fail(path, "want one of \(values.joined(separator: ", "))")
        }
        return s
    }

    /// A whole number written as a decimal string, within bounds.
    public func decimal(_ v: WireValue, _ path: String, min: Int64? = nil, max: Int64? = nil) throws -> Int64 {
        guard case let .string(s) = v, WirePattern.decimal.check(s) else {
            throw fail(path, "want a whole number as a decimal string")
        }
        guard let n = Int64(s) else { throw fail(path, "\(s) is out of range") }
        try bounds(n, path, min: min, max: max, multipleOf: 0)
        return n
    }

    /// An RFC 3339 instant to the second, at any offset. As in core, the day
    /// must exist: 2026-02-30 and 2026-02-29 are errors.
    public func instant(_ v: WireValue, _ path: String) throws -> Date {
        guard case let .string(s) = v, WirePattern.instant.check(s) else {
            throw fail(path, "want an RFC 3339 instant to the second")
        }
        let u = Array(s.utf8)
        func num(_ a: Int, _ b: Int) -> Int64 { u[a..<b].reduce(0) { $0 * 10 + Int64($1 - 48) } }
        let days = WireInstant.daysFromCivil(num(0, 4), num(5, 7), num(8, 10))
        var t = days * 86400 + num(11, 13) * 3600 + num(14, 16) * 60 + num(17, 19)
        if u[19] != UInt8(ascii: "Z") {
            let off = num(20, 22) * 3600 + num(23, 25) * 60
            t += u[19] == UInt8(ascii: "+") ? -off : off
        }
        return Date(timeIntervalSince1970: TimeInterval(t))
    }

    /// The field that names a tagged union's case.
    public func tag(_ v: WireValue, _ path: String, _ tag: String, _ cases: [String]) throws -> String {
        guard case let .object(m) = v else { throw fail(path, "want an object") }
        return try oneOf(m[tag] ?? .null, WireReader.join(path, tag), cases)
    }
}

/// Instants as core writes them: UTC, to the second.
public enum WireInstant {
    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's
    /// algorithm, as core's Tribrach.Wire.daysFromCivil).
    public static func daysFromCivil(_ y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    public static func civilFromDays(_ z0: Int64) -> (Int64, Int64, Int64) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? yoe + era * 400 + 1 : yoe + era * 400, m, d)
    }

    /// Write an instant in UTC to the second, rounding down.
    public static func format(_ date: Date) -> String {
        let t = Int64(date.timeIntervalSince1970.rounded(.down))
        let days = t >= 0 ? t / 86400 : (t - 86399) / 86400
        let secs = t - days * 86400
        let (y, m, d) = civilFromDays(days)
        func pad(_ n: Int64, _ w: Int) -> String {
            let s = String(n)
            return String(repeating: "0", count: max(0, w - s.count)) + s
        }
        return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(secs / 3600, 2)):\(pad(secs / 60 % 60, 2)):\(pad(secs % 60, 2))Z"
    }
}

/// Builds the JSON a generated encoder writes.
public enum WireWrite {
    public static func decimal(_ n: Int64) -> WireValue { .string(String(n)) }
    public static func int(_ n: Int64) -> WireValue { .number(String(n)) }
    public static func instant(_ d: Date) -> WireValue { .string(WireInstant.format(d)) }
}
