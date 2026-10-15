import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

extension AuthTests {
    func c22Model(_ app: Application, _ owner: AuthContext) async throws {
        var model = modelBody("2026-10-05")
        model["roundingEnabled"] = false
        model["fixedBreaks"] = [["start": "12:00", "end": "12:30"]]
        try await api(app, owner, .POST, "work-models", model, .created)
    }
    func c22RoundTrip(_ app: Application, _ auth: AuthService) async throws {
        let (source, _) = try await registered(auth, db: app.db)
        let destination = try await second(app, auth, source)
        try await c22Model(app, source); try await c22Model(app, destination)
        app.storage[WorktimeClockKey.self] = { Date(timeIntervalSince1970: 1792404000) }
        // Canonical split work/school days, three absence kinds and a synthetic custom holiday.
        let fixture = try SyntheticWorktime.build([
            .init(date: "2026-10-05", end: 60120, remark: "=1+1"),
            .init(date: "2026-10-06", remark: "Urlaub"), .init(date: "2026-10-07", remark: "Krank"),
            .init(date: "2026-10-08", remark: "Freigestellt"), .init(date: "2026-10-09", remark: "Berufsschule"),
            .init(date: "2026-10-12", remark: "Feiertag; Synthetic")])
        let seed = try await worktimeUpload(app, source, fixture)
        try await api(app, source, .PUT, "imports/\(seed)/mapping", SyntheticWorktime.mapping())
        try await api(app, source, .POST, "imports/\(seed)/commit")
        let query = "format=worktime-xlsx&from=2026-10-05&to=2026-10-12"
        let export = try await exportFetch(app, source, query)
        XCTAssertEqual(export.headers.first(name: .cacheControl), "no-store")
        XCTAssertEqual(export.headers.first(name: "X-Content-Type-Options"), "nosniff")
        XCTAssertEqual(export.headers.first(name: .contentType), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        XCTAssertTrue(export.headers.first(name: .contentDisposition)?.contains("zeitnachweis_2026-10-05_2026-10-12_tabelle.xlsx") == true)
        let book = try ExportReaders.xlsx(exportBytes(export))
        XCTAssertEqual(book.seconds("H1"), 1800)
        let balance = try object(await api(app, source, .GET, "time/account?asOf=2026-10-12"))
        try await eq(book.seconds("B2"), balance["balanceSeconds"] as? Int)
        for system in ["1900", "1904"] {
            let data = exportBytes(try await exportFetch(app, source, query + "&dateSystem=\(system)"))
            let id = try await worktimeUpload(app, destination, data)
            try await api(app, source, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping(), .notFound)
            let preview = try object(await api(app, destination, .PUT, "imports/\(id)/mapping", SyntheticWorktime.mapping()))
            try await eq(preview["errorCount"] as? Int, 0)
            let result = try object(await api(app, destination, .POST, "imports/\(id)/commit"))
            try await eq(result["created"] as? Int, system == "1900" ? 4 : 0)
            try await eq(result["absencesCreated"] as? Int, system == "1900" ? 3 : 0)
            try await eq(result["customDaysCreated"] as? Int, system == "1900" ? 1 : 0)
        }
        let segmentPath = "time/segments?from=2026-10-05T00:00:00Z&to=2026-10-13T00:00:00Z"
        func segmentKeys(_ response: XCTHTTPResponse) throws -> [String] {
            try list(response).map { row in ["startedAt", "endedAt", "kind", "note"].map { String(describing: row[$0] ?? "") }.joined(separator: "|") }.sorted()
        }
        let original = try segmentKeys(await api(app, source, .GET, segmentPath))
        try await eq(segmentKeys(await api(app, destination, .GET, segmentPath)), original)
        func absenceKeys(_ response: XCTHTTPResponse) throws -> [String] {
            try list(response).map { row in ["kind", "startDate", "endDate", "halfDayStart", "halfDayEnd", "note"].map { String(describing: row[$0] ?? "") }.joined(separator: "|") }.sorted()
        }
        let sourceAbsences = try absenceKeys(await api(app, source, .GET, "absences?from=2026-10-05&to=2026-10-12"))
        let targetAbsences = try absenceKeys(await api(app, destination, .GET, "absences?from=2026-10-05&to=2026-10-12"))
        try await eq(targetAbsences, sourceAbsences)
        let sourceHolidays = try list(await api(app, source, .GET, "calendar/holidays?year=2026")).filter { $0["source"] as? String == "custom" }
        let targetHolidays = try list(await api(app, destination, .GET, "calendar/holidays?year=2026")).filter { $0["source"] as? String == "custom" }
        try await eq(targetHolidays.first?["name"] as? String, sourceHolidays.first?["name"] as? String)
        try await eq(targetHolidays.first?["startDate"] as? String, sourceHolidays.first?["startDate"] as? String)
        let targetBalance = try object(await api(app, destination, .GET, "time/account?asOf=2026-10-12"))
        try await eq(targetBalance["balanceSeconds"] as? Int, balance["balanceSeconds"] as? Int)
        // Export the imported account again: canonical day data and a second commit are stable.
        let secondExport = exportBytes(try await exportFetch(app, destination, query))
        let firstDays = try WorktimeWorkbook.parse(ImportWorkbook.open(data: exportBytes(export), filename: "synthetic.xlsx"), options: .init())
        let secondDays = try WorktimeWorkbook.parse(ImportWorkbook.open(data: secondExport, filename: "synthetic.xlsx"), options: .init())
        XCTAssertEqual(firstDays.days.count, secondDays.days.count)
        for (first, second) in zip(firstDays.days, secondDays.days) { XCTAssertTrue(first.identical(to: second)) }
        let again = try await worktimeUpload(app, destination, secondExport)
        let preview = try object(await api(app, destination, .PUT, "imports/\(again)/mapping", SyntheticWorktime.mapping()))
        try await eq(preview["errorCount"] as? Int, 0); try await eq(preview["valid"] as? Int, 0)
        let repeated = try object(await api(app, destination, .POST, "imports/\(again)/commit"))
        for key in ["created", "absencesCreated", "customDaysCreated"] { try await eq(repeated[key] as? Int, 0) }
        try await eq(segmentKeys(await api(app, destination, .GET, segmentPath)), original)
        try await AbsenceRecord.query(on: app.db).delete()
    }

    func c22ValidationAndModules(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        let other = try await second(app, auth, owner)
        try await c22Model(app, owner)
        let query = "format=worktime-xlsx&from=2026-10-05&to=2026-10-12"
        _ = try await exportFetch(app, nil, query, status: .unauthorized)
        for suffix in ["times=", "times=raw", "times=Actual", "pauseMinutes=", "pauseMinutes=-1", "pauseMinutes=241", "pauseMinutes=1.5", "pauseMinutes=abc", "standardStart=8:00", "standardStart=24:00", "standardStart=29:59", "standardStart=08:60", "standardStart=", "dateSystem=", "dateSystem=1901"] {
            let response = try await exportFetch(app, owner, query + "&" + suffix, status: .badRequest)
            try await eq(errorCode(response), "bad_request")
        }
        for suffix in ["pauseMinutes=0", "pauseMinutes=240", "times=actual", "standardStart=23:59", "dateSystem=1904"] {
            _ = try ExportReaders.xlsx(exportBytes(try await exportFetch(app, owner, query + "&" + suffix)))
        }
        _ = try await exportFetch(app, owner, "format=worktime-xlsx&from=2026-01-01&to=2027-01-01")
        _ = try await exportFetch(app, owner, "format=worktime-xlsx&from=2026-01-01&to=2027-01-02", status: .badRequest)
        try await createAbsence(app, owner, absenceBody("2026-10-06", extra: ["note": "Synthetic private note"]))
        let before = try ExportReaders.xlsx(exportBytes(try await exportFetch(app, owner, query)))
        let r = try XCTUnwrap(before.rowNumber(serial: FormulaXLSXWriter.serial(try LocalDate("2026-10-06"), date1904: false)))
        XCTAssertTrue(before.value("F\(r)")?.contains("Synthetic private note") == true)
        let foreign = try ExportReaders.xlsx(exportBytes(try await exportFetch(app, other, query)))
        XCTAssertFalse(foreign.sheet.cells.values.contains { $0.value.contains("Synthetic private note") })
        try await api(app, owner, .PUT, "me/modules", ["modules": ["planning": false]])
        let disabled = try ExportReaders.xlsx(exportBytes(try await exportFetch(app, owner, query)))
        XCTAssertNil(disabled.value("B\(r)")); XCTAssertNil(disabled.value("F\(r)"))
        XCTAssertEqual(disabled.seconds("E\(r)"), -27720)
        try await api(app, owner, .PUT, "me/modules", ["modules": ["transfer": false]])
        _ = try await exportFetch(app, owner, query, status: .notFound)
        try await api(app, owner, .PUT, "me/modules", ["modules": ["transfer": true]])
        try await api(app, owner, .PUT, "admin/modules", ["modules": ["transfer": false]])
        _ = try await exportFetch(app, other, query, status: .notFound)
        try await api(app, owner, .PUT, "admin/modules", ["modules": ["transfer": true]])
        try await AbsenceRecord.query(on: app.db).delete()
    }
    func testC22RoundTripSQLite() async throws { try await withApp(c22RoundTrip) }
    func testC22ValidationAndModulesSQLite() async throws { try await withApp(c22ValidationAndModules) }
    func testC22ExportMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_c22", "DB_TLS": "off"]
        for scenario in [c22RoundTrip, c22ValidationAndModules] { try await withApp(environment: environment, scenario) }
    }
}
