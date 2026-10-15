import Foundation
import Fluent
import FluentSQL
import XCTVapor
@testable import TimetrackKit

/// Entirely synthetic, documented nine-row blocks; never reads external files.
enum SyntheticWorktime {
    struct Day {
        var date: String
        var start: Int? = 8 * 3600
        var end: Int? = 16 * 3600 + 12 * 60
        var remark = ""
        var difference = 0
    }
    static func rows(_ days: [Day], system1904: Bool = false, pause: Int = 1800, header: Bool = true, sheetYear: Int = 2026) throws -> [[TestCell]] {
        var rows: [[TestCell]] = header ? [
            [.shared("Wochenarbeitszeit"), .num(String(138600.0 / 86400)), .empty, .shared("Tägl. Arbeitszeit"), .formula("B1/5", cached: String(27720.0 / 86400)), .empty, .shared("Pause"), .num(String(Double(pause) / 86400))],
            [.shared("Summe"), .formula("SUM(E7:E999)", cached: "0")], [], [], []
        ] : [[], [], []]
        let grouped = try Dictionary(grouping: days) { day in
            let date = try LocalDate(day.date); return date.addingDays(1 - HolidayCalendar.weekday(date))
        }
        for monday in grouped.keys.sorted() {
            let instant = ImportInterpreter.instant(monday, seconds: 0, zone: .gmt)!
            var calendar = Calendar(identifier: .iso8601); calendar.timeZone = .gmt
            let week = calendar.component(.weekOfYear, from: instant)
            let year = calendar.component(.yearForWeekOfYear, from: instant)
            let label = String(format: "KW%02d", week) + (year == sheetYear ? "" : " - \(year)")
            rows.append([.shared(label), .shared("Beginn"), .shared("Ende"), .shared("Stunden"), .shared("Differenz"), .shared("Bemerkung"), .formula("SUM(INDIRECT(\"D\"&ROW()+1):INDIRECT(\"D\"&ROW()+5))*24", cached: "38.5")])
            for offset in 0..<7 {
                let date = monday.addingDays(offset)
                let serial = ImportInterpreter.epochDays(date) + (system1904 ? 24107 : 25569)
                guard let day = grouped[monday]?.first(where: { $0.date == date.description }) else {
                    rows.append([.num(String(serial), style: 1)]); continue
                }
                func fraction(_ seconds: Int?) -> TestCell {
                    seconds.map { .num(String(Double($0 + 1) / 86400), style: 2) } ?? .empty
                }
                rows.append([.num(String(serial), style: 1), fraction(day.start), fraction(day.end),
                    .formula("C-B-$H$1", cached: "0.3208333333333333"),
                    .formula("D-$E$1", cached: String(Double(day.difference) / 86400)), .shared(day.remark)])
            }
            rows.append([])
        }
        return rows
    }
    static func build(_ days: [Day], system1904: Bool = false, boundary: Bool = false, pause: Int = 1800, header: Bool = true) throws -> Data {
        let rows = try rows(days, system1904: system1904, pause: pause, header: header)
        var sheets = [(name: "2026", rows: rows)]
        if boundary { sheets.append((name: "2027", rows: try Self.rows(days, system1904: system1904, pause: pause, header: header, sheetYear: 2027))) }
        return try TestXLSX.build(sheets: sheets, date1904: system1904)
    }
    static func mapping(options: [String: Any] = [:]) -> [String: Any] {
        ["profile": "worktime_workbook", "sheet": "", "headerRow": 0, "columns": ["date": 0],
         "dateFormat": "excel_serial", "timeFormat": "excel_fraction", "worktime": options]
    }
    static func decodedMapping(options: [String: Any] = [:]) throws -> ImportMapping {
        try JSONDecoder().decode(ImportMapping.self, from: JSONSerialization.data(withJSONObject: mapping(options: options)))
    }
}

