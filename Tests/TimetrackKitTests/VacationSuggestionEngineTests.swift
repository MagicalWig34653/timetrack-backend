import Foundation
import XCTest
@testable import TimetrackKit

/// V2 (ADR-0025): the pure suggestion algorithm. 2026 reference dates (region DE-ST unless stated):
/// Ascension Thu 14 May, Corpus Christi Thu 4 June (DE-BY), German Unity Sat 3 Oct, Christmas Fri 25 Dec, New Year 2027 Fri 1 Jan.
final class VacationSuggestionEngineTests: XCTestCase {
    private func d(_ value: String) -> LocalDate { try! LocalDate(value) }

    private func holidays(_ region: String, years: ClosedRange<Int>) -> [LocalDate: String] {
        var result: [LocalDate: String] = [:]
        for year in years { for day in try! HolidayCalendar.holidays(year: year, region: region) { result[day.startDate] = day.name } }
        return result
    }
    private func input(_ from: String, _ to: String, region: String = "DE-ST", max: Int = 10, minOff: Int = 4, limit: Int = 50,
                       workdays: Set<Int> = [1, 2, 3, 4, 5], remaining: [Int: Double]? = nil,
                       configure: (inout VacationSuggestionInput) -> Void = { _ in }) -> VacationSuggestionInput {
        let first = d(from), last = d(to)
        var value = VacationSuggestionInput(
            from: first, to: last, maxVacationDays: max, minDaysOff: minOff, limit: limit,
            isWorkday: { workdays.contains(HolidayCalendar.weekday($0)) },
            holidays: holidays(region, years: first.year...last.year),
            remainingDaysByYear: remaining ?? Dictionary(uniqueKeysWithValues: (first.year...last.year).map { ($0, 30.0) }))
        configure(&value)
        return value
    }

    func testBridgeDayAfterAscension() {
        let result = VacationSuggestionEngine.suggest(input("2026-05-01", "2026-05-31"))
        let bridge = try! XCTUnwrap(result.first { $0.start == d("2026-05-14") })
        XCTAssertEqual(bridge.end, d("2026-05-17"))
        XCTAssertEqual(bridge.vacationDates, [d("2026-05-15")])
        XCTAssertEqual(bridge.vacationDaysNeeded, 1); XCTAssertEqual(bridge.totalDaysOff, 4)
        XCTAssertEqual(bridge.efficiency, 4); XCTAssertEqual(bridge.kind, .bridge)
        XCTAssertEqual(bridge.holidays, [.init(date: d("2026-05-14"), name: "Christi Himmelfahrt")])
        XCTAssertTrue(bridge.fitsBudget); XCTAssertEqual(bridge.remainingAfter, 29)
        XCTAssertGreaterThanOrEqual(try! XCTUnwrap(result.first).efficiency, bridge.efficiency, "best efficiency first")
    }

    func testFourDayWeekUsesItsOwnWorkingDays() {
        // Monday to Thursday: Friday is free anyway, so only Wednesday bridges to the long weekend.
        let result = VacationSuggestionEngine.suggest(input("2026-05-01", "2026-05-31", workdays: [1, 2, 3, 4]))
        let top = try! XCTUnwrap(result.first)
        XCTAssertEqual(top.start, d("2026-05-13")); XCTAssertEqual(top.end, d("2026-05-17"))
        XCTAssertEqual(top.vacationDates, [d("2026-05-13")]); XCTAssertEqual(top.totalDaysOff, 5)
        XCTAssertFalse(result.contains { $0.vacationDates.contains(d("2026-05-15")) }, "a free Friday never costs vacation")
        // Without the model's free Friday the Friday would have been the bridge.
        let fiveDay = VacationSuggestionEngine.suggest(input("2026-05-01", "2026-05-31"))
        XCTAssertTrue(fiveDay.contains { $0.vacationDates == [d("2026-05-15")] })
    }

