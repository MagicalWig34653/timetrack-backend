import Foundation
import Vapor

struct VacationSettingsDTO: Codable, Sendable {
    var configured: Bool?
    var region: String
    var annualEntitlementHalfDays: Int
    var carryOverByYear: [String: Int]?
    var carryOverExpiry: String?
    /// N4 (ADR-0029). Absent on PUT keeps the stored rules; the response always lists at least 24.12. and 31.12.
    var companyDays: [CompanyDayRule]?
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(CompanyDayRules.listed(companyDays ?? []), forKey: .companyDays)
        try c.encodeIfPresent(configured, forKey: .configured)
        try c.encode(region, forKey: .region); try c.encode(annualEntitlementHalfDays, forKey: .annualEntitlementHalfDays)
        try c.encode(carryOverByYear ?? [:], forKey: .carryOverByYear); try c.encode(carryOverExpiry, forKey: .carryOverExpiry)
    }
    enum CodingKeys: String, CodingKey { case configured, region, annualEntitlementHalfDays, carryOverByYear, carryOverExpiry, companyDays }
}
enum CompanyDayRules {
    static let maxRules = 12
    /// Stored rules plus the suggested dates (untreated) that are not configured, sorted by month and day.
    static func listed(_ rules: [CompanyDayRule]) -> [CompanyDayRule] {
        var all = rules
        for suggested in CompanyDayRule.suggested where !all.contains(where: { $0.month == suggested.month && $0.day == suggested.day }) { all.append(suggested) }
        return all.sorted { ($0.month, $0.day) < ($1.month, $1.day) }
    }
    /// Normalised rules or nil when invalid: valid non-leap dates, unique per date, bounded count and name length.
    static func validated(_ rules: [CompanyDayRule]) -> [CompanyDayRule]? {
        guard rules.count <= maxRules else { return nil }
        var seen = Set<Int>(), result: [CompanyDayRule] = []
        for rule in rules {
            guard (try? LocalDate(year: 2023, month: rule.month, day: rule.day)) != nil, seen.insert(rule.month * 100 + rule.day).inserted else { return nil }
            var name = rule.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if name?.isEmpty == true { name = nil }
            guard name?.fitsColumn(80) ?? true else { return nil }
            result.append(.init(month: rule.month, day: rule.day, treatment: rule.treatment, name: name))
        }
        return result.sorted { ($0.month, $0.day) < ($1.month, $1.day) }
    }
}
struct SnapshotInput: Decodable, Sendable { var date: LocalDate; var remainingHalfDays: Int }
struct VacationAdjustmentInput: Decodable, Sendable { var date: LocalDate; var halfDays: Int; var reason: String }

struct VacationBalanceDTO: Encodable, Sendable {
    var year: Int
    var snapshotDate: LocalDate?
    var snapshotRemainingHalfDays: Int?
    var entitlementHalfDays: Int
    var carryOverHalfDays: Int
    var adjustmentHalfDays: Int
    var bookedHalfDays: Int
    var plannedHalfDays: Int
    var availableHalfDays: Int
    var availableAfterPlannedHalfDays: Int
    init(_ r: VacationBalanceResult) {
        year = r.year; snapshotDate = r.snapshotDate; snapshotRemainingHalfDays = r.snapshotRemainingHalfDays
        entitlementHalfDays = r.entitlementHalfDays; carryOverHalfDays = r.carryOverHalfDays
        adjustmentHalfDays = r.adjustmentHalfDays; bookedHalfDays = r.bookedHalfDays; plannedHalfDays = r.plannedHalfDays
        availableHalfDays = r.availableHalfDays; availableAfterPlannedHalfDays = r.availableAfterPlannedHalfDays
    }
    // Explicit nulls for the optional snapshot fields keep the response shape stable.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(year, forKey: .year); try c.encode(snapshotDate, forKey: .snapshotDate)
        try c.encode(snapshotRemainingHalfDays, forKey: .snapshotRemainingHalfDays)
        try c.encode(entitlementHalfDays, forKey: .entitlementHalfDays); try c.encode(carryOverHalfDays, forKey: .carryOverHalfDays)
        try c.encode(adjustmentHalfDays, forKey: .adjustmentHalfDays); try c.encode(bookedHalfDays, forKey: .bookedHalfDays)
        try c.encode(plannedHalfDays, forKey: .plannedHalfDays); try c.encode(availableHalfDays, forKey: .availableHalfDays)
        try c.encode(availableAfterPlannedHalfDays, forKey: .availableAfterPlannedHalfDays)
    }
    enum CodingKeys: String, CodingKey {
        case year, snapshotDate, snapshotRemainingHalfDays, entitlementHalfDays, carryOverHalfDays, adjustmentHalfDays
        case bookedHalfDays, plannedHalfDays, availableHalfDays, availableAfterPlannedHalfDays
    }
}
struct VacationEntriesDTO: Encodable, Sendable {
    struct Snapshot: Encodable, Sendable { var id: UUID; var date: LocalDate; var remainingHalfDays: Int }
    struct Adjustment: Encodable, Sendable { var id: UUID; var date: LocalDate; var halfDays: Int; var reason: String }
    var snapshots: [Snapshot]
    var adjustments: [Adjustment]
}