final class WorktimeEngineTests: XCTestCase {
    func testRemarkRuleMatrixAndLiteralSafety() throws {
        let matrix: [(String, WorktimeAction)] = [("Urlaub", .vacation), ("Krank", .sick), ("Feiertag", .holiday),
            ("Berufsschule", .school), (" BS\u{a0}", .school), ("Berufsschule / Krank", .sick),
            ("Freigestellt", .excused), ("Urlaub (Freigestellt)", .excused), ("Arzttermin", .work), ("", .work), ("=SUM(A1)", .work)]
        for (remark, expected) in matrix {
            XCTAssertEqual(WorktimeRemarkRule.defaults.first { $0.matches(remark) }?.action ?? .work, expected, remark)
        }
        XCTAssertFalse(WorktimeRemarkRule(pattern: "^(a+)+$", action: .skip).matches(String(repeating: "a", count: 10000)))
        XCTAssertTrue(WorktimeRemarkRule(pattern: "^a.*$", action: .skip).matches("a.*"))
        XCTAssertFalse(WorktimeRemarkRule(pattern: "^bs$", action: .school).matches("bs extra"))
        var options = WorktimeOptions(); options.rules = []; XCTAssertEqual(options.effectiveRules, [])
        options.rules = Array(repeating: .init(pattern: "a", action: .skip), count: 101)
        XCTAssertThrowsError(try options.validate())
        options.rules = nil; options.pauseStart = "29:00"; XCTAssertThrowsError(try options.validate())
    }
    func testBothDateSystemsBoundaryDuplicatesAndCache() throws {
        for system in [false, true] {
            let data = try SyntheticWorktime.build([.init(date: "2026-12-31", remark: "Arzttermin", difference: 1800)], system1904: system, boundary: true)
            let workbook = try ImportWorkbook.open(data: data, filename: "synthetic.xlsx")
            XCTAssertTrue(try WorktimeWorkbook.detects(workbook))
            let parsed = try WorktimeWorkbook.parse(workbook, options: .init())
            XCTAssertEqual(parsed.days.count, 1); XCTAssertEqual(parsed.days.first?.date.description, "2026-12-31")
            XCTAssertEqual(parsed.days.first?.start, 28800); XCTAssertEqual(parsed.days.first?.end, 58320)
            XCTAssertEqual(parsed.date1904, system); XCTAssertEqual(parsed.balance, 3600)
            XCTAssertEqual(parsed.errors, [])
        }
    }
    func testWeekDetectionWithoutHeaderAndConflictingDates() throws {
        let a = try SyntheticWorktime.rows([.init(date: "2026-12-31", remark: "Urlaub")], header: false)
        let b = try SyntheticWorktime.rows([.init(date: "2026-12-31", remark: "Krank")], header: false)
        let data = try TestXLSX.build(sheets: [("one", a), ("two", b)])
        let workbook = try ImportWorkbook.open(data: data, filename: "synthetic.xlsx")
        XCTAssertTrue(try WorktimeWorkbook.detects(workbook))
        let parsed = try WorktimeWorkbook.parse(workbook, options: .init())
        XCTAssertTrue(parsed.days.isEmpty); XCTAssertEqual(parsed.errors.map(\.code), ["duplicate_date_conflict"])
    }
    func testPausePlacementAndNoiseOptions() throws {
        let date = try LocalDate("2026-10-12")
        var day = WorktimeDay(row: 1, date: date, start: 28800, end: 58320, remark: "", pause: 1800)
        var mapping = try SyntheticWorktime.decodedMapping()
        let inside = try WorktimeWorkbook.segments(day, action: .work, mapping: mapping)
        XCTAssertEqual(inside.0.count, 2); XCTAssertEqual(inside.0[0].end.distance(to: inside.0[1].start), 1800)
        XCTAssertEqual(inside.0.reduce(0) { $0 + Int($1.start.distance(to: $1.end)) }, 27720)
        mapping.worktime?.pauseStart = "23:00"
        let outside = try WorktimeWorkbook.segments(day, action: .work, mapping: mapping)
        XCTAssertEqual(outside.0[0].start.distance(to: outside.0[0].end), outside.0[1].start.distance(to: outside.0[1].end))
        day.end = 29400
        let short = try WorktimeWorkbook.segments(day, action: .work, mapping: mapping)
        XCTAssertTrue(short.1); XCTAssertEqual(short.0.count, 1)
        mapping.worktime?.pauseMode = "none"; day.end = 58320
        XCTAssertEqual(try WorktimeWorkbook.segments(day, action: .school, mapping: mapping).0.count, 1)
        XCTAssertEqual(try WorktimeWorkbook.seconds(.number(String(28801.0 / 86400), .time), roundMinutes: false), 28801)
    }
    func testExcusedEvaluationAndConsumption() throws {
        let date = try LocalDate("2026-10-12")
        let model = EngineWorkModel(validFrom: date, weeklyTargetSeconds: 138600, workdays: [1,2,3,4,5], roundingEnabled: false)
        let absence = EngineAbsence(kind: .excused, startDate: date, endDate: date, status: .taken)
        XCTAssertEqual(try VacationEngine.countedHalfDays(for: absence, models: [model]), 0)
        let start = ImportInterpreter.instant(date, seconds: 28800, zone: TimeZone(identifier: "Europe/Berlin")!)!
        let segment = EngineSegment(kind: .work, start: start, end: start.addingTimeInterval(3600))
        let snapshot = TimeEvaluationSnapshot(models: [model], segments: [segment], preferences: [:], absences: [absence])
        let day = try snapshot.evaluate(date, now: start.addingTimeInterval(50000))
        XCTAssertEqual(day.mark, .excused); XCTAssertEqual(day.markSource, .absence)
        XCTAssertEqual(day.targetSeconds, 0); XCTAssertEqual(day.evaluatedWorkSeconds, 3600)
        let holiday = CustomCalendarDay(startDate: date, endDate: date, name: "Synthetic")
        XCTAssertEqual(try AbsenceDayEffects.preferences(for: date, models: [model], absences: [absence], calendarDays: [holiday]).mark, .holiday)
        var changed = snapshot; changed.customDays = [holiday]
        XCTAssertEqual(try changed.evaluate(date, now: start).mark, .holiday)
        let explicit = TimeEvaluationSnapshot(models: [model], segments: [segment], preferences: [date.description: DayPreferences(mark: .sick)], absences: [absence], customDays: [holiday])
        XCTAssertEqual(try explicit.evaluate(date, now: start).mark, .sick)
    }
}

