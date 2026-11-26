/// One of core's closed list of string patterns (Tribrach.Schema.Pat).
/// Schemas carry each one's regex; generated code finds the checker by that
/// regex, so no regex is compiled or run here.
public struct WirePattern: Sendable {
    public let name: String
    public let regex: String
    public let check: @Sendable (String) -> Bool

    /// The patterns this version knows, as listed in core's
    /// tests/conformance/patterns.json.
    public static let all: [WirePattern] = [
        WirePattern(name: "hex16", regex: "^[0-9a-f]{16}$", check: { hex($0, 16) }),
        WirePattern(name: "hex40", regex: "^[0-9a-f]{40}$", check: { hex($0, 40) }),
        WirePattern(name: "hex64", regex: "^[0-9a-f]{64}$", check: { hex($0, 64) }),
        WirePattern(name: "slug", regex: "^[a-z0-9][a-z0-9-]*$", check: slug),
        WirePattern(name: "upperAlnum", regex: "^[A-Z0-9]+$", check: upperAlnum),
        WirePattern(name: "ownerRepo", regex: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", check: ownerRepo),
        WirePattern(name: "relPath", regex: #"^(?!/)(?!.*(^|/)\.\.(/|$))[^\\\x00-\x1f\u2028\u2029]+$"#, check: relPath),
        WirePattern(name: "uri", regex: #"^[A-Za-z][A-Za-z0-9+.-]*:[^\x00-\x20\x7f]*$"#, check: uri),
        WirePattern(name: "dateTime", regex: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"#, check: dateTime),
        WirePattern(name: "instant", regex: #"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"#, check: instant),
        WirePattern(name: "decimal", regex: "^(0|-?[1-9][0-9]*)$", check: decimal),
    ]

    public static func byRegex(_ regex: String) -> WirePattern? { all.first { $0.regex == regex } }
    public static func byName(_ name: String) -> WirePattern? { all.first { $0.name == name } }
}

private func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
private func isLower(_ c: Unicode.Scalar) -> Bool { c >= "a" && c <= "z" }
private func isUpper(_ c: Unicode.Scalar) -> Bool { c >= "A" && c <= "Z" }

private func every(_ s: Substring.UnicodeScalarView, _ f: (Unicode.Scalar) -> Bool) -> Bool { s.allSatisfy(f) }
private func every(_ s: String, _ f: (Unicode.Scalar) -> Bool) -> Bool { s.unicodeScalars.allSatisfy(f) }

private func hex(_ s: String, _ n: Int) -> Bool {
    s.unicodeScalars.count == n && every(s) { isDigit($0) || ($0 >= "a" && $0 <= "f") }
}

private func slug(_ s: String) -> Bool {
    guard let c = s.unicodeScalars.first, isLower(c) || isDigit(c) else { return false }
    return every(s) { isLower($0) || isDigit($0) || $0 == "-" }
}

private func upperAlnum(_ s: String) -> Bool {
    !s.isEmpty && every(s) { isUpper($0) || isDigit($0) }
}

private func ownerRepo(_ s: String) -> Bool {
    let parts = s.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
    let ok: (Unicode.Scalar) -> Bool = { isLower($0) || isUpper($0) || isDigit($0) || $0 == "_" || $0 == "." || $0 == "-" }
    return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(ok) }
}

private func relPath(_ s: String) -> Bool {
    let u = s.unicodeScalars
    guard let first = u.first, first != "/" else { return false }
    guard every(s, { $0 != "\\" && $0.value >= 0x20 && $0.value != 0x2028 && $0.value != 0x2029 }) else { return false }
    return !u.split(separator: "/", omittingEmptySubsequences: false).contains { $0.elementsEqual("..".unicodeScalars) }
}

private func uri(_ s: String) -> Bool {
    let u = Array(s.unicodeScalars)
    guard let colon = u.firstIndex(of: ":"), colon >= 1, isLower(u[0]) || isUpper(u[0]) else { return false }
    let schemeOK = u[..<colon].allSatisfy { isLower($0) || isUpper($0) || isDigit($0) || $0 == "+" || $0 == "." || $0 == "-" }
    return schemeOK && u[(colon + 1)...].allSatisfy { $0.value > 0x20 && $0.value != 0x7f }
}

/// Reads a pattern left to right over the string's scalars.
private struct Scan {
    var rest: ArraySlice<Unicode.Scalar>
    var ok = true

    init(_ s: String) { rest = ArraySlice(s.unicodeScalars) }

    mutating func num(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n {
            guard ok, let c = rest.first, isDigit(c) else { ok = false; return 0 }
            v = v * 10 + Int(c.value - 48)
            rest = rest.dropFirst()
        }
        return v
    }

    mutating func lit(_ c: Unicode.Scalar) {
        guard ok, rest.first == c else { ok = false; return }
        rest = rest.dropFirst()
    }

    mutating func offset(maxHour: Int, maxMin: Int) -> Bool {
        guard ok, let c = rest.first else { return false }
        if c == "Z" { return rest.count == 1 }
        guard c == "+" || c == "-" else { return false }
        rest = rest.dropFirst()
        let h = num(2)
        lit(":")
        let m = num(2)
        return ok && rest.isEmpty && h <= maxHour && m <= maxMin
    }
}

private func dateTime(_ str: String) -> Bool {
    var s = Scan(str)
    _ = s.num(4); s.lit("-"); _ = s.num(2); s.lit("-"); _ = s.num(2)
    s.lit("T"); _ = s.num(2); s.lit(":"); _ = s.num(2); s.lit(":"); _ = s.num(2)
    if s.ok, s.rest.first == "." {
        s.rest = s.rest.dropFirst()
        guard let c = s.rest.first, isDigit(c) else { return false }
        while let c = s.rest.first, isDigit(c) { s.rest = s.rest.dropFirst() }
    }
    return s.offset(maxHour: 99, maxMin: 99)
}

func instant(_ str: String) -> Bool {
    var s = Scan(str)
    _ = s.num(4); s.lit("-")
    let mo = s.num(2); s.lit("-")
    let d = s.num(2); s.lit("T")
    let h = s.num(2); s.lit(":")
    let mi = s.num(2); s.lit(":")
    let se = s.num(2)
    guard s.ok, (1...12).contains(mo), (1...31).contains(d), h <= 23, mi <= 59, se <= 59 else { return false }
    return s.offset(maxHour: 23, maxMin: 59)
}

func decimal(_ s: String) -> Bool {
    if s == "0" { return true }
    let body = s.hasPrefix("-") ? s.unicodeScalars.dropFirst() : Substring(s).unicodeScalars
    guard let first = body.first, first != "0" else { return false }
    return every(body, isDigit)
}
