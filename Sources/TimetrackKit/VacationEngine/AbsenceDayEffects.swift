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
        var result = explicit
        let holiday = model.map { $0.workdays.contains(HolidayCalendar.weekday(date)) } == true
            && HolidayCalendar.isHoliday(date, days: calendarDays)
        if let absence = absences.first(where: { $0.contains(date) && $0.status.isBooked && $0.kind != .other }) {
            result.mark = absence.kind == .sick ? .sick : .vacation
            result.creditSeconds = nil
            result.targetOverrideSeconds = nil
            if absence.kind == .vacation && absence.isHalfDay(date) {
                // A holiday never creates a half-day work obligation or vacation consumption.
                result.targetOverrideSeconds = holiday ? 0 : model.map { TimeEngine.target(for: date, model: $0) / 2 } ?? 0
            }
        } else if holiday {
            result.mark = .holiday
            result.creditSeconds = nil
            result.targetOverrideSeconds = nil
        }
        return result
    }
}
