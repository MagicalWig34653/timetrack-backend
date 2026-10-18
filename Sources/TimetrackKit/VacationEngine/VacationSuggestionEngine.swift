import Foundation
import Crypto

// V2 (ADR-0025): pure, deterministic vacation recommendations. No database, clock or network access: everything the
// algorithm needs is passed in, so the same input always yields the same list.

public enum VacationSuggestionKind: String, Codable, Sendable, CaseIterable {
    case bridge
    case holidayCluster = "holiday_cluster"
    case schoolHolidayExtension = "school_holiday_extension"
    case longBreak = "long_break"
}

public enum VacationSuggestionConflictType: String, Codable, Sendable, CaseIterable {
    case absence
    case schoolDay = "school_day"
    case plan
    case alreadyVacation = "already_vacation"
}

public struct VacationSuggestionHoliday: Equatable, Sendable { public var date: LocalDate; public var name: String }
public struct VacationSuggestionPeriod: Equatable, Sendable {
    public var startDate: LocalDate; public var endDate: LocalDate; public var name: String
    public init(startDate: LocalDate, endDate: LocalDate, name: String) { self.startDate = startDate; self.endDate = endDate; self.name = name }
}
public struct VacationSuggestionConflict: Equatable, Sendable {
    public var date: LocalDate; public var type: VacationSuggestionConflictType
}

public struct VacationSuggestionInput: Sendable {
    public var from: LocalDate
    public var to: LocalDate
    public var maxVacationDays: Int
    public var minDaysOff: Int
    public var limit: Int
    /// Working weekday (ISO 1...7) according to the work model valid on that date; days without a model use Monday to Friday.
    public var isWorkday: @Sendable (LocalDate) -> Bool
    /// Public holidays by date (built-in and custom, kind holiday). A holiday on a non-working day changes nothing.
    public var holidays: [LocalDate: String]
    /// User-entered school-holiday periods (there are no built-in school-holiday dates).
    public var schoolHolidays: [VacationSuggestionPeriod]
    /// Days covered by an active vacation absence (any status except rejected/cancelled; half days count as full).
    public var vacationDays: Set<LocalDate>
    /// Days covered by an active non-vacation absence (sick, excused, other).
    public var otherAbsenceDays: Set<LocalDate>
    /// Plan days with mode school.
    public var schoolDays: Set<LocalDate>
    /// Plan days with planned work (any mode except off and school).
    public var plannedWorkDays: Set<LocalDate>
    /// Remaining vacation days per calendar year (halves possible). A missing year means 0.
    public var remainingDaysByYear: [Int: Double]

    public init(from: LocalDate, to: LocalDate, maxVacationDays: Int = 10, minDaysOff: Int = 4, limit: Int = 20,
                isWorkday: @escaping @Sendable (LocalDate) -> Bool,
                holidays: [LocalDate: String] = [:], schoolHolidays: [VacationSuggestionPeriod] = [],
                vacationDays: Set<LocalDate> = [], otherAbsenceDays: Set<LocalDate> = [], schoolDays: Set<LocalDate> = [],
                plannedWorkDays: Set<LocalDate> = [], remainingDaysByYear: [Int: Double] = [:]) {
        self.from = from; self.to = to; self.maxVacationDays = maxVacationDays; self.minDaysOff = minDaysOff; self.limit = limit
        self.isWorkday = isWorkday; self.holidays = holidays; self.schoolHolidays = schoolHolidays
        self.vacationDays = vacationDays; self.otherAbsenceDays = otherAbsenceDays; self.schoolDays = schoolDays
        self.plannedWorkDays = plannedWorkDays; self.remainingDaysByYear = remainingDaysByYear
    }
}

public struct VacationSuggestion: Equatable, Sendable {
    public var id: String
    public var kind: VacationSuggestionKind
    public var start: LocalDate
    public var end: LocalDate
    public var vacationDates: [LocalDate]
    public var vacationDaysNeeded: Int
    public var totalDaysOff: Int
    public var efficiency: Double
    public var holidays: [VacationSuggestionHoliday]
    public var schoolHolidays: [VacationSuggestionPeriod]
    public var conflicts: [VacationSuggestionConflict]
    public var fitsBudget: Bool
    /// Remaining days of the year of `start` after taking this window's vacation dates of that year.
    public var remainingAfter: Double
}

