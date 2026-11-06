import Foundation

/// Lossless JSON container used for blocks we persist but do not interpret
/// (for example the `oauthAccount` object copied out of ~/.claude.json).
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Converts a JSONSerialization object graph.
    init(any: Any) {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    /// Back to a JSONSerialization-compatible graph.
    var any: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 9e15 ? NSNumber(value: Int64(n)) : NSNumber(value: n)
        case .bool(let b): return NSNumber(value: b)
        case .null: return NSNull()
        case .array(let a): return a.map { $0.any }
        case .object(let o): return o.mapValues { $0.any }
        }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    subscript(key: String) -> JSONValue? { object?[key] }
}

extension Dictionary where Key == String, Value == JSONValue {
    var anyDictionary: [String: Any] { mapValues { $0.any } }
    init(anyDictionary: [String: Any]) { self = anyDictionary.mapValues(JSONValue.init(any:)) }
}