    func testHolidayOnWeekendCostsAndSavesNothing() {
        // Sat 3 Oct: only a Friday vacation day links it to the weekend; the holiday is listed but the Monday stays a workday.
        let result = VacationSuggestionEngine.suggest(input("2026-09-28", "2026-10-11", minOff: 3))
        let friday = try! XCTUnwrap(result.first { $0.vacationDates == [d("2026-10-02")] })
        XCTAssertEqual(friday.start, d("2026-10-02")); XCTAssertEqual(friday.end, d("2026-10-04"))
        XCTAssertEqual(friday.holidays.map(\.date), [d("2026-10-03")])
        XCTAssertEqual(friday.vacationDaysNeeded, 1)
        XCTAssertFalse(result.contains { $0.vacationDates.contains(d("2026-10-05")) && $0.vacationDaysNeeded == 0 })
    }

    func testRegionDifferences() {
        let bavaria = VacationSuggestionEngine.suggest(input("2026-06-01", "2026-06-14", region: "DE-BY"))
        XCTAssertEqual(bavaria.first?.vacationDates, [d("2026-06-05")])
        XCTAssertEqual(bavaria.first?.holidays.map(\.name), ["Fronleichnam"])
        let anhalt = VacationSuggestionEngine.suggest(input("2026-06-01", "2026-06-14", region: "DE-ST"))
        XCTAssertFalse(anhalt.contains { $0.vacationDaysNeeded == 1 }, "no holiday, so no single-day bridge reaches four days")
    }

    func testYearBoundaryAndPerYearBudget() {
        // Christmas Fri 25 Dec to New Year Fri 1 Jan: four working days in between.
        let tight = VacationSuggestionEngine.suggest(input("2026-12-14", "2027-01-10", max: 4, minOff: 10, remaining: [2026: 3, 2027: 30]))
        let cluster = try! XCTUnwrap(tight.first { $0.start == d("2026-12-25") })
        XCTAssertEqual(cluster.end, d("2027-01-03"))
        XCTAssertEqual(cluster.vacationDates, ["2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31"].map(d))
        XCTAssertEqual(cluster.totalDaysOff, 10); XCTAssertEqual(cluster.efficiency, 2.5)
        XCTAssertEqual(cluster.holidays.map(\.name), ["1. Weihnachtstag", "2. Weihnachtstag", "Neujahr"])
        XCTAssertEqual(cluster.kind, .holidayCluster)
        XCTAssertFalse(cluster.fitsBudget, "4 days in 2026 but only 3 left that year")
        XCTAssertEqual(cluster.remainingAfter, -1)
        let roomy = VacationSuggestionEngine.suggest(input("2026-12-14", "2027-01-10", max: 4, minOff: 10, remaining: [2026: 10, 2027: 0]))
        XCTAssertTrue(try! XCTUnwrap(roomy.first { $0.start == d("2026-12-25") }).fitsBudget, "the 2027 budget is irrelevant for dates in 2026")
        // A window that spans the new year needs budget in both years.
        let span = VacationSuggestionEngine.suggest(input("2026-12-14", "2027-01-10", max: 4, minOff: 10, remaining: [2026: 10, 2027: 0]))
        XCTAssertTrue(span.allSatisfy { item in
            let crossing = item.vacationDates.contains { $0.year == 2027 }
            return !crossing || !item.fitsBudget
        })
    }

    func testNoEntitlementConfigured() {
        let result = VacationSuggestionEngine.suggest(input("2026-05-01", "2026-05-31", remaining: [:]))
        XCTAssertFalse(result.isEmpty, "suggestions are still shown, only marked")
        XCTAssertTrue(result.allSatisfy { !$0.fitsBudget })
        XCTAssertEqual(result.first?.remainingAfter, -1)
    }

    func testBudgetExhaustedMarksLargerWindowsOnly() {
        let result = VacationSuggestionEngine.suggest(input("2026-05-01", "2026-05-31", remaining: [2026: 2.5]))
        XCTAssertTrue(result.contains { $0.vacationDaysNeeded <= 2 && $0.fitsBudget })
        XCTAssertTrue(result.filter { $0.vacationDaysNeeded >= 3 }.allSatisfy { !$0.fitsBudget })
        let one = try! XCTUnwrap(result.first { $0.vacationDaysNeeded == 1 })
        XCTAssertEqual(one.remainingAfter, 1.5)
    }