struct AbsenceInputDTO: Decodable, Sendable {
    var kind: AbsenceKind
    var startDate: LocalDate
    var endDate: LocalDate
    var halfDayStart: Bool?
    var halfDayEnd: Bool?
    var status: AbsenceStatus
    var note: String?
    var documentStatus: String?
    var documentSubmittedOn: LocalDate?
    var documentReferenceStart: LocalDate?
    var documentReferenceEnd: LocalDate?
}
struct AbsenceDTO: Encodable, Sendable {
    var id: UUID
    var version: Int
    var kind: AbsenceKind
    var startDate: LocalDate
    var endDate: LocalDate
    var halfDayStart: Bool
    var halfDayEnd: Bool
    var status: AbsenceStatus
    var note: String?
    var documentStatus: String
    var documentSubmittedOn: LocalDate?
    var documentReferenceStart: LocalDate?
    var documentReferenceEnd: LocalDate?
    var countedHalfDays: Int
    /// Linked files that are stored and readable (the same set `GET /absences/{id}/attachments` lists).
    var attachmentCount: Int
}

struct CalendarDayDTO: Encodable, Sendable {
    var id: UUID?
    var startDate: LocalDate
    var endDate: LocalDate
    var name: String
    var kind: CalendarDayKind
    var source: CalendarDaySource
    /// nil for statutory and custom days; `half` or `full` for days derived from a company-day rule (ADR-0029).
    var companyTreatment: CompanyDayTreatment?
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(companyTreatment, forKey: .companyTreatment)
        try c.encode(id, forKey: .id); try c.encode(startDate, forKey: .startDate); try c.encode(endDate, forKey: .endDate)
        try c.encode(name, forKey: .name); try c.encode(kind, forKey: .kind); try c.encode(source, forKey: .source)
    }
    enum CodingKeys: String, CodingKey { case id, startDate, endDate, name, kind, source, companyTreatment }
}
struct CustomDayInput: Decodable, Sendable { var kind: CalendarDayKind; var startDate: LocalDate; var endDate: LocalDate; var name: String }

struct PlanDayInput: Decodable, Sendable {
    var mode: String; var placeId: UUID?; var note: String?
    /// K1 (ADR-0021): rough planned working window, local wall-clock "HH:mm" in the work model's time zone.
    var plannedStart: String?; var plannedEnd: String?; var plannedBreakMinutes: Int?
}
struct PlanDayDTO: Encodable, Sendable {
    var date: LocalDate; var mode: String; var placeId: UUID?; var note: String?
    var plannedStart: String?; var plannedEnd: String?; var plannedBreakMinutes: Int?
    /// Derived, never stored: (end - start - break), not negative; nil without planned times.
    var plannedSeconds: Int?
    init(date: LocalDate, mode: String, placeId: UUID?, note: String?, plannedStart: String? = nil, plannedEnd: String? = nil, plannedBreakMinutes: Int? = nil) {
        self.date = date; self.mode = mode; self.placeId = placeId; self.note = note
        self.plannedStart = plannedStart; self.plannedEnd = plannedEnd; self.plannedBreakMinutes = plannedBreakMinutes
        plannedSeconds = PlanTimes.seconds(start: plannedStart, end: plannedEnd, breakMinutes: plannedBreakMinutes)
    }
    init(_ row: PlanDayRecord) throws {
        self.init(date: try LocalDate(row.date), mode: row.mode, placeId: row.placeId, note: row.note,
                  plannedStart: row.plannedStart, plannedEnd: row.plannedEnd, plannedBreakMinutes: row.plannedBreakMinutes)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date); try c.encode(mode, forKey: .mode)
        try c.encode(placeId, forKey: .placeId); try c.encode(note, forKey: .note)
        try c.encode(plannedStart, forKey: .plannedStart); try c.encode(plannedEnd, forKey: .plannedEnd)
        try c.encode(plannedBreakMinutes, forKey: .plannedBreakMinutes); try c.encode(plannedSeconds, forKey: .plannedSeconds)
    }
    enum CodingKeys: String, CodingKey { case date, mode, placeId, note, plannedStart, plannedEnd, plannedBreakMinutes, plannedSeconds }
}

/// Planned times are plain wall-clock strings; the plan is rough, so no time zone or DST arithmetic is involved.
enum PlanTimes {
    static let maxBreakMinutes = 600
    /// Strict "HH:mm" (two digits each), 00:00...23:59.
    static func minutes(_ value: String) -> Int? {
        let bytes = Array(value.utf8)
        guard bytes.count == 5, bytes[2] == 58, [0, 1, 3, 4].allSatisfy({ (48...57).contains(bytes[$0]) }) else { return nil }
        let hour = Int(bytes[0] - 48) * 10 + Int(bytes[1] - 48), minute = Int(bytes[3] - 48) * 10 + Int(bytes[4] - 48)
        return hour < 24 && minute < 60 ? hour * 60 + minute : nil
    }
    static func seconds(start: String?, end: String?, breakMinutes: Int?) -> Int? {
        guard let start, let end, let from = minutes(start), let to = minutes(end), to > from else { return nil }
        return max(0, (to - from - (breakMinutes ?? 0)) * 60)
    }
}

