import Foundation
import XCTest
@testable import TimetrackKit

final class VacationEngineTests: XCTestCase {
    private func date(_ value: String) throws -> LocalDate { try LocalDate(value) }
    private func model(_ workdays: Set<Int> = [1, 2, 3, 4, 5]) throws -> EngineWorkModel {
        EngineWorkModel(validFrom: try date("1990-01-01"), weeklyTargetSeconds: 138_600, workdays: workdays)
    }
    private func absence(_ start: String, _ end: String? = nil, status: AbsenceStatus = .approved,
                         kind: AbsenceKind = .vacation, first: Bool = false, last: Bool = false) throws -> EngineAbsence {
        EngineAbsence(kind: kind, startDate: try date(start), endDate: try date(end ?? start),
                      status: status, halfDayStart: first, halfDayEnd: last)
    }

    func testSaxonyAnhaltExactHolidayTables() throws {
        let movable = [
            2024: ["03-29", "04-01", "05-09", "05-20"],
            2025: ["04-18", "04-21", "05-29", "06-09"],
            2026: ["04-03", "04-06", "05-14", "05-25"],
            2027: ["03-26", "03-29", "05-06", "05-17"]
        ]
        let fixed = ["01-01", "01-06", "05-01", "10-03", "10-31", "12-25", "12-26"]
        let names: Set<String> = ["Neujahr", "Heilige Drei Könige", "Karfreitag", "Ostermontag", "Tag der Arbeit",
                                  "Christi Himmelfahrt", "Pfingstmontag", "Tag der Deutschen Einheit", "Reformationstag",
                                  "1. Weihnachtstag", "2. Weihnachtstag"]
        for (year, dates) in movable {
            let holidays = try HolidayCalendar.holidays(year: year)
            XCTAssertEqual(holidays.map { $0.startDate.description }, (fixed + dates).map { "\(year)-\($0)" }.sorted())
            XCTAssertEqual(Set(holidays.map(\.name)), names)
            XCTAssertTrue(holidays.allSatisfy { $0.startDate == $0.endDate && $0.source == .builtin && $0.kind == .holiday })
        }
    }

    func testRegionalDifferencesAndIntroductionYears() throws {
        let cases: [(String, Int, String, Bool)] = [
            ("DE-BY", 2026, "06-04", true), ("DE-BY", 2026, "08-15", false),
            ("DE-SL", 2026, "08-15", true), ("DE-BY", 2026, "11-01", true),
            ("DE-NW", 2026, "01-06", false), ("DE-NW", 2026, "06-04", true),
            ("DE-SN", 2026, "11-18", true), ("DE-ST", 2026, "11-18", false),
            ("DE-BE", 2018, "03-08", false), ("DE-BE", 2019, "03-08", true),
            ("DE-MV", 2022, "03-08", false), ("DE-MV", 2023, "03-08", true),
            ("DE-TH", 2018, "09-20", false), ("DE-TH", 2019, "09-20", true),
            ("DE-HH", 2016, "10-31", false), ("DE-HH", 2018, "10-31", true),
            ("DE", 2017, "10-31", true), ("DE", 2018, "10-31", false),
            ("DE-BB", 2026, "04-05", true), ("DE-BB", 2026, "05-24", true),
            ("DE-ST", 2026, "04-05", false)
        ]
        for (region, year, suffix, expected) in cases {
            XCTAssertEqual(try HolidayCalendar.holidays(year: year, region: region).contains {
                $0.startDate.description == "\(year)-\(suffix)"
            }, expected, "\(region) \(year)-\(suffix)")
        }
    }

    func testAllRegionsAndYearBoundaries() throws {
        XCTAssertEqual(HolidayCalendar.supportedRegions.count, 17)
        for year in 1990...2100 {
            let easter = try HolidayCalendar.easterSunday(year: year)
            XCTAssertEqual(HolidayCalendar.weekday(easter), 7)
            XCTAssertTrue(easter >= (try LocalDate(year: year, month: 3, day: 22)))
            XCTAssertTrue(easter <= (try LocalDate(year: year, month: 4, day: 25)))
            for region in HolidayCalendar.supportedRegions {
                let days = try HolidayCalendar.holidays(year: year, region: region)
                XCTAssertEqual(Set(days.map(\.name)).count, days.count)
                XCTAssertTrue(days.allSatisfy { $0.startDate.year == year })
            }
        }
        XCTAssertEqual(try HolidayCalendar.easterSunday(year: 2000), try date("2000-04-23"))
        XCTAssertEqual(try HolidayCalendar.easterSunday(year: 2100), try date("2100-03-28"))
        XCTAssertThrowsError(try HolidayCalendar.holidays(year: 1989))
        XCTAssertThrowsError(try HolidayCalendar.holidays(year: 2101))
        XCTAssertThrowsError(try HolidayCalendar.holidays(year: 2026, region: "DE-XX"))
    }