    func testSuggestionsNeverOverlapAreUniqueAndRespectLimit() {
        let result = VacationSuggestionEngine.suggest(input("2026-01-01", "2027-06-30", limit: 15))
        XCTAssertEqual(result.count, 15)
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
        for (index, left) in result.enumerated() {
            for right in result[(index + 1)...] { XCTAssertFalse(left.start <= right.end && right.start <= left.end, "\(left.id) overlaps \(right.id)") }
        }
        for (left, right) in zip(result, result.dropFirst()) {
            XCTAssertGreaterThanOrEqual(left.efficiency, right.efficiency)
            XCTAssertTrue(left.vacationDaysNeeded <= 10 && left.totalDaysOff >= 4)
        }
        XCTAssertEqual(VacationSuggestionEngine.suggest(input("2026-01-01", "2027-06-30", limit: 15)), result, "deterministic")
    }

    func testIdIsStableHashOfWindow() {
        let first = VacationSuggestionEngine.suggest(input("2026-05-01", "2026-05-31")).first { $0.vacationDates == [d("2026-05-15")] }!
        let again = VacationSuggestionEngine.suggest(input("2026-04-20", "2026-06-30")).first { $0.vacationDates == first.vacationDates }
        XCTAssertEqual(again?.id, first.id)
        XCTAssertEqual(first.id, VacationSuggestionEngine.identifier(start: first.start, end: first.end, vacationDates: first.vacationDates))
        XCTAssertEqual(first.id.count, 16)
    }

    func testAlreadyVacationIsNeverRecommendedAgain() {
        let result = VacationSuggestionEngine.suggest(input("2026-05-01", "2026-05-31") { $0.vacationDays = [self.d("2026-05-15")] })
        XCTAssertFalse(result.contains { $0.vacationDates.contains(d("2026-05-15")) })
        // The booked day is free inside a neighbouring window and flagged.
        let touching = try! XCTUnwrap(result.first { $0.start <= d("2026-05-15") && d("2026-05-15") <= $0.end })
        XCTAssertTrue(touching.conflicts.contains(.init(date: d("2026-05-15"), type: .alreadyVacation)))
    }

    func testConflictsAreMarkedNotHidden() {
        let result = VacationSuggestionEngine.suggest(input("2026-05-01", "2026-05-31") {
            $0.schoolDays = [self.d("2026-05-15")]; $0.plannedWorkDays = [self.d("2026-05-15")]; $0.otherAbsenceDays = [self.d("2026-05-15")]
        })
        let bridge = try! XCTUnwrap(result.first { $0.vacationDates == [d("2026-05-15")] })
        XCTAssertEqual(bridge.conflicts.map(\.type), [.absence, .schoolDay, .plan])
        XCTAssertTrue(bridge.conflicts.allSatisfy { $0.date == d("2026-05-15") })
    }

    func testSchoolHolidayExtension() {
        let period = VacationSuggestionPeriod(startDate: d("2026-07-06"), endDate: d("2026-07-17"), name: "Sommerferien")
        let result = VacationSuggestionEngine.suggest(input("2026-07-01", "2026-07-31", max: 5, minOff: 7) { $0.schoolHolidays = [period] })
        let top = try! XCTUnwrap(result.first)
        XCTAssertEqual(top.kind, .schoolHolidayExtension)
        XCTAssertEqual(top.schoolHolidays, [period])
        let without = VacationSuggestionEngine.suggest(input("2026-07-01", "2026-07-31", max: 5, minOff: 7))
        XCTAssertEqual(without.first?.kind, .longBreak)
    }

    func testEmptyAndInvalidInput() {
        XCTAssertTrue(VacationSuggestionEngine.suggest(input("2026-05-31", "2026-05-01")).isEmpty)
        XCTAssertTrue(VacationSuggestionEngine.suggest(input("2026-05-01", "2026-05-31", max: 0)).isEmpty)
        // All days non-working: nothing needs vacation.
        XCTAssertTrue(VacationSuggestionEngine.suggest(input("2026-05-01", "2026-05-31", workdays: [])).isEmpty)
        // Window cap: with one vacation day at most, a two-week block cannot be suggested.
        let capped = VacationSuggestionEngine.suggest(input("2026-08-03", "2026-08-16", max: 1, minOff: 1))
        XCTAssertTrue(capped.allSatisfy { $0.vacationDaysNeeded == 1 })
    }
}
