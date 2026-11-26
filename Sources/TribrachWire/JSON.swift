import Foundation

/// A JSON document as the wire reads it. Numbers keep their text, so
/// `2.0`, `2e0` and `20000000000000000001` are read exactly, as core's Lean
/// decoders read them, rather than through a Double.
public indirect enum WireValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([WireValue])
    case object([String: WireValue])

    /// Compact JSON text with keys sorted.
    public var text: String {
        var out = ""
        write(&out)
        return out
    }

    public var data: Data { Data(text.utf8) }

    private func write(_ out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(n): out += n
        case let .string(s): WireValue.quote(s, &out)
        case let .array(a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(&out)
            }
            out += "]"
        case let .object(o):
            out += "{"
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                WireValue.quote(k, &out)
                out += ":"
                o[k]!.write(&out)
            }
            out += "}"
        }
    }

    private static func quote(_ s: String, _ out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x7f || u.value == 0x2028 || u.value == 0x2029 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    /// Read one JSON document. Anything after it but whitespace is an error.
    /// A repeated key keeps its last value.
    public static func parse(_ data: Data) throws -> WireValue {
        var p = Parser(bytes: [UInt8](data))
        p.space()
        let v = try p.value(depth: 0)
        p.space()
        guard p.i == p.bytes.count else { throw p.error("trailing data after the JSON value") }
        return v
    }
}

struct ParseError: Error, CustomStringConvertible {
    let description: String
}

private struct Parser {
    let bytes: [UInt8]
    var i = 0

    func error(_ why: String) -> ParseError { ParseError(description: "invalid JSON at byte \(i): \(why)") }

    var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

    mutating func space() {
        while let c = peek, c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d { i += 1 }
    }

    mutating func expect(_ word: String) throws {
        for b in word.utf8 {
            guard peek == b else { throw error("expected \(word)") }
            i += 1
        }
    }

    mutating func value(depth: Int) throws -> WireValue {
        guard depth < 512 else { throw error("nested too deeply") }
        guard let c = peek else { throw error("unexpected end") }
        switch c {
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "["):
            i += 1
            var out: [WireValue] = []
            space()
            if peek == UInt8(ascii: "]") { i += 1; return .array(out) }
            while true {
                space()
                out.append(try value(depth: depth + 1))
                space()
                if peek == UInt8(ascii: ",") { i += 1; continue }
                if peek == UInt8(ascii: "]") { i += 1; return .array(out) }
                throw error("expected , or ]")
            }
        case UInt8(ascii: "{"):
            i += 1
            var out: [String: WireValue] = [:]
            space()
            if peek == UInt8(ascii: "}") { i += 1; return .object(out) }
            while true {
                space()
                guard peek == UInt8(ascii: "\"") else { throw error("expected a key") }
                let k = try string()
                space()
                try expect(":")
                space()
                out[k] = try value(depth: depth + 1)
                space()
                if peek == UInt8(ascii: ",") { i += 1; continue }
                if peek == UInt8(ascii: "}") { i += 1; return .object(out) }
                throw error("expected , or }")
            }
        default:
            return .number(try number())
        }
    }

    mutating func digits() -> Int {
        let start = i
        while let c = peek, c >= 0x30, c <= 0x39 { i += 1 }
        return i - start
    }

    mutating func number() throws -> String {
        let start = i
        if peek == UInt8(ascii: "-") { i += 1 }
        if peek == UInt8(ascii: "0") {
            i += 1
        } else if digits() == 0 {
            throw error("expected a value")
        }
        if peek == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw error("expected digits after .") }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            i += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw error("expected exponent digits") }
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count, let n = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16)
        else { throw error("bad \\u escape") }
        i += 4
        return n
    }

    mutating func string() throws -> String {
        i += 1
        var raw: [UInt8] = []
        var out = ""
        func flush() {
            if !raw.isEmpty { out += String(decoding: raw, as: UTF8.self); raw = [] }
        }
        while true {
            guard let c = peek else { throw error("unterminated string") }
            i += 1
            switch c {
            case UInt8(ascii: "\""):
                flush()
                return out
            case UInt8(ascii: "\\"):
                guard let e = peek else { throw error("unterminated string") }
                i += 1
                switch e {
                case UInt8(ascii: "\""): raw.append(0x22)
                case UInt8(ascii: "\\"): raw.append(0x5c)
                case UInt8(ascii: "/"): raw.append(0x2f)
                case UInt8(ascii: "b"): raw.append(0x08)
                case UInt8(ascii: "f"): raw.append(0x0c)
                case UInt8(ascii: "n"): raw.append(0x0a)
                case UInt8(ascii: "r"): raw.append(0x0d)
                case UInt8(ascii: "t"): raw.append(0x09)
                case UInt8(ascii: "u"):
                    flush()
                    var u = try hex4()
                    if (0xD800..<0xDC00).contains(u), peek == UInt8(ascii: "\\"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        let lo = try hex4()
                        if (0xDC00..<0xE000).contains(lo) {
                            u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
                        } else {
                            i = save
                        }
                    }
                    // A lone surrogate becomes U+FFFD, as in Go.
                    out.unicodeScalars.append(Unicode.Scalar(u) ?? "\u{FFFD}")
                default:
                    throw error("bad escape")
                }
            default:
                guard c >= 0x20 else { throw error("control character in string") }
                raw.append(c)
            }
        }
    }
}