    func testCountingTable() throws {
        let cases: [(String, String, Bool, Bool, Int)] = [
            ("2026-04-01", "2026-04-07", false, false, 6),
            ("2026-04-04", "2026-04-05", false, false, 0),
            ("2026-06-01", "2026-06-05", true, true, 8),
            ("2026-06-01", "2026-06-01", true, true, 1),
            ("2026-06-01", "2026-06-01", false, true, 1),
            ("2026-06-01", "2026-06-01", true, false, 1),
            ("2026-04-03", "2026-04-03", true, true, 0),
            ("2024-02-28", "2024-03-01", false, false, 6)
        ]
        for (start, end, first, last, expected) in cases {
            let item = try absence(start, end, first: first, last: last)
            XCTAssertEqual(try VacationEngine.countedHalfDays(for: item, models: [model()],
                calendarDays: HolidayCalendar.holidays(year: item.startDate.year)), expected)
        }
        XCTAssertEqual(try VacationEngine.countedHalfDays(for: absence("2026-06-01", "2026-06-05"),
                                                          models: [model([1, 2, 3, 4])]), 8)
    }

    func testCountingStatusesAndCustomRanges() throws {
        for status in [AbsenceStatus.planned, .requested, .approved, .taken, .rejected, .cancelled] {
            for kind in [AbsenceKind.vacation, .sick, .other] {
                let expected = kind == .vacation && status.isActive ? 2 : 0
                XCTAssertEqual(try VacationEngine.countedHalfDays(for: absence("2026-06-01", status: status, kind: kind),
                                                                  models: [model()]), expected)
            }
        }
        let holiday = try CustomCalendarDay(startDate: date("2026-06-01"), endDate: date("2026-06-02"), name: "Betriebsfeiertag")
        var school = holiday; school.kind = .schoolHoliday
        let item = try absence("2026-06-01", "2026-06-03")
        XCTAssertEqual(try VacationEngine.countedHalfDays(for: item, models: [model()], calendarDays: [holiday, holiday]), 2)
        XCTAssertEqual(try VacationEngine.countedHalfDays(for: item, models: [model()], calendarDays: [school]), 6)
    }

    func testModelChangesAndMissingModels() throws {
        var first = try model(); first.validTo = try date("2026-06-02")
        var next = try model([1, 2, 4]); next.validFrom = try date("2026-06-03")
        let item = try absence("2026-06-01", "2026-06-05")
        XCTAssertEqual(try VacationEngine.countedHalfDays(for: item, models: [next, first]), 6)
        XCTAssertThrowsError(try VacationEngine.countedHalfDays(for: item, models: [first]))
        XCTAssertThrowsError(try VacationEngine.countedHalfDays(for: item, models: [first, model()]))
    }

    func testAnnualBalanceStatusTransitionAndPreview() throws {
        let settings = VacationSettings(carryOverByYear: [2026: 8, 2027: 4])
        let booked = try absence("2026-06-01", "2026-06-05")
        let others = try [absence("2026-06-08", status: .planned), absence("2026-06-09", status: .requested),
                          absence("2026-06-10", status: .rejected), absence("2026-06-11", status: .cancelled),
                          absence("2026-06-12", kind: .sick)]
        let result = try VacationEngine.balance(year: 2026, settings: settings, absences: [booked] + others, models: [model()],
            adjustments: [VacationAdjustment(date: date("2026-01-01"), halfDays: -3)])
        XCTAssertEqual(result.entitlementHalfDays, 60)
        XCTAssertEqual(result.carryOverHalfDays, 8)
        XCTAssertEqual(result.bookedHalfDays, 10)
        XCTAssertEqual(result.plannedHalfDays, 4)
        XCTAssertEqual(result.availableHalfDays, 55)
        XCTAssertEqual(result.availableAfterPlannedHalfDays, 51)
        var taken = booked; taken.status = .taken
        XCTAssertEqual(try VacationEngine.balance(year: 2026, absences: [booked], models: [model()]),
                       try VacationEngine.balance(year: 2026, absences: [taken], models: [model()]))
        XCTAssertNil(result.snapshotRemainingHalfDays)
    }

