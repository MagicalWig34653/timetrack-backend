import Foundation
import Fluent
import Vapor

// V2 (ADR-0025): loads the account's data, hands it to the pure `VacationSuggestionEngine` and shapes the response.

enum VacationSuggestionLimits {
    static let maxSpanMonths = 18
    static let defaultMaxVacationDays = 10, maxMaxVacationDays = 60
    static let defaultMinDaysOff = 4, maxMinDaysOff = 60
    static let defaultLimit = 20, maxLimit = 100
}

extension LocalDate {
    /// Calendar-month arithmetic; a day beyond the target month's length clamps to its last day.
    func addingMonths(_ months: Int) throws -> LocalDate {
        let index = year * 12 + (month - 1) + months
        let targetYear = index / 12, targetMonth = index % 12 + 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = calendar.date(from: DateComponents(year: targetYear, month: targetMonth, day: 1))!
        let length = calendar.range(of: .day, in: .month, for: first)!.count
        return try LocalDate(year: targetYear, month: targetMonth, day: min(day, length))
    }
}

struct VacationSuggestionQuery: Sendable {
    var from: LocalDate?, to: LocalDate?
    var maxVacationDays: Int?, minDaysOff: Int?, limit: Int?
}

struct VacationSuggestionsDTO: Encodable, Sendable {
    struct Budget: Encodable, Sendable {
        var entitlementDays: Double, takenDays: Double, plannedDays: Double, remainingDays: Double
    }
    struct Holiday: Encodable, Sendable { var date: LocalDate; var name: String }
    struct Period: Encodable, Sendable { var startDate: LocalDate; var endDate: LocalDate; var name: String }
    struct Conflict: Encodable, Sendable { var date: LocalDate; var type: String }
    struct Item: Encodable, Sendable {
        var id: String, kind: String
        var start: LocalDate, end: LocalDate
        var vacationDates: [LocalDate]
        var vacationDaysNeeded: Int, totalDaysOff: Int
        var efficiency: Double
        var holidays: [Holiday]
        var schoolHolidays: [Period]
        var conflicts: [Conflict]
        var fitsBudget: Bool
        var remainingAfter: Double
    }
    var from: LocalDate, to: LocalDate
    var budget: Budget
    var suggestions: [Item]
}

extension VacationService {
    func suggestions(_ query: VacationSuggestionQuery, now: Date = Date()) async throws -> VacationSuggestionsDTO {
        let models = try await scope.models.list().map { try $0.engine() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: models.last?.timezone ?? "Europe/Berlin") ?? TimeZone(secondsFromGMT: 0)!
        let today = LocalDate.local(now, calendar: calendar)
        let from = query.from ?? today
        let to = try query.to ?? LocalDate(year: from.year + 1, month: 12, day: 31)
        let maxDays = query.maxVacationDays ?? VacationSuggestionLimits.defaultMaxVacationDays
        let minOff = query.minDaysOff ?? VacationSuggestionLimits.defaultMinDaysOff
        let limit = query.limit ?? VacationSuggestionLimits.defaultLimit
        guard (1...VacationSuggestionLimits.maxMaxVacationDays).contains(maxDays),
              (1...VacationSuggestionLimits.maxMinDaysOff).contains(minOff),
              (1...VacationSuggestionLimits.maxLimit).contains(limit),
              (1990...2100).contains(from.year), (1990...2100).contains(to.year) else { throw APIError.invalid }
        guard to >= from else { throw APIError.invalid }
        guard to <= (try from.addingMonths(VacationSuggestionLimits.maxSpanMonths)) else { throw APIError(.badRequest, "range_too_large") }

        let region = try await settings().region
        var holidays: [LocalDate: String] = [:]
        for year in from.year...to.year {
            for day in try HolidayCalendar.holidays(year: year, region: region) { holidays[day.startDate] = day.name }
        }
        var periods: [VacationSuggestionPeriod] = []
        for custom in try await customDays() where custom.endDate >= from && custom.startDate <= to {
            switch custom.kind {
            case .schoolHoliday: periods.append(.init(startDate: custom.startDate, endDate: custom.endDate, name: custom.name))
            case .holiday:
                var day = max(custom.startDate, from)
                while day <= min(custom.endDate, to) { holidays[day] = holidays[day] ?? custom.name; day = day.addingDays(1) }
            }
        }
        var vacationDays = Set<LocalDate>(), otherAbsenceDays = Set<LocalDate>()
        for absence in try await engineAbsences(window: from...to) where absence.status.isActive {
            var day = max(absence.startDate, from)
            while day <= min(absence.endDate, to) {
                if absence.kind == .vacation { vacationDays.insert(day) } else { otherAbsenceDays.insert(day) }
                day = day.addingDays(1)
            }
        }
        var schoolDays = Set<LocalDate>(), plannedWorkDays = Set<LocalDate>()
        for row in try await PlanDayRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
            .filter(\.$date >= from.description).filter(\.$date <= to.description).all() {
            let day = try LocalDate(row.date)
            if row.mode == "school" { schoolDays.insert(day) } else if row.mode != "off" { plannedWorkDays.insert(day) }
        }

        var remaining: [Int: Double] = [:]
        var budget: VacationSuggestionsDTO.Budget?
        for year in from.year...to.year {
            let balance = try await self.balance(year: year)
            remaining[year] = Double(balance.availableAfterPlannedHalfDays) / 2
            if year == from.year {
                budget = .init(entitlementDays: Double(balance.availableHalfDays + balance.bookedHalfDays) / 2,
                               takenDays: Double(balance.bookedHalfDays) / 2, plannedDays: Double(balance.plannedHalfDays) / 2,
                               remainingDays: Double(balance.availableAfterPlannedHalfDays) / 2)
            }
        }
        let found = VacationSuggestionEngine.suggest(.init(
            from: from, to: to, maxVacationDays: maxDays, minDaysOff: minOff, limit: limit,
            isWorkday: { date in
                guard let model = models.first(where: { $0.contains(date) }) else { return (1...5).contains(HolidayCalendar.weekday(date)) }
                return model.workdays.contains(HolidayCalendar.weekday(date))
            },
            holidays: holidays, schoolHolidays: periods, vacationDays: vacationDays, otherAbsenceDays: otherAbsenceDays,
            schoolDays: schoolDays, plannedWorkDays: plannedWorkDays, remainingDaysByYear: remaining))
        return .init(from: from, to: to, budget: budget!, suggestions: found.map { item in
            .init(id: item.id, kind: item.kind.rawValue, start: item.start, end: item.end, vacationDates: item.vacationDates,
                  vacationDaysNeeded: item.vacationDaysNeeded, totalDaysOff: item.totalDaysOff, efficiency: item.efficiency,
                  holidays: item.holidays.map { .init(date: $0.date, name: $0.name) },
                  schoolHolidays: item.schoolHolidays.map { .init(startDate: $0.startDate, endDate: $0.endDate, name: $0.name) },
                  conflicts: item.conflicts.map { .init(date: $0.date, type: $0.type.rawValue) },
                  fitsBudget: item.fitsBudget, remainingAfter: item.remainingAfter)
        })
    }
}
