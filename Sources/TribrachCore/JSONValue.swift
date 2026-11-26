import Foundation

/// A JSON value with the equality replay uses: object key order is ignored,
/// numbers compare by value (1 equals 1.0), and booleans are never numbers.
public enum JSONValue: Equatable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var string: String? { if case let .string(s) = self { return s } else { return nil } }
    public var array: [JSONValue]? { if case let .array(a) = self { return a } else { return nil } }
    public var object: [String: JSONValue]? { if case let .object(o) = self { return o } else { return nil } }

    public static func parse(_ data: Data) throws -> JSONValue {
        from(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Convert a value from JSONSerialization.
    public static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map(from))
        case let o as [String: Any]:
            return .object(o.mapValues(from))
        default:
            return .null
        }
    }

    /// Encode any Encodable value and read it back as JSON.
    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        try parse(JSONEncoder().encode(value))
    }

    public var foundation: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return b
        case let .number(n): return n
        case let .string(s): return s
        case let .array(a): return a.map(\.foundation)
        case let .object(o): return o.mapValues(\.foundation)
        }
    }

    /// Compact JSON text, keys sorted.
    public var description: String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: foundation, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return "?" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode this value as a Decodable type.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: foundation, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(type, from: data)
    }
}
