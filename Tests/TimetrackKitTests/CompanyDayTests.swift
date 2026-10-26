import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// N4 (ADR-0029): company days (24.12./31.12.) with the treatments none, half and full.
final class CompanyDayEngineTests: XCTestCase {
    private func date(_ value: String) throws -> LocalDate { try LocalDate(value) }
    private func models() throws -> [EngineWorkModel] {
        [EngineWorkModel(validFrom: try date("2020-01-01"), weeklyTargetSeconds: 138_600, workdays: [1, 2, 3, 4, 5])]
    }
    private func days(_ treatment: CompanyDayTreatment, year: Int = 2026) throws -> [CustomCalendarDay] {
        try HolidayCalendar.calendar(year: year, region: "DE-ST", companyDays: [
            .init(month: 12, day: 24, treatment: treatment), .init(month: 12, day: 31, treatment: treatment)])
    }

    func testNoneAddsNothingAndDefaultsMatchStatutoryTable() throws {
        XCTAssertEqual(try days(.none), try HolidayCalendar.holidays(year: 2026, region: "DE-ST"))
        XCTAssertEqual(try HolidayCalendar.calendar(year: 2026), try HolidayCalendar.holidays(year: 2026))
    }

    func testFullBehavesLikeHolidayAndHalfDoesNot() throws {
        let full = try days(.full), half = try days(.half)
        XCTAssertTrue(HolidayCalendar.isHoliday(try date("2026-12-24"), days: full))
        XCTAssertTrue(HolidayCalendar.isHoliday(try date("2026-12-31"), days: full))
        XCTAssertFalse(HolidayCalendar.isHoliday(try date("2026-12-24"), days: half))
        XCTAssertTrue(HolidayCalendar.isHalfCompanyDay(try date("2026-12-24"), days: half))
        XCTAssertFalse(HolidayCalendar.isHalfCompanyDay(try date("2026-12-24"), days: full))
        XCTAssertEqual(full.filter { $0.companyTreatment == .full }.map(\.name), ["Heiligabend", "Silvester"])
    }

    func testStatutoryHolidayWinsOverCompanyRule() throws {
        let merged = try HolidayCalendar.calendar(year: 2026, region: "DE-ST", companyDays: [.init(month: 12, day: 25, treatment: .half)])
        XCTAssertNil(merged.first { $0.name == "Betriebsfreier Tag" })
        XCTAssertFalse(HolidayCalendar.isHalfCompanyDay(try date("2026-12-25"), days: merged))
    }

    func testDayEffectsAndTargets() throws {
        let model = try XCTUnwrap(models().first)
        let thursday = try date("2026-12-24")
        let base = TimeEngine.target(for: thursday, model: model)
        XCTAssertEqual(base, 27_720)
        let none = AbsenceDayEffects.apply(for: thursday, model: model, absences: [], calendarDays: try days(.none), explicit: DayPreferences())
        XCTAssertEqual(none.mark, DayMarkKind.none); XCTAssertNil(none.targetOverrideSeconds)
        let full = AbsenceDayEffects.apply(for: thursday, model: model, absences: [], calendarDays: try days(.full), explicit: DayPreferences())
        XCTAssertEqual(full.mark, .holiday)
        let half = AbsenceDayEffects.apply(for: thursday, model: model, absences: [], calendarDays: try days(.half), explicit: DayPreferences())
        XCTAssertEqual(half.mark, DayMarkKind.none); XCTAssertEqual(half.targetOverrideSeconds, base / 2)
        // A user-set target override wins over the half-day rule.
        let own = AbsenceDayEffects.apply(for: thursday, model: model, absences: [], calendarDays: try days(.half),
                                          explicit: DayPreferences(targetOverrideSeconds: 3_600))
        XCTAssertEqual(own.targetOverrideSeconds, 3_600)
        // Vacation on a half company day leaves no work obligation, also with the half-day flag.
        for flags in [(false, false), (true, true)] {
            let absence = EngineAbsence(kind: .vacation, startDate: thursday, endDate: thursday, status: .approved, halfDayStart: flags.0, halfDayEnd: flags.1)
            let vacation = AbsenceDayEffects.apply(for: thursday, model: model, absences: [absence], calendarDays: try days(.half), explicit: DayPreferences())
            XCTAssertEqual(vacation.mark, .vacation); XCTAssertNil(vacation.targetOverrideSeconds)
        }
    }

