import Foundation

/// Minimal JSON value used for JSON-RPC envelopes, tool arguments, schemas and structured results.
indirect enum McpJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([McpJSON])
    case object([String: McpJSON])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([McpJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: McpJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    subscript(key: String) -> McpJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int? { if case .int(let i) = self { return i }; return nil }
    var object: [String: McpJSON]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    func text() throws -> String { String(decoding: try data(), as: UTF8.self) }

    static func parse(_ data: Data) throws -> McpJSON { try JSONDecoder().decode(McpJSON.self, from: data) }

    /// Encodes a service DTO exactly like the REST layer does (ISO-8601 instants), then re-reads it as a JSON value.
    static func encoding<T: Encodable>(_ value: T) throws -> McpJSON {
        let response = try timeResponse(value)
        guard let body = response.body.data else { return .null }
        return try parse(body)
    }

    /// Adds `...Hm` siblings (h:mm) to every integer `...Seconds` member so clients need no unit conversion.
    func addingDurationStrings() -> McpJSON {
        switch self {
        case .array(let items): return .array(items.map { $0.addingDurationStrings() })
        case .object(let members):
            var result: [String: McpJSON] = [:]
            for (key, value) in members {
                result[key] = value.addingDurationStrings()
                guard case .int(let seconds) = value else { continue }
                let sibling: String?
                if key == "seconds" { sibling = "hm" }
                else if key.hasSuffix("Seconds") { sibling = String(key.dropLast("Seconds".count)) + "Hm" }
                else { sibling = nil }
                if let sibling, members[sibling] == nil { result[sibling] = .string(Self.hm(seconds)) }
            }
            return .object(result)
        default: return self
        }
    }
    static func hm(_ seconds: Int) -> String {
        let total = abs(seconds) / 60
        return (seconds < 0 ? "-" : "") + "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

extension McpJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                   ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: McpJSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, McpJSON)...) { self = .object(Dictionary(elements) { _, new in new }) }
}
