import Foundation

/// Builders for the JSON Schemas advertised by `tools/list`. Every object schema forbids unknown members.
enum McpSchema {
    static func object(_ properties: [String: McpJSON] = [:], required: [String] = []) -> McpJSON {
        var schema: [String: McpJSON] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }
    static func string(_ description: String, maxLength: Int? = nil, enumeration: [String]? = nil, format: String? = nil) -> McpJSON {
        var schema: [String: McpJSON] = ["type": "string", "description": .string(description)]
        if let maxLength { schema["maxLength"] = .int(maxLength) }
        if let enumeration { schema["enum"] = .array(enumeration.map { .string($0) }) }
        if let format { schema["format"] = .string(format) }
        return .object(schema)
    }
    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> McpJSON {
        var schema: [String: McpJSON] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .int(minimum) }
        if let maximum { schema["maximum"] = .int(maximum) }
        return .object(schema)
    }
    static func boolean(_ description: String) -> McpJSON { ["type": "boolean", "description": .string(description)] }
    static func array(_ description: String, items: McpJSON, maxItems: Int) -> McpJSON {
        ["type": "array", "description": .string(description), "items": items, "maxItems": .int(maxItems)]
    }
    static func date(_ description: String) -> McpJSON { string(description + " (ISO date YYYY-MM-DD)", format: "date") }
    static func dateTime(_ description: String) -> McpJSON { string(description + " (ISO 8601 instant, e.g. 2026-10-12T06:07:00Z)", format: "date-time") }
    static func uuid(_ description: String) -> McpJSON { string(description, format: "uuid") }
    static func nullable(_ schema: McpJSON) -> McpJSON {
        guard case .object(var members) = schema, let type = members["type"] else { return schema }
        members["type"] = .array([type, "null"])
        return .object(members)
    }
}

/// Validates tool arguments against the subset of JSON Schema used by `McpSchema`.
/// Returns a human-readable problem or nil. Messages never echo argument values.
enum McpSchemaValidator {
    static func validate(_ value: McpJSON, against schema: McpJSON, path: String = "arguments") -> String? {
        guard case .object(let rules) = schema else { return nil }
        let types: [String]
        switch rules["type"] {
        case .string(let t)?: types = [t]
        case .array(let list)?: types = list.compactMap(\.string)
        default: types = []
        }
        if !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) {
            return "\(path) must be of type \(types.joined(separator: " or "))"
        }
        if case .null = value { return nil }
        if case .array(let allowed)? = rules["enum"], !allowed.contains(value) {
            return "\(path) must be one of " + allowed.compactMap(\.string).joined(separator: ", ")
        }
        switch value {
        case .string(let text):
            if case .int(let limit)? = rules["maxLength"], text.unicodeScalars.count > limit { return "\(path) is longer than \(limit) characters" }
            if case .int(let limit)? = rules["minLength"], text.unicodeScalars.count < limit { return "\(path) is shorter than \(limit) characters" }
            if case .string(let format)? = rules["format"], !formatOK(text, format) { return "\(path) must be a valid \(format)" }
        case .int(let number):
            if case .int(let limit)? = rules["minimum"], number < limit { return "\(path) must be at least \(limit)" }
            if case .int(let limit)? = rules["maximum"], number > limit { return "\(path) must be at most \(limit)" }
        case .object(let members):
            let properties = rules["properties"]?.object ?? [:]
            for name in (rules["required"].flatMap { v -> [McpJSON]? in if case .array(let a) = v { return a }; return nil } ?? []).compactMap(\.string)
            where members[name] == nil { return "\(path).\(name) is required" }
            for (name, member) in members.sorted(by: { $0.key < $1.key }) {
                guard let child = properties[name] else {
                    if rules["additionalProperties"] == .bool(false) { return "\(path).\(name) is not allowed" }
                    continue
                }
                if let problem = validate(member, against: child, path: path + "." + name) { return problem }
            }
        case .array(let members):
            if case .int(let limit)? = rules["maxItems"], members.count > limit { return "\(path) has too many items" }
            if let itemSchema = rules["items"] {
                for (index, member) in members.enumerated() {
                    if let problem = validate(member, against: itemSchema, path: "\(path)[\(index)]") { return problem }
                }
            }
        default: break
        }
        return nil
    }

    private static func matches(_ value: McpJSON, type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("integer", .int), ("boolean", .bool), ("object", .object), ("array", .array), ("null", .null): return true
        case ("number", .int), ("number", .double): return true
        default: return false
        }
    }

    private static func formatOK(_ text: String, _ format: String) -> Bool {
        switch format {
        case "date": return text.count == 10 && (try? LocalDate(text)) != nil
        case "date-time": return timeInstant(text) != nil
        case "uuid": return UUID(uuidString: text) != nil
        default: return true
        }
    }
}
