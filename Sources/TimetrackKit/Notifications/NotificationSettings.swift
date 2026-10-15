import Foundation

enum NotificationKind {
    static let reminders = ["running_timer", "pending_suggestions", "report_gap", "document_submission"]
    static let all = reminders + ["system"]
}

struct NotificationCategorySettings: Codable, Equatable, Sendable {
    var inApp: Bool
    var push: Bool
    var thresholdMinutes: Int?
    var weekday: Int?
    var time: String?
}

struct NotificationSettingsDTO: Codable, Equatable, Sendable {
    var categories: [String: NotificationCategorySettings]
    var quietStart: String?
    var quietEnd: String?

    enum CodingKeys: String, CodingKey { case categories, quietStart, quietEnd }
    init(categories: [String: NotificationCategorySettings], quietStart: String?, quietEnd: String?) {
        self.categories = categories; self.quietStart = quietStart; self.quietEnd = quietEnd
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categories = try container.decode([String: NotificationCategorySettings].self, forKey: .categories)
        quietStart = try container.decodeIfPresent(String.self, forKey: .quietStart)
        quietEnd = try container.decodeIfPresent(String.self, forKey: .quietEnd)
    }
    /// Explicit nulls so clients can distinguish "no quiet hours".
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(categories, forKey: .categories)
        try container.encode(quietStart, forKey: .quietStart)
        try container.encode(quietEnd, forKey: .quietEnd)
    }

    /// ADR-0010 defaults: every category on, push flags on (effective only once a device is subscribed), quiet hours 22:00-07:00.
    static let defaults = NotificationSettingsDTO(categories: [
        "running_timer": .init(inApp: true, push: true, thresholdMinutes: 600, weekday: nil, time: nil),
        "pending_suggestions": .init(inApp: true, push: true, thresholdMinutes: nil, weekday: nil, time: nil),
        "report_gap": .init(inApp: true, push: true, thresholdMinutes: nil, weekday: 5, time: "15:00"),
        "document_submission": .init(inApp: true, push: true, thresholdMinutes: nil, weekday: nil, time: nil),
    ], quietStart: "22:00", quietEnd: "07:00")

    /// Validates a client document and returns the normalized settings. Missing categories fall back to the defaults.
    func validated() throws -> NotificationSettingsDTO {
        var result = Self.defaults.categories
        for (kind, value) in categories {
            guard NotificationKind.reminders.contains(kind) else { throw APIError.invalid }
            if let minutes = value.thresholdMinutes { guard kind == "running_timer", (30...1440).contains(minutes) else { throw APIError.invalid } }
            if let day = value.weekday { guard kind == "report_gap", (1...7).contains(day) else { throw APIError.invalid } }
            if let time = value.time { guard kind == "report_gap", Self.minutes(time) != nil else { throw APIError.invalid } }
            var merged = value
            let base = Self.defaults.categories[kind]!
            merged.thresholdMinutes = value.thresholdMinutes ?? base.thresholdMinutes
            merged.weekday = value.weekday ?? base.weekday
            merged.time = value.time ?? base.time
            result[kind] = merged
        }
        for value in [quietStart, quietEnd].compactMap({ $0 }) { guard Self.minutes(value) != nil else { throw APIError.invalid } }
        guard (quietStart == nil) == (quietEnd == nil) else { throw APIError.invalid }
        return .init(categories: result, quietStart: quietStart, quietEnd: quietEnd)
    }

    /// Minutes since midnight for `HH:mm` (00:00-23:59).
    static func minutes(_ value: String) -> Int? {
        let chars = Array(value.utf8)
        guard chars.count == 5, chars[2] == 58, [0, 1, 3, 4].allSatisfy({ (48...57).contains(chars[$0]) }) else { return nil }
        let hour = Int(chars[0] - 48) * 10 + Int(chars[1] - 48), minute = Int(chars[3] - 48) * 10 + Int(chars[4] - 48)
        guard hour < 24, minute < 60 else { return nil }
        return hour * 60 + minute
    }
}
