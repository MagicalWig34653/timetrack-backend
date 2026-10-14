import Foundation

public enum VacationEngineError: Error, Equatable, Sendable {
    case unsupportedYear, unsupportedRegion, invalidRange, invalidSettings
    case absenceOverlap, duplicateAbsenceID, duplicateSnapshotDate
}

public enum AbsenceKind: String, Codable, Sendable { case vacation, sick, other }
public enum AbsenceStatus: String, Codable, Sendable {
    case planned, requested, approved, rejected, cancelled, taken
    public var isActive: Bool { self != .rejected && self != .cancelled }
    public var isBooked: Bool { self == .approved || self == .taken }
}

/// One current version per ID; historical revisions must not be supplied to the engine.
public struct EngineAbsence: Equatable, Sendable {
    public var id: UUID
    public var kind: AbsenceKind
    public var startDate: LocalDate
    public var endDate: LocalDate
    public var status: AbsenceStatus
    public var halfDayStart: Bool
    public var halfDayEnd: Bool

    public init(id: UUID = UUID(), kind: AbsenceKind = .vacation, startDate: LocalDate, endDate: LocalDate,
                status: AbsenceStatus = .planned, halfDayStart: Bool = false, halfDayEnd: Bool = false) {
        self.id = id; self.kind = kind; self.startDate = startDate; self.endDate = endDate
        self.status = status; self.halfDayStart = halfDayStart; self.halfDayEnd = halfDayEnd
    }
    func validate() throws {
        guard startDate <= endDate else { throw VacationEngineError.invalidRange }
    }
    func contains(_ date: LocalDate) -> Bool { startDate <= date && date <= endDate }
    func isHalfDay(_ date: LocalDate) -> Bool {
        (date == startDate && halfDayStart) || (date == endDate && halfDayEnd)
    }
}

public enum CalendarDayKind: String, Codable, Sendable {
    case holiday
    case schoolHoliday = "school_holiday"
}
public enum CalendarDaySource: String, Codable, Sendable { case builtin, custom }

/// Built-in single days and caller-supplied custom ranges share the contract representation.
public struct CustomCalendarDay: Equatable, Codable, Sendable {
    public var id: UUID?
    public var startDate: LocalDate
    public var endDate: LocalDate
    public var name: String
    public var kind: CalendarDayKind
    public var source: CalendarDaySource
    public init(id: UUID? = nil, startDate: LocalDate, endDate: LocalDate, name: String,
                kind: CalendarDayKind = .holiday, source: CalendarDaySource = .custom) {
        self.id = id; self.startDate = startDate; self.endDate = endDate
        self.name = name; self.kind = kind; self.source = source
    }
}

public struct VacationSettings: Equatable, Sendable {
    public var region: String
    public var annualEntitlementHalfDays: Int
    public var carryOverByYear: [Int: Int]
    /// MM-DD; informational only, never an automatic deduction.
    public var carryOverExpiry: String?
    public init(region: String = "DE-ST", annualEntitlementHalfDays: Int = 60,
                carryOverByYear: [Int: Int] = [:], carryOverExpiry: String? = nil) {
        self.region = region; self.annualEntitlementHalfDays = annualEntitlementHalfDays
        self.carryOverByYear = carryOverByYear; self.carryOverExpiry = carryOverExpiry
    }
}
public struct VacationSnapshot: Equatable, Sendable {
    public var date: LocalDate
    public var remainingHalfDays: Int
    public init(date: LocalDate, remainingHalfDays: Int) {
        self.date = date; self.remainingHalfDays = remainingHalfDays
    }
}
public struct VacationAdjustment: Equatable, Sendable {
    public var date: LocalDate
    public var halfDays: Int
    public init(date: LocalDate, halfDays: Int) { self.date = date; self.halfDays = halfDays }
}

public struct VacationBalanceResult: Equatable, Encodable, Sendable {
    public let year: Int
    public let snapshotDate: LocalDate?
    public let snapshotRemainingHalfDays: Int?
    public let entitlementHalfDays: Int
    public let carryOverHalfDays: Int
    public let adjustmentHalfDays: Int
    public let bookedHalfDays: Int
    public let plannedHalfDays: Int
    public let availableHalfDays: Int
    public let availableAfterPlannedHalfDays: Int
    /// Domain-only preview: remaining carry used by booked vacation first, never deducted.
    public let expiredCarryOverHalfDays: Int
}
