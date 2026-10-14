import Foundation

public enum TimeEngineError: Error, Equatable, Sendable {
    case invalidDate, invalidTime, invalidModel, invalidSegment, invalidPreferences
    case overlappingModels, overlappingSegments, duplicateSegmentID, duplicateEvaluationDate
    case modelNotEffective, missingModel(LocalDate), missingEvaluation(LocalDate)
}

/// A Gregorian civil date, independent of the process time zone.
public struct LocalDate: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let instant = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: instant) == year,
              calendar.component(.month, from: instant) == month,
              calendar.component(.day, from: instant) == day else { throw TimeEngineError.invalidDate }
        self.year = year; self.month = month; self.day = day
    }

    public init(_ value: String) throws {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              value.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            throw TimeEngineError.invalidDate
        }
        try self.init(year: year, month: month, day: day)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    func addingDays(_ days: Int) -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        return Self.local(calendar.date(byAdding: .day, value: days, to: start)!, calendar: calendar)
    }
    static func local(_ instant: Date, calendar: Calendar) -> LocalDate {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return try! LocalDate(year: parts.year!, month: parts.month!, day: parts.day!)
    }
}

public struct LocalTime: Hashable, Sendable {
    public let hour: Int
    public let minute: Int
    public init(hour: Int, minute: Int) throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else { throw TimeEngineError.invalidTime }
        self.hour = hour; self.minute = minute
    }
    public var minutes: Int { hour * 60 + minute }
}

public struct FixedBreak: Equatable, Sendable {
    public let start: LocalTime
    public let end: LocalTime
    /// An end before the start belongs to the following civil date. Equal endpoints are invalid.
    public init(start: LocalTime, end: LocalTime) throws {
        guard start != end else { throw TimeEngineError.invalidTime }
        self.start = start; self.end = end
    }
}

public struct EngineWorkModel: Equatable, Sendable {
    public var id: UUID
    public var validFrom: LocalDate
    /// Inclusive, like validFrom. Adjacent versions must start on the next date.
    public var validTo: LocalDate?
    public var timezone: String
    public var weeklyTargetSeconds: Int
    /// ISO weekdays: Monday = 1, Sunday = 7.
    public var workdays: Set<Int>
    public var dailyTargetSeconds: [Int: Int]
    public var travelCountsAsWork: Bool
    public var roundingEnabled: Bool
    public var roundingMinutes: Int
    public var schoolFullDayThresholdSeconds: Int
    public var schoolCreditSeconds: Int?
    public var dayBoundaryMinutes: Int
    public var fixedBreaks: [FixedBreak]

    public init(id: UUID = UUID(), validFrom: LocalDate, validTo: LocalDate? = nil,
                timezone: String = "Europe/Berlin", weeklyTargetSeconds: Int, workdays: Set<Int>,
                dailyTargetSeconds: [Int: Int] = [:], travelCountsAsWork: Bool = true,
                roundingEnabled: Bool = true, roundingMinutes: Int = 15,
                schoolFullDayThresholdSeconds: Int = 10_800, schoolCreditSeconds: Int? = nil,
                dayBoundaryMinutes: Int = 0, fixedBreaks: [FixedBreak] = []) {
        self.id = id; self.validFrom = validFrom; self.validTo = validTo; self.timezone = timezone
        self.weeklyTargetSeconds = weeklyTargetSeconds; self.workdays = workdays
        self.dailyTargetSeconds = dailyTargetSeconds; self.travelCountsAsWork = travelCountsAsWork
        self.roundingEnabled = roundingEnabled; self.roundingMinutes = roundingMinutes
        self.schoolFullDayThresholdSeconds = schoolFullDayThresholdSeconds; self.schoolCreditSeconds = schoolCreditSeconds
        self.dayBoundaryMinutes = dayBoundaryMinutes; self.fixedBreaks = fixedBreaks
    }

    public func validate() throws {
        guard TimeZone(identifier: timezone) != nil, weeklyTargetSeconds >= 0,
              workdays.allSatisfy({ (1...7).contains($0) }),
              dailyTargetSeconds.allSatisfy({ (1...7).contains($0.key) && $0.value >= 0 }),
              (1...60).contains(roundingMinutes), (0...719).contains(dayBoundaryMinutes),
              schoolFullDayThresholdSeconds >= 0, schoolCreditSeconds.map({ $0 >= 0 }) ?? true,
              validTo.map({ $0 >= validFrom }) ?? true else { throw TimeEngineError.invalidModel }
    }
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timezone)!
        return value
    }
    func contains(_ date: LocalDate) -> Bool { date >= validFrom && (validTo.map { date <= $0 } ?? true) }
}

public enum EngineSegmentKind: String, Codable, Sendable { case work, travel, school }
public enum EngineSegmentSource: String, Codable, Sendable {
    case timer, manual, automation, suggestion
    case imported = "import"
}

/// Effective times drive evaluation. Raw times and transport metadata are passed through unchanged.
public struct EngineSegment: Equatable, Codable, Sendable {
    public var id: UUID
    public var kind: EngineSegmentKind
    public var startedAt: Date
    public var endedAt: Date?
    public var voided: Bool
    public var rawStartedAt: Date
    public var rawEndedAt: Date?
    public var source: EngineSegmentSource
    public var version: Int
    public var needsReview: Bool
    public var placeId: UUID?
    public var note: String?
    public var revisions: Int