    func testSnapshotReplacesHistoryAndClipsSpanningAbsence() throws {
        let settings = VacationSettings(carryOverByYear: [2026: 8, 2027: 4])
        let snapshots = try [VacationSnapshot(date: date("2026-01-01"), remainingHalfDays: 99),
                             VacationSnapshot(date: date("2026-06-03"), remainingHalfDays: 20)]
        let result = try VacationEngine.balance(year: 2026, settings: settings,
            absences: [absence("2026-06-01", "2026-06-05", first: true, last: true),
                       absence("2026-05-01", "2026-05-08", status: .planned)], models: [model()], snapshots: snapshots,
            adjustments: [VacationAdjustment(date: date("2026-06-02"), halfDays: 100),
                          VacationAdjustment(date: date("2026-06-03"), halfDays: -2)])
        XCTAssertEqual(result.snapshotDate, try date("2026-06-03"))
        XCTAssertEqual(result.snapshotRemainingHalfDays, 20)
        XCTAssertEqual(result.entitlementHalfDays, 0)
        XCTAssertEqual(result.carryOverHalfDays, 0)
        XCTAssertEqual(result.bookedHalfDays, 5)
        XCTAssertEqual(result.plannedHalfDays, 0)
        XCTAssertEqual(result.availableHalfDays, 13)
        let next = try VacationEngine.balance(year: 2027, settings: settings, absences: [], models: [], snapshots: snapshots)
        XCTAssertEqual(next.availableHalfDays, 64)
        XCTAssertNil(next.snapshotDate)
    }

    func testYearClippingAndExpiryPreviewDoesNotDeduct() throws {
        let item = try absence("2025-12-31", "2026-01-02", first: true, last: true)
        XCTAssertEqual(try VacationEngine.balance(year: 2026, absences: [item], models: [model()]).bookedHalfDays, 1)
        let settings = VacationSettings(carryOverByYear: [2026: 8], carryOverExpiry: "03-31")
        for (asOf, expired) in [("2026-03-31", 0), ("2026-04-01", 6)] {
            let result = try VacationEngine.balance(year: 2026, settings: settings,
                absences: [absence("2026-02-02"), absence("2026-06-01")], models: [model()], asOf: date(asOf))
            XCTAssertEqual(result.expiredCarryOverHalfDays, expired)
            XCTAssertEqual(result.availableHalfDays, 64)
        }
    }

    func testOverlapInclusiveAndInactiveIgnored() throws {
        let first = try absence("2026-06-01", "2026-06-03", last: true)
        for kind in [AbsenceKind.vacation, .sick, .other] {
            XCTAssertThrowsError(try VacationEngine.validateNoOverlap([first, absence("2026-06-03", kind: kind, first: true)]))
        }
        try VacationEngine.validateNoOverlap([first, absence("2026-06-04")])
        for status in [AbsenceStatus.cancelled, .rejected] {
            try VacationEngine.validateNoOverlap([first, absence("2026-06-02", status: status)])
        }
        XCTAssertThrowsError(try VacationEngine.validateNoOverlap([first, first]))
        XCTAssertThrowsError(try VacationEngine.validateNoOverlap([absence("2026-06-02", "2026-06-01")]))
    }

    func testEffectsAndTimeEngineOverride() throws {
        var workModel = try model(); workModel.dailyTargetSeconds[1] = 27_721
        let day = try date("2026-06-01")
        let now = ISO8601DateFormatter().date(from: "2026-06-02T12:00:00Z")!
        for (kind, half, mark, target) in [(AbsenceKind.vacation, false, DayMarkKind.vacation, 0),
                                          (.vacation, true, .vacation, 13_860), (.sick, true, .sick, 0),
                                          (.other, false, .none, 27_721)] {
            let preferences = try AbsenceDayEffects.preferences(for: day, models: [workModel],
                absences: [absence("2026-06-01", kind: kind, first: half)])
            XCTAssertEqual(preferences.mark, mark)
            let evaluation = try TimeEngine.evaluateDay(date: day, model: workModel, segments: [], preferences: preferences, now: now)
            XCTAssertEqual(evaluation.targetSeconds, target)
        }
        for status in [AbsenceStatus.planned, .requested, .rejected, .cancelled] {
            XCTAssertEqual(try AbsenceDayEffects.preferences(for: day, models: [workModel],
                absences: [absence("2026-06-01", status: status)]).mark, .none)
        }
        XCTAssertEqual(try TimeEngine.evaluateDay(date: day, model: workModel, segments: [],
            preferences: DayPreferences(targetOverrideSeconds: 123), now: now).targetSeconds, 123)
        XCTAssertThrowsError(try TimeEngine.evaluateDay(date: day, model: workModel, segments: [],
            preferences: DayPreferences(targetOverrideSeconds: -1), now: now))
    }