public enum VacationSuggestionEngine {
    /// Stable identifier: SHA-256 over start, end and the vacation dates (first 16 hex characters).
    static func identifier(start: LocalDate, end: LocalDate, vacationDates: [LocalDate]) -> String {
        let text = ([start, end] + vacationDates).map(\.description).joined(separator: "|")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private struct Candidate {
        var start: LocalDate; var end: LocalDate; var cost: Int; var total: Int
        var firstCost: Int; var lastCost: Int   // indices into the cost-day list
    }

    public static func suggest(_ input: VacationSuggestionInput) -> [VacationSuggestion] {
        guard input.from <= input.to, input.maxVacationDays >= 1, input.limit >= 1 else { return [] }
        let minDaysOff = max(1, input.minDaysOff)
        // Cost days: working days that are neither holidays nor already vacation. Everything else inside a window is free.
        var costDays: [LocalDate] = []
        var date = input.from
        let span = input.from.distance(to: input.to)
        for _ in 0...span {
            if input.isWorkday(date), input.holidays[date] == nil, !input.vacationDays.contains(date) { costDays.append(date) }
            date = date.addingDays(1)
        }
        guard !costDays.isEmpty else { return [] }

        // A window is fully determined by its first and last cost day: it stretches over all free days around them
        // (up to the neighbouring cost days), so it is maximal for its cost and cheaper variants never beat it.
        var candidates: [Candidate] = []
        for first in costDays.indices {
            let start = first == 0 ? input.from : costDays[first - 1].addingDays(1)
            let maxLast = min(costDays.count - 1, first + input.maxVacationDays - 1)
            for last in first...maxLast {
                let end = last == costDays.count - 1 ? input.to : costDays[last + 1].addingDays(-1)
                let total = start.distance(to: end) + 1
                if total >= minDaysOff {
                    candidates.append(Candidate(start: start, end: end, cost: last - first + 1, total: total, firstCost: first, lastCost: last))
                }
            }
        }
        // Efficiency (total / cost) compared exactly by cross-multiplication, then more days off, then earlier start.
        candidates.sort {
            let left = $0.total * $1.cost, right = $1.total * $0.cost
            if left != right { return left > right }
            if $0.total != $1.total { return $0.total > $1.total }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var chosen: [Candidate] = []
        for candidate in candidates {
            if chosen.count == input.limit { break }
            if chosen.contains(where: { $0.start <= candidate.end && candidate.start <= $0.end }) { continue }
            chosen.append(candidate)
        }
        return chosen.map { build($0, costDays: costDays, input: input) }
    }

    private static func build(_ candidate: Candidate, costDays: [LocalDate], input: VacationSuggestionInput) -> VacationSuggestion {
        let vacationDates = Array(costDays[candidate.firstCost...candidate.lastCost])
        var holidays: [VacationSuggestionHoliday] = []
        var conflicts: [VacationSuggestionConflict] = []
        var date = candidate.start
        for _ in 0..<candidate.total {
            if let name = input.holidays[date] { holidays.append(.init(date: date, name: name)) }
            if input.vacationDays.contains(date) { conflicts.append(.init(date: date, type: .alreadyVacation)) }
            if input.otherAbsenceDays.contains(date) { conflicts.append(.init(date: date, type: .absence)) }
            if input.schoolDays.contains(date) { conflicts.append(.init(date: date, type: .schoolDay)) }
            if input.plannedWorkDays.contains(date) { conflicts.append(.init(date: date, type: .plan)) }
            date = date.addingDays(1)
        }
        let schoolHolidays = input.schoolHolidays.filter { $0.startDate <= candidate.end && candidate.start <= $0.endDate }
            .sorted { $0.startDate == $1.startDate ? $0.name < $1.name : $0.startDate < $1.startDate }
        let kind: VacationSuggestionKind
        if !schoolHolidays.isEmpty { kind = .schoolHolidayExtension }
        else if !holidays.isEmpty && candidate.cost <= 2 { kind = .bridge }
        else if !holidays.isEmpty { kind = .holidayCluster }
        else { kind = .longBreak }

        var neededByYear: [Int: Int] = [:]
        for day in vacationDates { neededByYear[day.year, default: 0] += 1 }
        let fits = neededByYear.allSatisfy { Double($0.value) <= (input.remainingDaysByYear[$0.key] ?? 0) }
        let startYear = candidate.start.year
        let remainingAfter = (input.remainingDaysByYear[startYear] ?? 0) - Double(neededByYear[startYear] ?? 0)
        let efficiency = (Double(candidate.total) / Double(candidate.cost) * 100).rounded() / 100
        return VacationSuggestion(
            id: identifier(start: candidate.start, end: candidate.end, vacationDates: vacationDates), kind: kind,
            start: candidate.start, end: candidate.end, vacationDates: vacationDates, vacationDaysNeeded: candidate.cost,
            totalDaysOff: candidate.total, efficiency: efficiency, holidays: holidays, schoolHolidays: schoolHolidays,
            conflicts: conflicts, fitsBudget: fits, remainingAfter: remainingAfter)
    }
}