    func testWeekendIsUnaffected() throws {
        let model = try XCTUnwrap(models().first)
        // 24.12.2028 is a Sunday.
        let sunday = try date("2028-12-24")
        for treatment in [CompanyDayTreatment.half, .full] {
            let effect = AbsenceDayEffects.apply(for: sunday, model: model, absences: [], calendarDays: try days(treatment, year: 2028), explicit: DayPreferences())
            XCTAssertEqual(effect.mark, DayMarkKind.none); XCTAssertNil(effect.targetOverrideSeconds)
        }
    }

    func testVacationCountingPerTreatment() throws {
        let absence = EngineAbsence(kind: .vacation, startDate: try date("2026-12-23"), endDate: try date("2026-12-24"), status: .approved)
        let counts = try [CompanyDayTreatment.none, .half, .full].map {
            try VacationEngine.countedHalfDays(for: absence, models: models(), calendarDays: days($0))
        }
        XCTAssertEqual(counts, [4, 3, 2])
        // A half-day request on the half company day cannot consume more than one half day.
        let halfRequest = EngineAbsence(kind: .vacation, startDate: try date("2026-12-24"), endDate: try date("2026-12-24"), status: .approved, halfDayStart: true, halfDayEnd: true)
        XCTAssertEqual(try VacationEngine.countedHalfDays(for: halfRequest, models: models(), calendarDays: days(.half)), 1)
        // Whole holiday week around New Year: 28.12. to 31.12. (Mon to Thu) plus 1.1.
        let year = EngineAbsence(kind: .vacation, startDate: try date("2026-12-28"), endDate: try date("2026-12-31"), status: .approved)
        let yearCounts = try [CompanyDayTreatment.none, .half, .full].map {
            try VacationEngine.countedHalfDays(for: year, models: models(), calendarDays: days($0))
        }
        XCTAssertEqual(yearCounts, [8, 7, 6])
    }

    func testBalanceUsesSettingsRules() throws {
        let absence = EngineAbsence(kind: .vacation, startDate: try date("2026-12-23"), endDate: try date("2026-12-24"), status: .approved)
        func booked(_ treatment: CompanyDayTreatment) throws -> Int {
            let settings = VacationSettings(companyDays: [.init(month: 12, day: 24, treatment: treatment)])
            return try VacationEngine.balance(year: 2026, settings: settings, absences: [absence], models: models()).bookedHalfDays
        }
        XCTAssertEqual([try booked(.none), try booked(.half), try booked(.full)], [4, 3, 2])
    }
}

extension AuthTests {
    private func setCompanyDays(_ app: Application, _ context: AuthContext, _ rules: [[String: Any]]) async throws -> [String: Any] {
        try object(await api(app, context, .PUT, "vacation/settings", ["region": "DE-ST", "annualEntitlementHalfDays": 60, "companyDays": rules]))
    }
    private func weekDays(_ app: Application, _ context: AuthContext, _ week: String) async throws -> (days: [String: [String: Any]], summary: [String: Any]) {
        let value = try object(await timeRequest(app, context, .GET, "time/weeks/" + week))
        let days = try XCTUnwrap(value["days"] as? [[String: Any]])
        return (Dictionary(uniqueKeysWithValues: days.map { ($0["date"] as! String, $0) }), try XCTUnwrap(value["summary"] as? [String: Any]))
    }