extension AuthTests {
    func scenarioC23PartialCreditSeparatesAbsenceRanges(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        var model = modelBody("2026-05-04"); model["roundingEnabled"] = false; model["fixedBreaks"] = []
        try await api(app, owner, .POST, "work-models", model, .created)
        let data = try SyntheticWorktime.build([
            .init(date: "2026-05-04", remark: "Urlaub"),
            .init(date: "2026-05-05", end: 10 * 3600 + 33 * 60, remark: "Urlaub"),
            .init(date: "2026-05-06", remark: "Urlaub")
        ])
        let id = try await worktimeUpload(app, owner, data)
        let defaults = try object(await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping()))
        try await eq((defaults["worktime"] as? [String: Any])?["absences"] as? Int, 2)
        try await eq((defaults["worktime"] as? [String: Any])?["segments"] as? Int, 2)
        let legacy = try object(await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping(options: ["partialCredit": "absence"])))
        try await eq((legacy["worktime"] as? [String: Any])?["absences"] as? Int, 1)
        try await eq((legacy["worktime"] as? [String: Any])?["segments"] as? Int, 0)
    }
    func testC23PartialCreditSeparatesAbsenceRangesSQLite() async throws { try await withApp(scenarioC23PartialCreditSeparatesAbsenceRanges) }
    func testC23PartialCreditSeparatesAbsenceRangesMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_c23", "DB_TLS": "off"]
        try await withApp(environment: environment, scenarioC23PartialCreditSeparatesAbsenceRanges)
    }
    func scenarioC23BuiltinHolidayTimesDiscardVsKeep(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        var model = modelBody("2026-01-01"); model["roundingEnabled"] = false; model["fixedBreaks"] = []
        try await api(app, owner, .POST, "work-models", model, .created)
        let data = try SyntheticWorktime.build([
            .init(date: "2026-01-01", remark: "Berufsschule"),
            .init(date: "2026-05-01", end: 15 * 3600 + 45 * 60, remark: "Work on holiday")
        ])
        let id = try await worktimeUpload(app, owner, data)
        let discarded = try object(await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping()))
        try await eq((discarded["worktime"] as? [String: Any])?["segments"] as? Int, 0)
        let warnings = try XCTUnwrap(discarded["warnings"] as? [[String: Any]])
        try await eq(warnings.first { $0["code"] as? String == "school_on_holiday" }?["count"] as? Int, 1)
        try await eq(warnings.first { $0["code"] as? String == "holiday_times_discarded" }?["count"] as? Int, 1)
        let kept = try object(await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping(options: ["holidayTimes": "keep"])))
        try await eq((kept["worktime"] as? [String: Any])?["segments"] as? Int, 4)
        let result = try object(await api(app, owner, .POST, "imports/\(id)/commit"))
        try await eq(result["created"] as? Int, 4)
        let school = try object(await api(app, owner, .GET, "time/days/2026-01-01"))
        let work = try object(await api(app, owner, .GET, "time/days/2026-05-01"))
        try await eq(school["deltaSeconds"] as? Int, 38 * 3600 / 5 + 30 * 60 / 5)
        try await eq(work["deltaSeconds"] as? Int, (15 * 3600 + 45 * 60) - 8 * 3600 - 30 * 60)
        try await api(app, owner, .POST, "imports/\(id)/rollback")
    }
    func testC23BuiltinHolidayTimesDiscardVsKeepSQLite() async throws { try await withApp(scenarioC23BuiltinHolidayTimesDiscardVsKeep) }
    func testC23BuiltinHolidayTimesDiscardVsKeepMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_c23", "DB_TLS": "off"]
        try await withApp(environment: environment, scenarioC23BuiltinHolidayTimesDiscardVsKeep)
    }
    func scenarioC23OptionsAndThreshold(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        app.storage[WorktimeClockKey.self] = { ImportInterpreter.instant(try! LocalDate("2026-05-10"), seconds: 20 * 3600, zone: .gmt)! }
        let data = try SyntheticWorktime.build([
            .init(date: "2026-05-01", end: 15 * 3600 + 45 * 60, remark: "Manual work"),
            .init(date: "2026-05-04", end: 10 * 3600 + 33 * 60, remark: "Urlaub"),
            .init(date: "2026-05-05", end: 10 * 3600 + 33 * 60, remark: "Krank"),
            .init(date: "2026-05-06", end: 16 * 3600 + 17 * 60, remark: "Freigestellt"),
            .init(date: "2026-05-07", end: 16 * 3600 + 18 * 60, remark: "Freigestellt")
        ])
        let id = try await worktimeUpload(app, owner, data)
        let defaults = try object(await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping()))
        let details = try XCTUnwrap(defaults["worktime"] as? [String: Any])
        try await eq(details["segments"] as? Int, 6)
        try await eq(details["absences"] as? Int, 1)
        let warnings = try XCTUnwrap(defaults["warnings"] as? [[String: Any]])
        try await eq(warnings.first { $0["code"] as? String == "credit_partial_as_work" }?["count"] as? Int, 3)
        try await eq(warnings.first { $0["code"] as? String == "holiday_times_discarded" }?["count"] as? Int, 1)
        let legacy = try object(await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping(options: ["holidayTimes": "keep", "partialCredit": "absence"])))
        let legacyDetails = try XCTUnwrap(legacy["worktime"] as? [String: Any])
        try await eq(legacyDetails["segments"] as? Int, 2)
        try await eq(legacyDetails["absences"] as? Int, 3)
        try await eq((legacy["warnings"] as? [[String: Any]])?.count, 0)
        try await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping(options: ["holidayTimes": "bad"]), .badRequest)
        try await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping(options: ["partialCredit": "bad"]), .badRequest)
    }
    func testC23OptionsAndThresholdSQLite() async throws { try await withApp(scenarioC23OptionsAndThreshold) }
    func testC23OptionsAndThresholdMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_c23", "DB_TLS": "off"]
        try await withApp(environment: environment, scenarioC23OptionsAndThreshold)
    }
    func scenarioC23HolidayAndPartialCredit(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        var model = modelBody("2026-04-30"); model["roundingEnabled"] = false; model["fixedBreaks"] = []
        try await api(app, owner, .POST, "work-models", model, .created)
        try await api(app, owner, .POST, "calendar/custom-days", ["kind": "holiday", "startDate": "2026-05-07", "endDate": "2026-05-07", "name": "Synthetic custom holiday"], .created)
        app.storage[WorktimeClockKey.self] = { ImportInterpreter.instant(try! LocalDate("2026-05-05"), seconds: 20 * 3600, zone: .gmt)! }
        let data = try SyntheticWorktime.build([
            .init(date: "2026-04-30", difference: 0),
            .init(date: "2026-05-01", remark: "Berufsschule", difference: 0),
            .init(date: "2026-05-04", end: 10 * 3600 + 33 * 60, remark: "Freigestellt", difference: -20340),
            .init(date: "2026-05-05", remark: "Freigestellt", difference: 0),
            .init(date: "2026-05-06", end: 16 * 3600 + 42 * 60, difference: 1800),
            .init(date: "2026-05-07", end: 15 * 3600 + 45 * 60, remark: "Synthetic work", difference: 0)
        ])
        let id = try await worktimeUpload(app, owner, data)
        let preview = try object(await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping()))
        let details = try XCTUnwrap(preview["worktime"] as? [String: Any])
        try await eq(details["firstContentDate"] as? String, "2026-04-30")
        try await eq(details["sheetBalanceSeconds"] as? Int, -18540)
        try await eq(details["sheetBalanceUpToTodaySeconds"] as? Int, -20340)
        try await eq(details["sheetBalanceFutureSeconds"] as? Int, 1800)
        try await eq(details["segments"] as? Int, 6)
        try await eq(details["absences"] as? Int, 1)
        let warnings = try XCTUnwrap(preview["warnings"] as? [[String: Any]])
        try await eq(warnings.first { $0["code"] as? String == "school_on_holiday" }?["count"] as? Int, 1)
        try await eq(warnings.first { $0["code"] as? String == "holiday_times_discarded" }?["count"] as? Int, 1)
        try await eq(warnings.first { $0["code"] as? String == "credit_partial_as_work" }?["count"] as? Int, 1)
        let committed = try object(await api(app, owner, .POST, "imports/\(id)/commit"))
        try await eq((committed["warnings"] as? [[String: Any]])?.count, 3)
        let holiday = try object(await api(app, owner, .GET, "time/days/2026-05-01"))
        try await eq(holiday["deltaSeconds"] as? Int, 0)
        let account = try object(await api(app, owner, .GET, "time/account?asOf=2026-05-05"))
        let actual = try XCTUnwrap(account["balanceSeconds"] as? Int)
        let partialNet = (10 * 3600 + 33 * 60) - 8 * 3600 - 30 * 60
        let dailyTarget = (38 * 3600 + 30 * 60) / 5
        let expectedThroughToday = partialNet - dailyTarget
        XCTAssertEqual(expectedThroughToday, -20340)
        try await eq(details["sheetBalanceUpToTodaySeconds"] as? Int, expectedThroughToday)
        XCTAssertLessThanOrEqual(abs(actual - expectedThroughToday), 4 * 60)
        let segments = try list(await api(app, owner, .GET, "time/segments?from=2026-04-30T00:00:00Z&to=2026-05-08T00:00:00Z"))
        try await eq(segments.filter { $0["note"] as? String == "Freigestellt" }.count, 2)
        let again = try await worktimeUpload(app, owner, data)
        let repeated = try object(await api(app, owner, .PUT, "imports/\(again)/mapping", SyntheticWorktime.mapping()))
        try await eq(repeated["valid"] as? Int, 0)
        try await api(app, owner, .POST, "imports/\(id)/rollback")
        try await eq(try await SegmentRecord.query(on: app.db).filter(\.$voidedAt == nil).count(), 0)
        try await eq(try await AbsenceRecord.query(on: app.db).count(), 0)
    }
    func testC23DefaultSheetAndAccountParityThroughTodayWithinOneMinutePerDaySQLite() async throws { try await withApp(scenarioC23HolidayAndPartialCredit) }
    func testC23DefaultSheetAndAccountParityThroughTodayWithinOneMinutePerDayMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_c23", "DB_TLS": "off"]
        try await withApp(environment: environment, scenarioC23HolidayAndPartialCredit)
    }
    func worktimeUpload(_ app: Application, _ context: AuthContext, _ data: Data) async throws -> String {
        let job = try object(await importUpload(app, context, "synthetic.xlsx", data))
        try await eq(job["detectedProfile"] as? String, "worktime_workbook")
        return try XCTUnwrap(job["id"] as? String)
    }
    func scenarioC21Flow(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        let other = try await second(app, auth, owner)
        var model = modelBody("2026-01-01"); model["roundingEnabled"] = false; model["fixedBreaks"] = []
        try await api(app, owner, .POST, "work-models", model, .created)
        let rules = try list(await api(app, owner, .GET, "import-profiles/worktime/default-rules"))
        try await eq(rules.compactMap { $0["pattern"] as? String }, ["krank", "freigestellt", "urlaub", "feiertag", "berufsschule", "^bs$"])
        app.storage[WorktimeClockKey.self] = { Date(timeIntervalSince1970: 1792404000) } // 2026-10-19
        let data = try SyntheticWorktime.build([
            .init(date: "2026-10-12", remark: "=SUM(A1)", difference: 0),
            .init(date: "2026-10-13", remark: "Berufsschule\u{a0}"),
            .init(date: "2026-10-14", remark: "Berufsschule / Krank"),
            .init(date: "2026-10-15", remark: "Urlaub (Freigestellt)"),
            .init(date: "2026-10-16", remark: "Urlaub"),
            .init(date: "2026-10-19", remark: " Feiertag synthetic\u{a0}"),
            .init(date: "2026-10-20", remark: "Urlaub"),
            .init(date: "2026-10-31", remark: "Feiertag")], system1904: true, boundary: true)
        let id = try await worktimeUpload(app, owner, data)
        try await api(app, other, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping(), .notFound)
        let preview = try object(await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping()))
        try await eq(preview["errorCount"] as? Int, 0)
        let worktime = try XCTUnwrap(preview["worktime"] as? [String: Any])
        try await eq(worktime["dateSystem"] as? String, "1904"); try await eq(worktime["segments"] as? Int, 4)
        try await eq(worktime["absences"] as? Int, 3); try await eq(worktime["customDays"] as? Int, 1)
        try await eq(worktime["skippedHolidays"] as? Int, 1)
        try await eq((worktime["unmappedRemarks"] as? [[String: Any]])?.first?["text"] as? String, "=SUM(A1)")
        let committed = try object(await api(app, owner, .POST, "imports/\(id)/commit"))
        try await eq(committed["created"] as? Int, 4); try await eq(committed["absencesCreated"] as? Int, 3); try await eq(committed["customDaysCreated"] as? Int, 1)
        let segments = try list(await api(app, owner, .GET, "time/segments?from=2026-10-01T00:00:00Z&to=2026-11-01T00:00:00Z"))
        try await eq(segments.count, 4); try await eq(segments.filter { $0["note"] as? String == "=SUM(A1)" }.count, 2)
        let absences = try list(await api(app, owner, .GET, "absences?from=2026-10-01&to=2026-10-31"))
        try await eq(absences.count, 3)
        try await eq(absences.first { $0["kind"] as? String == "excused" }?["countedHalfDays"] as? Int, 0)
        try await eq(absences.first { $0["startDate"] as? String == "2026-10-14" }?["status"] as? String, "taken")
        try await eq(absences.first { $0["startDate"] as? String == "2026-10-16" }?["status"] as? String, "approved")
        let holidays = try list(await api(app, owner, .GET, "calendar/holidays?year=2026"))
        try await eq(holidays.filter { $0["source"] as? String == "custom" }.count, 1)
        let day = try object(await api(app, owner, .GET, "time/days/2026-10-15"))
        try await eq(day["mark"] as? String, "excused"); try await eq(day["targetSeconds"] as? Int, 0)
        let export = try await api(app, owner, .GET, "export/time?format=csv&from=2026-10-15&to=2026-10-15")
        XCTAssertTrue(export.body.string.contains("Freigestellt"))
        let share = try object(await api(app, owner, .POST, "shares", ["recipientHandle": "member", "scopes": ["vacation": true, "actual": true]], .created))
        let view = try object(await api(app, other, .GET, "shares/incoming/\(share["id"] as! String)/view?from=2026-10-01&to=2026-10-31"))
        try await eq((view["vacation"] as? [[String: Any]])?.count, 1)
        XCTAssertFalse(String(describing: view).contains("excused")); XCTAssertFalse(String(describing: view).contains("Freigestellt"))
        try await eq(try list(await api(app, other, .GET, "absences?from=2026-10-01&to=2026-10-31")).count, 0)
        app.storage[WorktimeClockKey.self] = { Date(timeIntervalSince1970: 1793502000) }
        let again = try await worktimeUpload(app, owner, data)
        let repeated = try object(await api(app, owner, .PUT, "imports/\(again)/mapping", SyntheticWorktime.mapping()))
        try await eq(repeated["valid"] as? Int, 0); try await eq(repeated["duplicates"] as? Int, 8)
        let result = try object(await api(app, owner, .POST, "imports/\(again)/commit"))
        try await eq(result["created"] as? Int, 0); try await eq(result["absencesCreated"] as? Int, 0)
        try await api(app, owner, .POST, "imports/\(id)/rollback")
        try await eq(try list(await api(app, owner, .GET, "absences?from=2026-10-01&to=2026-10-31")).count, 0)
        try await eq(try list(await api(app, owner, .GET, "calendar/holidays?year=2026")).filter { $0["source"] as? String == "custom" }.count, 0)
        let third = try await worktimeUpload(app, owner, data)
        try await api(app, owner, .PUT, "imports/\(third)/mapping", SyntheticWorktime.mapping())
        try await api(app, owner, .POST, "imports/\(third)/commit")
        let fresh = try list(await api(app, owner, .GET, "absences?from=2026-10-01&to=2026-10-31"))
        let changed = try XCTUnwrap(fresh.first { $0["kind"] as? String == "excused" })
        let changedId = changed["id"] as! String
        try await api(app, owner, .PUT, "absences/\(changedId)", ["kind": "excused", "startDate": "2026-10-15", "endDate": "2026-10-15", "status": "taken", "note": "edited"], version: 1)
        let conflict = try object(await api(app, owner, .POST, "imports/\(third)/rollback", nil, .conflict))
        try await eq((conflict["conflicts"] as? [String]), [changedId])
        try await eq(((conflict["error"] as? [String: Any])?["conflictItems"] as? [[String: Any]])?.first?["type"] as? String, "absence")
        try await eq(try list(await api(app, owner, .GET, "absences?from=2026-10-01&to=2026-10-31")).count, 3)
        try await AbsenceRecord.query(on: app.db).delete()
    }
    func scenarioC21RulesModulesAndMerging(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        var model = modelBody("2026-01-01"); model["roundingEnabled"] = false
        try await api(app, owner, .POST, "work-models", model, .created)
        app.storage[WorktimeClockKey.self] = { Date(timeIntervalSince1970: 1793502000) } // November 1
        let data = try SyntheticWorktime.build([.init(date: "2026-10-23", remark: "Freigestellt"),
            .init(date: "2026-10-26", remark: "Feiertag"), .init(date: "2026-10-27", remark: "Freigestellt"),
            .init(date: "2026-10-28", remark: "Arzttermin"), .init(date: "2026-10-29", start: 28800, end: 29400, remark: "short")])
        let id = try await worktimeUpload(app, owner, data)
        let preview = try object(await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping()))
        try await eq((preview["worktime"] as? [String: Any])?["absences"] as? Int, 1)
        try await eq((preview["warnings"] as? [[String: Any]])?.first?["code"] as? String, "pause_exceeds_day")
        try await api(app, owner, .POST, "imports/\(id)/commit")
        let absences = try list(await api(app, owner, .GET, "absences?from=2026-10-01&to=2026-10-31"))
        try await eq(absences.first?["startDate"] as? String, "2026-10-23"); try await eq(absences.first?["endDate"] as? String, "2026-10-27")
        try await api(app, owner, .POST, "imports/\(id)/rollback")
        // User rules replace all defaults, including vacation and sick rules.
        let custom = try await worktimeUpload(app, owner, data)
        let options: [String: Any] = ["rules": [["pattern": "^Arzttermin$", "action": "skip"]], "pauseMode": "none"]
        let customPreview = try object(await api(app, owner, .PUT, "imports/\(custom)/mapping", SyntheticWorktime.mapping(options: options)))
        let counts = (customPreview["worktime"] as? [String: Any])?["byAction"] as? [String: Int]
        try await eq(counts?["work"], 4); try await eq(counts?["skip"], 1)
        let empty = try object(await api(app, owner, .PUT, "imports/\(custom)/mapping", SyntheticWorktime.mapping(options: ["rules": []])))
        try await eq(((empty["worktime"] as? [String: Any])?["byAction"] as? [String: Int])?["work"], 5)
        try await api(app, owner, .PUT, "me/modules", ["modules": ["planning": false]])
        let disabled = try object(await api(app, owner, .PUT, "imports/\(custom)/mapping", SyntheticWorktime.mapping()))
        try await eq((disabled["errors"] as? [[String: Any]])?.map { $0["code"] as! String }, Array(repeating: "planning_disabled", count: 3))
        try await api(app, owner, .POST, "imports/\(custom)/commit", ["ignoreErrors": true])
        try await eq(try await AbsenceRecord.query(on: app.db).count(), 0)
        try await eq(try await CustomCalendarDayRecord.query(on: app.db).count(), 0)
        try await api(app, owner, .PUT, "me/modules", ["modules": ["transfer": false]])
        try await api(app, owner, .GET, "import-profiles/worktime/default-rules", nil, .notFound)
        try await importUpload(app, owner, "synthetic.xlsx", data, .notFound)
    }
    func scenarioC21ParityAndConflicts(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        var model = modelBody("2026-10-05"); model["roundingEnabled"] = false; model["fixedBreaks"] = []
        try await api(app, owner, .POST, "work-models", model, .created)
        let data = try SyntheticWorktime.build([
            .init(date: "2026-10-05", end: 60120, difference: 1800), .init(date: "2026-10-06", remark: "Urlaub"),
            .init(date: "2026-10-07", remark: "Krank"), .init(date: "2026-10-08", remark: "Freigestellt"),
            .init(date: "2026-10-09", remark: "Berufsschule")])
        let id = try await worktimeUpload(app, owner, data)
        let preview = try object(await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping()))
        let sheetBalance = (preview["worktime"] as? [String: Any])?["sheetBalanceSeconds"] as? Int
        try await eq(sheetBalance, 1800)
        try await api(app, owner, .POST, "imports/\(id)/commit")
        let account = try object(await api(app, owner, .GET, "time/account?asOf=2026-10-09"))
        try await eq(account["balanceSeconds"] as? Int, sheetBalance)
        // A changed imported segment blocks the entire rollback, retaining absences as well.
        let segments = try list(await api(app, owner, .GET, "time/segments?from=2026-10-05T00:00:00Z&to=2026-10-10T00:00:00Z"))
        let changed = try XCTUnwrap(segments.first?["id"] as? String)
        try await api(app, owner, .PATCH, "time/segments/\(changed)", ["note": "edited", "reason": "Synthetic correction"], version: 1)
        let conflict = try object(await api(app, owner, .POST, "imports/\(id)/rollback", nil, .conflict))
        try await eq((conflict["conflicts"] as? [String]), [changed])
        try await eq(try await AbsenceRecord.query(on: app.db).count(), 3)
        // Non-identical segment and absence collisions are row errors.
        let again = try await worktimeUpload(app, owner, data)
        let repeated = try object(await api(app, owner, .PUT, "imports/\(again)/mapping", SyntheticWorktime.mapping()))
        try await eq((repeated["errors"] as? [[String: Any]])?.first?["code"] as? String, "overlap")
        try await AbsenceRecord.query(on: app.db).delete()
    }
    func testC21MigrationPreservesRowsSQLite() async throws {
        try await withApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            try await EnableExcusedAbsences().revert(on: app.db)
            let existing = try object(await api(app, owner, .POST, "absences", ["kind": "sick", "startDate": "2026-10-12", "endDate": "2026-10-12", "status": "approved", "note": "Synthetic"], .created))
            let id = existing["id"] as! String
            try await EnableExcusedAbsences().prepare(on: app.db)
            let preserved = try object(await api(app, owner, .GET, "absences/\(id)"))
            try await eq(preserved["note"] as? String, "Synthetic"); try await eq(preserved["version"] as? Int, 1)
            let excused = try object(await api(app, owner, .POST, "absences", ["kind": "excused", "startDate": "2026-10-13", "endDate": "2026-10-13", "status": "approved"], .created))
            try await eq(excused["countedHalfDays"] as? Int, 0)
            let manual = try object(await api(app, owner, .PUT, "time/days/2026-10-14", ["mark": "excused"]))
            try await eq(manual["mark"] as? String, "excused"); try await eq(manual["markSource"] as? String, "explicit")
            do {
                try await requireSQL(app.db).raw("UPDATE absences SET kind = 'invalid' WHERE id = \(bind: UUID(uuidString: id)!)").run()
                XCTFail("Expected the kind check to remain active")
            } catch {}
            try await AbsenceRecord.query(on: app.db).filter(\.$kind == "excused").delete()
        }
    }
    func testC21AtomicCommitSQLite() async throws {
        try await withApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let data = try SyntheticWorktime.build([.init(date: "2026-10-12"), .init(date: "2026-10-13", remark: "Krank"), .init(date: "2026-10-14", remark: "Feiertag synthetic")])
            let id = try await worktimeUpload(app, owner, data)
            try await api(app, owner, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping())
            try await requireSQL(app.db).raw("CREATE TRIGGER c21_reject_day BEFORE INSERT ON custom_calendar_days BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END").run()
            try await api(app, owner, .POST, "imports/\(id)/commit", nil, .internalServerError)
            try await eq(try await SegmentRecord.query(on: app.db).count(), 0)
            try await eq(try await AbsenceRecord.query(on: app.db).count(), 0)
            try await eq(try await ImportBatchRecord.query(on: app.db).count(), 0)
            try await eq(try await ImportBatchItemRecord.query(on: app.db).count(), 0)
            try await eq(try object(await api(app, owner, .GET, "imports/\(id)"))["status"] as? String, "mapped")
            try await requireSQL(app.db).raw("DROP TRIGGER c21_reject_day").run()
            try await api(app, owner, .POST, "imports/\(id)/commit")
            // Deleting a custom day is a typed conflict and does not void the segments.
            let holidays = try list(await api(app, owner, .GET, "calendar/holidays?year=2026"))
            let custom = try XCTUnwrap(holidays.first { $0["source"] as? String == "custom" }?["id"] as? String)
            try await api(app, owner, .DELETE, "calendar/custom-days/\(custom)", nil, .noContent)
            let conflict = try object(await api(app, owner, .POST, "imports/\(id)/rollback", nil, .conflict))
            try await eq((conflict["conflictItems"] as? [[String: Any]])?.first?["type"] as? String, "custom_day")
            try await eq(try await SegmentRecord.query(on: app.db).filter(\.$voidedAt == nil).count(), 2)
        }
    }
    func testC21WorktimeSQLite() async throws {
        for scenario in [scenarioC21Flow, scenarioC21RulesModulesAndMerging, scenarioC21ParityAndConflicts] { try await withApp(scenario) }
    }
    func testC21WorktimeMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_c21", "DB_TLS": "off"]
        for scenario in [scenarioC21Flow, scenarioC21RulesModulesAndMerging, scenarioC21ParityAndConflicts] { try await withApp(environment: environment, scenario) }
    }
}