    func testExplicitMarkPrecedenceAndHolidayEffects() throws {
        let days = try HolidayCalendar.holidays(year: 2026)
        let day = try date("2026-04-03")
        let item = try absence("2026-04-03", first: true)
        let explicit = DayPreferences(mark: .schoolCredit, creditSeconds: 500, skipFixedBreaks: true, note: "Manual")
        XCTAssertEqual(try AbsenceDayEffects.preferences(for: day, models: [model()], absences: [item],
            calendarDays: days, explicit: explicit), explicit)
        XCTAssertEqual(try AbsenceDayEffects.preferences(for: day, models: [model()], absences: [item],
            calendarDays: days, hasExplicitMark: true), DayPreferences())
        let half = try AbsenceDayEffects.preferences(for: day, models: [model()], absences: [item], calendarDays: days)
        XCTAssertEqual(half.targetOverrideSeconds, 0)
        let holiday = try AbsenceDayEffects.preferences(for: day, models: [model()], absences: [], calendarDays: days,
            explicit: DayPreferences(skipFixedBreaks: true, note: "Keep"))
        XCTAssertEqual(holiday.mark, .holiday)
        XCTAssertEqual(holiday.note, "Keep")
        XCTAssertTrue(holiday.skipFixedBreaks)
        XCTAssertEqual(try AbsenceDayEffects.preferences(for: date("2026-10-03"), models: [model()], absences: [],
            calendarDays: days).mark, .none)
        XCTAssertEqual(try AbsenceDayEffects.preferences(for: date("2026-10-03"), models: [model([6])], absences: [],
            calendarDays: days).mark, .holiday)
    }

    func testCoincidentHolidaysAndHalfDayPreserveActualWork() throws {
        let holidays = try HolidayCalendar.holidays(year: 2008)
        XCTAssertEqual(holidays.filter { $0.startDate.description == "2008-05-01" }.count, 2)
        XCTAssertEqual(try VacationEngine.countedHalfDays(for: absence("2008-05-01"), models: [model()],
                                                          calendarDays: holidays), 0)
        let day = try date("2026-06-01")
        let start = ISO8601DateFormatter().date(from: "2026-06-01T06:07:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-06-01T10:02:00Z")!
        let segment = EngineSegment(kind: .work, start: start, end: end)
        let baseline = try TimeEngine.evaluateDay(date: day, model: model(), segments: [segment], now: end)
        let preferences = try AbsenceDayEffects.preferences(for: day, models: [model()],
            absences: [absence("2026-06-01", status: .taken, first: true)])
        let half = try TimeEngine.evaluateDay(date: day, model: model(), segments: [segment], preferences: preferences, now: end)
        XCTAssertEqual(half.targetSeconds, baseline.targetSeconds / 2)
        XCTAssertEqual(half.rawWorkSeconds, baseline.rawWorkSeconds)
        XCTAssertEqual(half.evaluatedWorkSeconds, baseline.evaluatedWorkSeconds)
        XCTAssertEqual(half.startAdjustSeconds, baseline.startAdjustSeconds)
        XCTAssertEqual(half.endAdjustSeconds, baseline.endAdjustSeconds)
        XCTAssertEqual(half.creditSeconds, 0)
    }

    func testInvalidSettingsAndSnapshots() throws {
        XCTAssertThrowsError(try VacationEngine.balance(year: 2026, settings: VacationSettings(annualEntitlementHalfDays: -1),
            absences: [], models: []))
        XCTAssertThrowsError(try VacationEngine.balance(year: 2026, settings: VacationSettings(carryOverExpiry: "13-01"),
            absences: [], models: []))
        let snapshot = try VacationSnapshot(date: date("2026-01-01"), remainingHalfDays: 5)
        XCTAssertThrowsError(try VacationEngine.balance(year: 2026, absences: [], models: [], snapshots: [snapshot, snapshot]))
    }
}
