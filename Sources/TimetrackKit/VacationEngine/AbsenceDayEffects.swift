import Foundation

public enum AbsenceDayEffects {
    /// A non-none explicit mark wins. To explicitly suppress automatic effects with a none mark,
    /// pass hasExplicitMark=true; a preferences row containing only notes does not suppress them.
    public static func preferences(for date: LocalDate, models: [EngineWorkModel], absences: [EngineAbsence],
                                   calendarDays: [CustomCalendarDay] = [],
                                   explicit: DayPreferences = DayPreferences(),
                                   hasExplicitMark: Bool = false) throws -> DayPreferences {
        try VacationEngine.validateNoOverlap(absences)
        try HolidayCalendar.validate(calendarDays)
        if hasExplicitMark || explicit.mark != .none { return explicit }
        let model = try TimeEngine.selectModel(for: date, models: models)
        return apply(for: date, model: model, absences: absences, calendarDays: calendarDays, explicit: explicit)
    }

    /// The effect computation without validation; callers validate the inputs (once per range instead of per day).
    static func apply(for date: LocalDate, model: EngineWorkModel?, absences: [EngineAbsence],
                      calendarDays: [CustomCalendarDay], explicit: DayPreferences) -> DayPreferences {
        var result = explicit
        let isWorkday = model.map { $0.workdays.contains(HolidayCalendar.weekday(date)) } == true
        let holiday = isWorkday && HolidayCalendar.isHoliday(date, days: calendarDays)
        let halfCompany = isWorkday && HolidayCalendar.isHalfCompanyDay(date, days: calendarDays)
        if let absence = absences.first(where: { $0.contains(date) && $0.status.isBooked && $0.kind != .other }) {
            // Excused follows the current holiday precedence even for direct engine callers.
            // Existing vacation/sick callers retain the C8 behavior; REST applies the shared precedence.
            result.mark = absence.kind == .excused ? (holiday ? .holiday : .excused)
                : absence.kind == .sick ? .sick : .vacation
            result.creditSeconds = nil
            result.targetOverrideSeconds = nil
            // A half company day: vacation (full or half) takes the free half plus the vacation half, no work obligation remains.
            if absence.kind == .vacation && absence.isHalfDay(date) && !halfCompany {
                // A holiday never creates a half-day work obligation or vacation consumption.
                result.targetOverrideSeconds = holiday ? 0 : model.map { TimeEngine.target(for: date, model: $0) / 2 } ?? 0
            }
        } else if holiday {
            result.mark = .holiday
            result.creditSeconds = nil
            result.targetOverrideSeconds = nil
        } else if halfCompany, result.targetOverrideSeconds == nil, let model {
            // Half company day without absence: the target is halved; a user-set target override wins.
            result.targetOverrideSeconds = TimeEngine.target(for: date, model: model) / 2
        }
        return result
    }
}
