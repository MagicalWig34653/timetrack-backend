import Foundation
import Vapor

struct VacationSettingsDTO: Codable, Sendable {
    var configured: Bool?
    var region: String
    var annualEntitlementHalfDays: Int
    var carryOverByYear: [String: Int]?
    var carryOverExpiry: String?
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(configured, forKey: .configured)
        try c.encode(region, forKey: .region); try c.encode(annualEntitlementHalfDays, forKey: .annualEntitlementHalfDays)
        try c.encode(carryOverByYear ?? [:], forKey: .carryOverByYear); try c.encode(carryOverExpiry, forKey: .carryOverExpiry)
    }
    enum CodingKeys: String, CodingKey { case configured, region, annualEntitlementHalfDays, carryOverByYear, carryOverExpiry }
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
}

struct CalendarDayDTO: Encodable, Sendable {
    var id: UUID?
    var startDate: LocalDate
    var endDate: LocalDate
    var name: String
    var kind: CalendarDayKind
    var source: CalendarDaySource
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(startDate, forKey: .startDate); try c.encode(endDate, forKey: .endDate)
        try c.encode(name, forKey: .name); try c.encode(kind, forKey: .kind); try c.encode(source, forKey: .source)
    }
    enum CodingKeys: String, CodingKey { case id, startDate, endDate, name, kind, source }
}
struct CustomDayInput: Decodable, Sendable { var kind: CalendarDayKind; var startDate: LocalDate; var endDate: LocalDate; var name: String }

struct PlanDayInput: Decodable, Sendable {
    var mode: String; var placeId: UUID?; var note: String?
}
struct PlanDayDTO: Encodable, Sendable {
    var date: LocalDate; var mode: String; var placeId: UUID?; var note: String?
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date); try c.encode(mode, forKey: .mode)
        try c.encode(placeId, forKey: .placeId); try c.encode(note, forKey: .note)
    }
    enum CodingKeys: String, CodingKey { case date, mode, placeId, note }
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
    struct Plan: Encodable, Sendable { var date: LocalDate; var mode: String }
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
