import Foundation

/// A JSON document value, used to build request bodies and JSON schemas.
///
/// Member order (`.ordered`) and sorted keys (`.object`) are guaranteed only by `jsonData()`; every request path
/// must serialize with it. `encode(to:)` through a `JSONEncoder` gives unspecified key order.
public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    /// An object whose members keep the given order in `jsonData()` only (not via `JSONEncoder`). Decoding never produces this case.
    case ordered([JSONMember])
    /// An object that encodes with its keys sorted, so the bytes are the same on every launch.
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .ordered(let members):
            // Order is NOT kept here: JSONEncoder's keyed containers are unordered. Use `jsonData()` for order.
            try c.encode(Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last }))
        }
    }

    /// The document as JSON bytes: `.ordered` members in their given order, `.object` keys sorted, so a request body
    /// is byte-identical on every launch. Use this, not `JSONEncoder`, wherever order matters: `JSONEncoder`'s keyed
    /// containers do not keep insertion order, so `encode(to:)` alone cannot promise it.
    public func jsonData() throws -> Data {
        var out = Data()
        try write(to: &out)
        return out
    }

    private func write(to out: inout Data) throws {
        switch self {
        case .string, .number, .bool, .null:
            out.append(try JSONEncoder().encode(self))
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                try item.write(to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let dict):
            try Self.write(dict.sorted { $0.key < $1.key }.map { JSONMember(key: $0.key, value: $0.value) }, to: &out)
        case .ordered(let members):
            try Self.write(members, to: &out)
        }
    }

    private static func write(_ members: [JSONMember], to out: inout Data) throws {
        out.append(UInt8(ascii: "{"))
        for (i, m) in members.enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            out.append(try JSONEncoder().encode(m.key))
            out.append(UInt8(ascii: ":"))
            try m.value.write(to: &out)
        }
        out.append(UInt8(ascii: "}"))
    }
}

/// One member of a `JSONValue.ordered` object.
public struct JSONMember: Sendable, Equatable, Codable {
    public var key: String
    public var value: JSONValue
    public init(key: String, value: JSONValue) { self.key = key; self.value = value }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
