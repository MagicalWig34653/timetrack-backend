import Foundation

/// Small JSON-Schema subset validator for the OpenAPI 3.1 contract (no external dependency).
/// Supports: $ref (local), type (string or list incl. "null"), nullable, enum, const, format (date, date-time, uuid),
/// object (properties, required, additionalProperties), array (items, minItems), allOf, oneOf, anyOf,
/// integer/number bounds (minimum, maximum). Unknown keywords are ignored; mismatches are returned as readable strings.
struct JSONSchemaValidator {
    let root: [String: Any]
    /// Strict mode additionally reports response properties the schema does not declare (documentation gaps),
    /// unless the schema sets `additionalProperties`.
    let reportUndeclaredProperties: Bool
    init(document: [String: Any], reportUndeclaredProperties: Bool = false) { root = document; self.reportUndeclaredProperties = reportUndeclaredProperties }

    func validate(_ value: Any, against schema: [String: Any], path: String = "$", checkUndeclared: Bool = true) -> [String] {
        if let ref = schema["$ref"] as? String {
            guard let target = resolve(ref) else { return ["\(path): unresolvable $ref \(ref)"] }
            return validate(value, against: target, path: path, checkUndeclared: checkUndeclared)
        }
        var problems: [String] = []
        if reportUndeclaredProperties, checkUndeclared, let object = value as? [String: Any], schema["additionalProperties"] == nil {
            let declared = declaredProperties(schema)
            if !declared.isEmpty || schema["properties"] != nil {
                for name in object.keys.sorted() where !declared.contains(name) { problems.append("\(path): property \"\(name)\" is not declared in the schema") }
            }
        }
        if value is NSNull {
            if allowsNull(schema) { return [] }
            // allOf/oneOf/anyOf may still accept null through a branch.
            if schema["allOf"] == nil && schema["oneOf"] == nil && schema["anyOf"] == nil { return ["\(path): null not allowed"] }
        }
        for sub in schema["allOf"] as? [[String: Any]] ?? [] { problems += validate(value, against: sub, path: path, checkUndeclared: false) }
        if let options = schema["oneOf"] as? [[String: Any]] {
            let matching = options.filter { validate(value, against: $0, path: path).isEmpty }.count
            if matching != 1 { problems.append("\(path): matches \(matching) oneOf branches (expected 1)") }
        }
        if let options = schema["anyOf"] as? [[String: Any]], !options.contains(where: { validate(value, against: $0, path: path).isEmpty }) {
            problems.append("\(path): matches no anyOf branch")
        }
        if value is NSNull { return problems }
        if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { Self.equal($0, value) }) {
            problems.append("\(path): value \(Self.describe(value)) not in enum \(allowed.map(Self.describe))")
        }
        if let constant = schema["const"], !Self.equal(constant, value) { problems.append("\(path): value \(Self.describe(value)) != const \(Self.describe(constant))") }
        let types = Self.types(schema)
        if !types.isEmpty, !types.contains(where: { Self.matches($0, value) }) {
            problems.append("\(path): expected \(types.joined(separator: "|")), got \(Self.kind(value))")
            return problems
        }
        if let string = value as? String, !Self.isBool(value) { problems += checkString(string, schema, path) }
        if let number = Self.double(value) {
            if let minimum = Self.double(schema["minimum"] as Any), number < minimum { problems.append("\(path): \(number) < minimum \(minimum)") }
            if let maximum = Self.double(schema["maximum"] as Any), number > maximum { problems.append("\(path): \(number) > maximum \(maximum)") }
        }
        if let object = value as? [String: Any] { problems += checkObject(object, schema, path) }
        if let array = value as? [Any] {
            if let minimum = schema["minItems"] as? Int, array.count < minimum { problems.append("\(path): fewer than \(minimum) items") }
            if let items = schema["items"] as? [String: Any] {
                for (index, element) in array.enumerated() { problems += validate(element, against: items, path: "\(path)[\(index)]") }
            }
        }
        return problems
    }

    private func checkString(_ string: String, _ schema: [String: Any], _ path: String) -> [String] {
        switch schema["format"] as? String {
        case "date": return Self.isDate(string) ? [] : ["\(path): \"\(string)\" is not a date"]
        case "date-time": return Self.isDateTime(string) ? [] : ["\(path): \"\(string)\" is not a date-time"]
        case "uuid": return UUID(uuidString: string) != nil ? [] : ["\(path): \"\(string)\" is not a uuid"]
        default: return []
        }
    }

    private func checkObject(_ object: [String: Any], _ schema: [String: Any], _ path: String) -> [String] {
        var problems: [String] = []
        let properties = schema["properties"] as? [String: Any] ?? [:]
        for name in schema["required"] as? [String] ?? [] where object[name] == nil { problems.append("\(path): missing required property \"\(name)\"") }
        for (name, element) in object {
            if let sub = properties[name] as? [String: Any] {
                problems += validate(element, against: sub, path: "\(path).\(name)")
            } else if let extra = schema["additionalProperties"] {
                if let flag = extra as? Bool, !flag, !Self.isBool(extra) || flag == false { problems.append("\(path): unexpected property \"\(name)\"") }
                else if let sub = extra as? [String: Any] { problems += validate(element, against: sub, path: "\(path).\(name)") }
            }
        }
        return problems
    }

    private func declaredProperties(_ schema: [String: Any]) -> Set<String> {
        var names = Set((schema["properties"] as? [String: Any] ?? [:]).keys)
        if let ref = schema["$ref"] as? String, let target = resolve(ref) { names.formUnion(declaredProperties(target)) }
        for key in ["allOf", "oneOf", "anyOf"] { for sub in schema[key] as? [[String: Any]] ?? [] { names.formUnion(declaredProperties(sub)) } }
        return names
    }

    private func resolve(_ ref: String) -> [String: Any]? {
        guard ref.hasPrefix("#/") else { return nil }
        var node: Any = root
        for part in ref.dropFirst(2).split(separator: "/") {
            guard let next = (node as? [String: Any])?[String(part)] else { return nil }
            node = next
        }
        return node as? [String: Any]
    }

    private func allowsNull(_ schema: [String: Any]) -> Bool {
        if Self.types(schema).contains("null") || (schema["nullable"] as? Bool) == true { return true }
        if schema["type"] == nil && schema["allOf"] == nil && schema["oneOf"] == nil && schema["anyOf"] == nil && schema["$ref"] == nil && schema["enum"] == nil { return true }
        if let allowed = schema["enum"] as? [Any], allowed.contains(where: { $0 is NSNull }) { return true }
        return false
    }

    static func types(_ schema: [String: Any]) -> [String] {
        if let one = schema["type"] as? String { return [one] }
        return schema["type"] as? [String] ?? []
    }

    /// Booleans are detected by their Swift type. Values must come from `parse(_:)` (or be native Swift literals):
    /// `JSONSerialization` yields NSNumber, whose boolean/number distinction differs between Darwin and swift-corelibs-foundation.
    static func isBool(_ value: Any) -> Bool {
        if value is NSNull { return false }
        #if canImport(Darwin)
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() }
        #endif
        return type(of: value) == Bool.self
    }
    /// Numeric value of a JSON number; nil for booleans and non-numbers.
    static func double(_ value: Any) -> Double? {
        if isBool(value) { return nil }
        switch value {
        case let v as Int: return Double(v)
        case let v as Double: return v
        case let v as Int64: return Double(v)
        case let v as UInt64: return Double(v)
        case let v as Float: return Double(v)
        case let v as NSNumber: return v.doubleValue
        default: return nil
        }
    }
    static func isNumber(_ value: Any) -> Bool { double(value) != nil }

    /// Parses JSON into native Swift values (Bool, Int, Double, String, NSNull, arrays, dictionaries) identically on every platform.
    static func parse(_ data: Data) throws -> Any {
        try JSONDecoder().decode(Node.self, from: data).value
    }
    private enum Node: Decodable {
        case null, bool(Bool), int(Int), double(Double), string(String), array([Node]), object([String: Node])
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Int.self) { self = .int(v) }
            else if let v = try? c.decode(Double.self) { self = .double(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([Node].self) { self = .array(v) }
            else { self = .object(try c.decode([String: Node].self)) }
        }
        var value: Any {
            switch self {
            case .null: return NSNull()
            case .bool(let v): return v
            case .int(let v): return v
            case .double(let v): return v
            case .string(let v): return v
            case .array(let v): return v.map(\.value)
            case .object(let v): return v.mapValues(\.value)
            }
        }
    }
    static func matches(_ type: String, _ value: Any) -> Bool {
        switch type {
        case "null": return value is NSNull
        case "string": return value is String
        case "boolean": return isBool(value)
        case "number": return isNumber(value)
        case "integer": return double(value).map { $0.rounded() == $0 } ?? false
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        default: return true
        }
    }
    static func kind(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if isBool(value) { return "boolean" }
        if isNumber(value) { return "number(\(value))" }
        if value is String { return "string" }
        if value is [String: Any] { return "object" }
        return value is [Any] ? "array" : "\(type(of: value))"
    }
    static func describe(_ value: Any) -> String { value is String ? "\"\(value)\"" : "\(value)" }
    static func equal(_ a: Any, _ b: Any) -> Bool {
        if a is NSNull || b is NSNull { return a is NSNull && b is NSNull }
        if isBool(a) != isBool(b) { return false }
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = double(a), let y = double(b) { return x == y }
        return false
    }
    static func isDate(_ string: String) -> Bool {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), (1...12).contains(m), d >= 1 else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return false }
        return calendar.dateComponents([.month, .day], from: date).day == d
    }
    static func isDateTime(_ string: String) -> Bool {
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: string) != nil || fractional.date(from: string) != nil
    }
}
