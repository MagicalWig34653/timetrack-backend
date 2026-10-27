import Foundation

/// Published rules are data, while recorded time remains unchanged. Warnings are informational.
public struct LegalWorkProfile: Codable, Equatable, Sendable {
    public struct BreakRule: Codable, Equatable, Sendable {
        public let afterSeconds: Int
        public let requiredSeconds: Int
    }
    public struct SchoolRule: Codable, Equatable, Sendable {
        public let fullDayLessons: Int
        public let fullDaysPerWeek: Int
        public let fullDayCreditSeconds: Int
        public let blockWeekLessons: Int
        public let blockWeekDays: Int
        public let blockWeekCreditSeconds: Int
        public let noWorkBeforeMinutes: Int
    }
    public let id: String
    public let name: String
    public let maxDailySeconds: Int?
    public let maxWeeklySeconds: Int?
    public let maxWorkdaysPerWeek: Int?
    public let breakRules: [BreakRule]
    public let minimumBreakPartSeconds: Int
    public let maximumContinuousSeconds: Int
    public let minimumRestSeconds: Int?
    public let restrictedWeekdays: [Int]
    public let school: SchoolRule?
    public let sources: [String]
    public let informationalOnly: Bool

    public static let adult = LegalWorkProfile(id: "arbzg-adult-de", name: "Erwachsene (ArbZG, Deutschland)",
        maxDailySeconds: nil, maxWeeklySeconds: nil, maxWorkdaysPerWeek: nil,
        breakRules: [.init(afterSeconds: 21_600, requiredSeconds: 1_800), .init(afterSeconds: 32_400, requiredSeconds: 2_700)],
        minimumBreakPartSeconds: 900, maximumContinuousSeconds: 21_600, minimumRestSeconds: nil,
        restrictedWeekdays: [], school: nil,
        sources: ["https://www.gesetze-im-internet.de/arbzg/__4.html"], informationalOnly: true)
    public static let minor = LegalWorkProfile(id: "jarbschg-minor-de", name: "Jugendliche unter 18 (JArbSchG, Deutschland)",
        maxDailySeconds: 28_800, maxWeeklySeconds: 144_000, maxWorkdaysPerWeek: 5,
        breakRules: [.init(afterSeconds: 16_200, requiredSeconds: 1_800), .init(afterSeconds: 21_600, requiredSeconds: 3_600)],
        minimumBreakPartSeconds: 900, maximumContinuousSeconds: 16_200, minimumRestSeconds: 43_200,
        restrictedWeekdays: [6, 7],
        school: .init(fullDayLessons: 6, fullDaysPerWeek: 1, fullDayCreditSeconds: 28_800, blockWeekLessons: 25,
                      blockWeekDays: 5, blockWeekCreditSeconds: 144_000, noWorkBeforeMinutes: 540),
        sources: ["https://www.gesetze-im-internet.de/jarbschg/__8.html", "https://www.gesetze-im-internet.de/jarbschg/__9.html",
                  "https://www.gesetze-im-internet.de/jarbschg/__11.html", "https://www.gesetze-im-internet.de/jarbschg/__13.html",
                  "https://www.gesetze-im-internet.de/jarbschg/__15.html", "https://www.gesetze-im-internet.de/jarbschg/__16.html",
                  "https://www.gesetze-im-internet.de/jarbschg/__17.html"], informationalOnly: true)
    public static let all = [adult, minor]
    public static func profile(_ id: String) -> LegalWorkProfile? { all.first { $0.id == id } }
}

public struct LegalWarning: Equatable, Codable, Sendable {
    public enum Code: String, Codable, Sendable {
        case dailyLimit = "daily_limit", weeklyLimit = "weekly_limit", fiveDayWeek = "five_day_week"
        case restPeriod = "rest_period", weekendWork = "weekend_work"
        case workAfterFullSchoolDay = "work_after_full_school_day"
        case workBeforeSchool = "work_before_school"
    }
    public let code: Code
    public init(_ code: Code) { self.code = code }
}