struct PlanWeekDayInput: Decodable, Sendable {
    var date: LocalDate; var day: PlanDayInput
    init(from decoder: any Decoder) throws {
        date = try decoder.container(keyedBy: CodingKeys.self).decode(LocalDate.self, forKey: .date)
        day = try PlanDayInput(from: decoder)
    }
    enum CodingKeys: String, CodingKey { case date }
}
struct PlanWeekInput: Decodable, Sendable { var replace: Bool?; var days: [PlanWeekDayInput] }

/// One day of the week planner: the stored plan plus the rule-derived target and the blocking reason.
struct PlanWeekDayDTO: Encodable, Sendable {
    var date: LocalDate; var weekday: Int
    var targetSeconds: Int
    /// Effective planned seconds: 0 for a blocked day, nil without a plan or without planned times.
    var plannedSeconds: Int?
    /// holiday, vacation, sick or excused when that mark overrides the plan (a half-day vacation does not block).
    var blockedBy: String?
    var plan: PlanDayDTO?
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date); try c.encode(weekday, forKey: .weekday); try c.encode(targetSeconds, forKey: .targetSeconds)
        try c.encode(plannedSeconds, forKey: .plannedSeconds); try c.encode(blockedBy, forKey: .blockedBy); try c.encode(plan, forKey: .plan)
    }
    enum CodingKeys: String, CodingKey { case date, weekday, targetSeconds, plannedSeconds, blockedBy, plan }
}
struct PlanWeekDTO: Encodable, Sendable {
    struct Totals: Encodable, Sendable { var targetSeconds: Int; var plannedSeconds: Int; var differenceSeconds: Int }
    var week: String; var from: LocalDate; var to: LocalDate
    var days: [PlanWeekDayDTO]; var totals: Totals
}

struct ShareScopesDTO: Codable, Sendable, Equatable {
    var plan: Bool; var actual: Bool; var vacation: Bool
    init(plan: Bool = false, actual: Bool = false, vacation: Bool = false) { self.plan = plan; self.actual = actual; self.vacation = vacation }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decodeIfPresent(Bool.self, forKey: .plan) ?? false
        actual = try c.decodeIfPresent(Bool.self, forKey: .actual) ?? false
        vacation = try c.decodeIfPresent(Bool.self, forKey: .vacation) ?? false
    }
    enum CodingKeys: String, CodingKey { case plan, actual, vacation }
}
struct ShareCreateInput: Decodable, Sendable { var recipientHandle: String; var scopes: ShareScopesDTO }
struct ShareUpdateInput: Decodable, Sendable { var scopes: ShareScopesDTO }
struct ShareDTO: Encodable, Sendable { var id: UUID; var recipientHandle: String; var scopes: ShareScopesDTO; var createdAt: Date }
struct IncomingShareDTO: Encodable, Sendable { var id: UUID; var ownerDisplayName: String; var scopes: ShareScopesDTO }
struct SharedViewDTO: Encodable, Sendable {
    struct Plan: Encodable, Sendable {
        var date: LocalDate; var mode: String
        // Planned times belong to the plan scope; notes and places never leave the owner's account.
        var plannedStart: String?; var plannedEnd: String?; var plannedBreakMinutes: Int?; var plannedSeconds: Int?
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date); try c.encode(mode, forKey: .mode)
            // Without planned times the entry stays exactly as before (date and mode only).
            try c.encodeIfPresent(plannedStart, forKey: .plannedStart); try c.encodeIfPresent(plannedEnd, forKey: .plannedEnd)
            try c.encodeIfPresent(plannedBreakMinutes, forKey: .plannedBreakMinutes); try c.encodeIfPresent(plannedSeconds, forKey: .plannedSeconds)
        }
        enum CodingKeys: String, CodingKey { case date, mode, plannedStart, plannedEnd, plannedBreakMinutes, plannedSeconds }
    }
    struct Actual: Encodable, Sendable {
        var date: LocalDate; var evaluatedStart: Date?; var evaluatedEnd: Date?; var evaluatedWorkSeconds: Int
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date); try c.encode(evaluatedStart, forKey: .evaluatedStart)
            try c.encode(evaluatedEnd, forKey: .evaluatedEnd); try c.encode(evaluatedWorkSeconds, forKey: .evaluatedWorkSeconds)
        }
        enum CodingKeys: String, CodingKey { case date, evaluatedStart, evaluatedEnd, evaluatedWorkSeconds }
    }
    struct Vacation: Encodable, Sendable { var startDate: LocalDate; var endDate: LocalDate }
    // Scopes that are not shared stay nil and are therefore absent from the JSON.
    var plan: [Plan]?
    var actual: [Actual]?
    var vacation: [Vacation]?
}