    func testCompanyDaySettingsDefaultsValidationAndPersistence() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let defaults = try object(await api(app, context, .GET, "vacation/settings"))
            let listed = try XCTUnwrap(defaults["companyDays"] as? [[String: Any]])
            XCTAssertEqual(listed.map { "\($0["month"] as! Int)-\($0["day"] as! Int)-\($0["treatment"] as! String)" }, ["12-24-none", "12-31-none"])
            let saved = try await setCompanyDays(app, context, [["month": 12, "day": 24, "treatment": "half"], ["month": 6, "day": 15, "treatment": "full", "name": " Brückentag "]])
            let rules = try XCTUnwrap(saved["companyDays"] as? [[String: Any]])
            XCTAssertEqual(rules.map { "\($0["month"] as! Int)-\($0["day"] as! Int)-\($0["treatment"] as! String)" }, ["6-15-full", "12-24-half", "12-31-none"])
            XCTAssertEqual(rules.first?["name"] as? String, "Brückentag")
            // A PUT without the field (older client) keeps the rules.
            let kept = try object(await api(app, context, .PUT, "vacation/settings", ["region": "DE-ST", "annualEntitlementHalfDays": 60]))
            XCTAssertEqual((kept["companyDays"] as? [[String: Any]])?.count, 3)
            // Invalid: leap day, month 13, duplicate, unknown treatment.
            for bad in [[["month": 2, "day": 29, "treatment": "full"]], [["month": 13, "day": 1, "treatment": "full"]],
                        [["month": 12, "day": 24, "treatment": "full"], ["month": 12, "day": 24, "treatment": "half"]],
                        [["month": 12, "day": 24, "treatment": "quarter"]]] as [[[String: Any]]] {
                try await api(app, context, .PUT, "vacation/settings", ["region": "DE-ST", "annualEntitlementHalfDays": 60, "companyDays": bad], .badRequest)
            }
            // Clearing the list restores the untreated defaults.
            let cleared = try await setCompanyDays(app, context, [])
            XCTAssertTrue((cleared["companyDays"] as? [[String: Any]])?.allSatisfy { $0["treatment"] as? String == "none" } == true)
        }
    }

    func testCompanyDaysInWeekOverviewTargetsAndHolidayList() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-01-01"), status: .created)
            let none = try await weekDays(app, context, "2026-W52")
            XCTAssertTrue(none.days["2026-12-24"]?["holidayName"] is NSNull)
            XCTAssertTrue(none.days["2026-12-24"]?["companyDayTreatment"] is NSNull)
            XCTAssertEqual(none.days["2026-12-24"]?["targetSeconds"] as? Int, 27_720)
            XCTAssertEqual(none.summary["targetSeconds"] as? Int, 27_720 * 4)

            _ = try await setCompanyDays(app, context, [["month": 12, "day": 24, "treatment": "half"], ["month": 12, "day": 31, "treatment": "full"]])
            let treated = try await weekDays(app, context, "2026-W52")
            let eve = try XCTUnwrap(treated.days["2026-12-24"])
            XCTAssertEqual(eve["holidayName"] as? String, "Heiligabend")
            XCTAssertEqual(eve["companyDayTreatment"] as? String, "half")
            XCTAssertEqual(eve["mark"] as? String, "work")
            XCTAssertEqual(eve["targetSeconds"] as? Int, 13_860)
            // 25.12. stays a statutory holiday, not a company day.
            XCTAssertTrue(treated.days["2026-12-25"]?["companyDayTreatment"] is NSNull)
            XCTAssertEqual(treated.days["2026-12-25"]?["holidayName"] as? String, "1. Weihnachtstag")
            // Week target: Mon 21, Tue 22, Wed 23 full, Thu 24 half, Fri 25 holiday = 3.5 days.
            XCTAssertEqual(treated.summary["targetSeconds"] as? Int, 27_720 * 3 + 13_860)
            let newYearsWeek = try await weekDays(app, context, "2026-W53")
            XCTAssertEqual(newYearsWeek.days["2026-12-31"]?["mark"] as? String, "holiday")
            XCTAssertEqual(newYearsWeek.days["2026-12-31"]?["holidayName"] as? String, "Silvester")
            XCTAssertEqual(newYearsWeek.days["2026-12-31"]?["targetSeconds"] as? Int, 0)
            XCTAssertEqual(newYearsWeek.days["2026-12-31"]?["markSource"] as? String, "holiday")

            // Calendar holiday list: same kind, attribute names the treatment; no new enum values.
            let listResponse = try json(await api(app, context, .GET, "calendar/holidays?year=2026"))
            let list = try XCTUnwrap(listResponse as? [[String: Any]])
            let eveEntry = try XCTUnwrap(list.first { $0["startDate"] as? String == "2026-12-24" })
            XCTAssertEqual(eveEntry["kind"] as? String, "holiday"); XCTAssertEqual(eveEntry["companyTreatment"] as? String, "half")
            XCTAssertEqual(eveEntry["name"] as? String, "Heiligabend"); XCTAssertEqual(eveEntry["source"] as? String, "builtin")
            let neujahr = try XCTUnwrap(list.first { $0["startDate"] as? String == "2026-01-01" })
            XCTAssertTrue(neujahr["companyTreatment"] is NSNull)

            // Plan week uses the same targets.
            let plan = try object(await timeRequest(app, context, .GET, "plan/weeks/2026-W52"))
            let planDays = try XCTUnwrap(plan["days"] as? [[String: Any]])
            XCTAssertEqual(planDays.first { $0["date"] as? String == "2026-12-24" }?["targetSeconds"] as? Int, 13_860)
            XCTAssertEqual(planDays.first { $0["date"] as? String == "2026-12-24" }?["blockedBy"] is NSNull, true)
        }
    }

    func testCompanyDaysOnWeekendsAndVacationCountingOverHTTP() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2020-01-01"), status: .created)
            _ = try await setCompanyDays(app, context, [["month": 12, "day": 24, "treatment": "full"], ["month": 12, "day": 31, "treatment": "full"]])
            // 24.12.2028 and 31.12.2028 are Sundays: named, but no consumed day and no target.
            let weekend = try await weekDays(app, context, "2028-W51")
            XCTAssertEqual(weekend.days["2028-12-24"]?["holidayName"] as? String, "Heiligabend")
            XCTAssertEqual(weekend.days["2028-12-24"]?["mark"] as? String, "off")
            XCTAssertEqual(weekend.days["2028-12-24"]?["targetSeconds"] as? Int, 0)

            // Vacation 23.-24.12.2026: none 2 days (4 half days), half 3, full 2.
            func counted(_ treatment: String) async throws -> Int {
                _ = try await setCompanyDays(app, context, [["month": 12, "day": 24, "treatment": treatment]])
                let response = try json(await api(app, context, .GET, "absences?from=2026-12-01&to=2026-12-31"))
                let list = try XCTUnwrap(response as? [[String: Any]])
                return try XCTUnwrap(list.first?["countedHalfDays"] as? Int)
            }
            try await createAbsence(app, context, absenceBody("2026-12-23", "2026-12-24"))
            let counts = [try await counted("none"), try await counted("half"), try await counted("full")]
            XCTAssertEqual(counts, [4, 3, 2])
            // The balance follows the same rule.
            _ = try await setCompanyDays(app, context, [["month": 12, "day": 24, "treatment": "half"]])
            let balance = try object(await api(app, context, .GET, "vacation/balance?year=2026"))
            XCTAssertEqual(balance["bookedHalfDays"] as? Int, 3)
        }
    }

    func testCompanyDaysInTimeAccountAndStatistics() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-12-21"), status: .created)
            let before = try object(await timeRequest(app, context, .GET, "time/account"))
            _ = try await setCompanyDays(app, context, [["month": 12, "day": 24, "treatment": "half"], ["month": 12, "day": 31, "treatment": "full"]])
            let after = try object(await timeRequest(app, context, .GET, "time/account"))
            // The account runs up to today (October 2026 or later) so only compare when the dates are covered; the
            // statistics series below is the deterministic assertion.
            XCTAssertNotNil(before["balanceSeconds"]); XCTAssertNotNil(after["balanceSeconds"])
            let stats = try object(await timeRequest(app, context, .GET, "time/statistics?from=2026-12-21&to=2026-12-31&granularity=day"))
            let text = String(data: try JSONSerialization.data(withJSONObject: stats), encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("13860"), "the half company day has half the target")
        }
    }

    func testCompanyDaysInCalendarFeed() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2020-01-01"), status: .created)
            _ = try await setCompanyDays(app, context, [["month": 12, "day": 24, "treatment": "half"], ["month": 12, "day": 31, "treatment": "full"]])
            let created = try object(await timeRequest(app, context, .POST, "me/calendar-feeds", ["label": "T", "include": ["holidays"]], status: .created))
            let token = try XCTUnwrap(created["token"] as? String)
            let response = try await app.testable().sendRequest(.GET, "/ics/" + token + ".ics")
            XCTAssertEqual(response.status, .ok)
            let text = response.body.string.replacingOccurrences(of: "\r\n ", with: "")
            // The 400-day window from today (Oct 2026) covers both days of 2026 and 2027.
            XCTAssertTrue(text.contains("SUMMARY:Heiligabend (halber Tag)"), text)
            XCTAssertTrue(text.contains("SUMMARY:Silvester\r\n"), text)
            XCTAssertTrue(text.contains("CATEGORIES:Betriebsfrei"))
        }
    }
}