    public init(id: UUID = UUID(), kind: EngineSegmentKind = .work, start: Date, end: Date? = nil,
                voided: Bool = false, rawStartedAt: Date? = nil, rawEndedAt: Date? = nil,
                source: EngineSegmentSource = .manual, version: Int = 1, needsReview: Bool = false,
                placeId: UUID? = nil, note: String? = nil, revisions: Int = 0) {
        self.id = id; self.kind = kind; self.startedAt = start; self.endedAt = end; self.voided = voided
        self.rawStartedAt = rawStartedAt ?? start; self.rawEndedAt = rawEndedAt
        self.source = source; self.version = version; self.needsReview = needsReview
        self.placeId = placeId; self.note = note; self.revisions = revisions
    }

    // The contract requires these nullable keys even for a running segment.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind)
        try c.encode(startedAt, forKey: .startedAt); try c.encode(endedAt, forKey: .endedAt)
        try c.encode(rawStartedAt, forKey: .rawStartedAt); try c.encode(rawEndedAt, forKey: .rawEndedAt)
        try c.encode(voided, forKey: .voided); try c.encode(source, forKey: .source)
        try c.encode(version, forKey: .version); try c.encode(needsReview, forKey: .needsReview)
        try c.encodeIfPresent(placeId, forKey: .placeId); try c.encodeIfPresent(note, forKey: .note)
        try c.encode(revisions, forKey: .revisions)
    }
}

public enum DayMarkKind: String, Codable, Sendable {
    case none, holiday, vacation, sick
    case schoolCredit = "school_credit"
}
public struct DayPreferences: Equatable, Sendable {
    public var mark: DayMarkKind
    public var creditSeconds: Int?
    public var skipFixedBreaks: Bool
    public var note: String?
    public var targetOverrideSeconds: Int?
    public init(mark: DayMarkKind = .none, creditSeconds: Int? = nil, skipFixedBreaks: Bool = false, note: String? = nil,
                targetOverrideSeconds: Int? = nil) {
        self.mark = mark; self.creditSeconds = creditSeconds; self.skipFixedBreaks = skipFixedBreaks; self.note = note
        self.targetOverrideSeconds = targetOverrideSeconds
    }
}
public struct BreakHint: Equatable, Codable, Sendable {
    public enum Code: String, Codable, Sendable {
        case breakMissing30 = "break_missing_30"
        case breakMissing45 = "break_missing_45"
        case breakPartTooShort = "break_part_too_short"
        case workOver6hWithoutBreak = "work_over_6h_without_break"
    }
    public let code: Code
    public init(code: Code) { self.code = code }
}

/// Field names map directly to contract v0.2.1 DayEvaluation. Encode dates as ISO 8601 in the adapter.
public struct DayEvaluationResult: Equatable, Encodable, Sendable {
    public let date: LocalDate
    public let modelId: UUID?
    public let mark: DayMarkKind
    public let skipFixedBreaks: Bool
    public let targetSeconds: Int
    public let rawWorkSeconds: Int
    public let breakDeductionSeconds: Int
    public let startAdjustSeconds: Int
    public let endAdjustSeconds: Int
    public let evaluatedWorkSeconds: Int
    public let creditSeconds: Int
    public var deltaSeconds: Int { evaluatedWorkSeconds + creditSeconds - targetSeconds }
    public let evaluatedStart: Date?
    public let evaluatedEnd: Date?
    public let provisional: Bool
    public let segmentIds: [UUID]
    public let segments: [EngineSegment]
    public let markCreditSeconds: Int?
    public let note: String?
    public let breakHints: [BreakHint]

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date); try c.encode(modelId, forKey: .modelId)
        try c.encode(mark, forKey: .mark); try c.encode(skipFixedBreaks, forKey: .skipFixedBreaks)
        try c.encode(targetSeconds, forKey: .targetSeconds); try c.encode(rawWorkSeconds, forKey: .rawWorkSeconds)
        try c.encode(breakDeductionSeconds, forKey: .breakDeductionSeconds)
        try c.encode(startAdjustSeconds, forKey: .startAdjustSeconds); try c.encode(endAdjustSeconds, forKey: .endAdjustSeconds)
        try c.encode(evaluatedWorkSeconds, forKey: .evaluatedWorkSeconds); try c.encode(creditSeconds, forKey: .creditSeconds)
        try c.encode(deltaSeconds, forKey: .deltaSeconds)
        try c.encode(evaluatedStart, forKey: .evaluatedStart); try c.encode(evaluatedEnd, forKey: .evaluatedEnd)
        try c.encode(provisional, forKey: .provisional); try c.encode(segmentIds, forKey: .segmentIds)
        try c.encode(segments, forKey: .segments); try c.encode(markCreditSeconds, forKey: .markCreditSeconds)
        try c.encode(note, forKey: .note); try c.encode(breakHints, forKey: .breakHints)
    }
    private enum CodingKeys: String, CodingKey {
        case date, modelId, mark, skipFixedBreaks, targetSeconds, rawWorkSeconds, breakDeductionSeconds
        case startAdjustSeconds, endAdjustSeconds, evaluatedWorkSeconds, creditSeconds, deltaSeconds
        case evaluatedStart, evaluatedEnd, provisional, segmentIds, segments, markCreditSeconds, note, breakHints
    }
}

public struct AccountAdjustment: Equatable, Sendable {
    public let date: LocalDate
    public let seconds: Int
    public init(date: LocalDate, seconds: Int) { self.date = date; self.seconds = seconds }
}
public struct TimeAccountResult: Equatable, Encodable, Sendable {
    public let asOf: LocalDate
    public let accountStart: LocalDate?
    public let balanceSeconds: Int
    public let openingSeconds: Int
    public let adjustmentSeconds: Int
    public let provisional: Bool
}
