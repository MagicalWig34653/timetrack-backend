import Foundation

public enum VacationLimits {
    /// Upper bound for user-supplied half-day quantities (entitlement, carry-over, snapshot remainder).
    public static let maxHalfDays = 100_000
}

/// Overflow-safe integer helpers: stored values can never trap the process, results clamp instead.
func saturatingAdd(_ left: Int, _ right: Int) -> Int {
    let (value, overflow) = left.addingReportingOverflow(right)
    return overflow ? (right > 0 ? Int.max : Int.min) : value
}
func saturatingNegate(_ value: Int) -> Int { value == Int.min ? Int.max : -value }

public enum VacationEngine {
    /// Calendar days must include the built-in holidays for every year in the range.
    /// Missing models are errors by default; with `lenient` (service layer, so that history survives the end of a work
    /// model) days outside every model count as 0.
    public static func countedHalfDays(for absence: EngineAbsence, models: [EngineWorkModel],
                                       calendarDays: [CustomCalendarDay] = [],
                                       lenient: Bool = false) throws -> Int {
        try count(absence, models: models, days: calendarDays, from: absence.startDate, through: absence.endDate, lenient: lenient)
    }

    static func count(_ absence: EngineAbsence, models: [EngineWorkModel], days: [CustomCalendarDay],
                      from: LocalDate, through: LocalDate, lenient: Bool = false) throws -> Int {
        try absence.validate()
        try HolidayCalendar.validate(days)
        guard absence.kind == .vacation, absence.status.isActive else { return 0 }
        _ = try TimeEngine.selectModel(for: from, models: models)
        var date = max(from, absence.startDate)
        let end = min(through, absence.endDate)
        var result = 0
        while date <= end {
            if let model = try TimeEngine.selectModel(for: date, models: models) {
                if model.workdays.contains(HolidayCalendar.weekday(date)), !HolidayCalendar.isHoliday(date, days: days) {
                    // A half company day leaves at most one half day of vacation to consume.
                    let units = absence.isHalfDay(date) || HolidayCalendar.isHalfCompanyDay(date, days: days) ? 1 : 2
                    result = result.addingReportingOverflow(units).partialValue
                }
            } else if !lenient {
                throw TimeEngineError.missingModel(date)
            }
            if date == end { break }
            date = date.addingDays(1)
        }
        return result
    }

    /// Inclusive date intervals block even if both endpoint flags indicate half days.
    /// For an update, remove the stored version of that ID before validating the replacement.
    public static func validateNoOverlap(_ absences: [EngineAbsence]) throws {
        for absence in absences { try absence.validate() }
        guard Set(absences.map(\.id)).count == absences.count else { throw VacationEngineError.duplicateAbsenceID }
        let active = absences.filter { $0.status.isActive }.sorted { $0.startDate < $1.startDate }
        for (left, right) in zip(active, active.dropFirst()) where left.endDate >= right.startDate {
            throw VacationEngineError.absenceOverlap
        }
    }

    /// An annual projection including future bookings. The latest snapshot in this year wins.
    /// asOf affects only the informational carry-over expiry preview, not the annual balance.
    public static func balance(year: Int, settings: VacationSettings = VacationSettings(),
                               absences: [EngineAbsence], models: [EngineWorkModel],
                               snapshots: [VacationSnapshot] = [], adjustments: [VacationAdjustment] = [],
                               customCalendarDays: [CustomCalendarDay] = [], asOf: LocalDate? = nil,
                               lenient: Bool = false) throws -> VacationBalanceResult {
        let days = try HolidayCalendar.calendar(year: year, region: settings.region, companyDays: settings.companyDays) + customCalendarDays
        try HolidayCalendar.validate(days)
        guard settings.annualEntitlementHalfDays >= 0,
              settings.annualEntitlementHalfDays <= VacationLimits.maxHalfDays,
              settings.carryOverByYear.allSatisfy({ (1990...2100).contains($0.key) && (0...VacationLimits.maxHalfDays).contains($0.value) }) else {
            throw VacationEngineError.invalidSettings
        }
        var expiry: LocalDate?
        if let value = settings.carryOverExpiry {
            guard let parsed = try? LocalDate(String(format: "%04d-", year) + value) else {
                throw VacationEngineError.invalidSettings
            }
            expiry = parsed
        }
        try validateNoOverlap(absences)
        let annualSnapshots = snapshots.filter { $0.date.year == year }
        guard Set(annualSnapshots.map(\.date)).count == annualSnapshots.count else {
            throw VacationEngineError.duplicateSnapshotDate
        }
        let snapshot = annualSnapshots.max { $0.date < $1.date }
        let start = try snapshot?.date ?? LocalDate(year: year, month: 1, day: 1)
        let end = try LocalDate(year: year, month: 12, day: 31)
        let entitlement = snapshot == nil ? settings.annualEntitlementHalfDays : 0
        let carry = snapshot == nil ? settings.carryOverByYear[year, default: 0] : 0
        let adjustment = adjustments.filter { $0.date >= start && $0.date <= end }.reduce(0) { saturatingAdd($0, $1.halfDays) }
        var booked = 0, planned = 0, usedCarry = 0
        for absence in absences {
            let count = try count(absence, models: models, days: days, from: start, through: end, lenient: lenient)
            if absence.status.isBooked {
                booked = saturatingAdd(booked, count)
                if let asOf, carry > 0 {
                    usedCarry = saturatingAdd(usedCarry, try self.count(absence, models: models, days: days, from: start, through: min(asOf, end), lenient: lenient))
                }
            } else { planned = saturatingAdd(planned, count) }
        }
        let available = saturatingAdd(saturatingAdd(saturatingAdd(snapshot?.remainingHalfDays ?? 0, entitlement), saturatingAdd(carry, adjustment)), saturatingNegate(booked))
        let expired = expiry.map { expiry in
            asOf.map { $0 > expiry ? max(0, carry - usedCarry) : 0 } ?? 0
        } ?? 0
        return VacationBalanceResult(year: year, snapshotDate: snapshot?.date,
                                     snapshotRemainingHalfDays: snapshot?.remainingHalfDays,
                                     entitlementHalfDays: entitlement, carryOverHalfDays: carry,
                                     adjustmentHalfDays: adjustment, bookedHalfDays: booked, plannedHalfDays: planned,
                                     availableHalfDays: available, availableAfterPlannedHalfDays: saturatingAdd(available, saturatingNegate(planned)),
                                     expiredCarryOverHalfDays: expired)
    }
}
