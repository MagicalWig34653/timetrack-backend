import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// C15: Berichtsheft REST scenarios. Each runs on SQLite and (gated on MARIADB_TEST_HOST) on MariaDB.

extension AuthTests {
    func entryBody(_ date: String, _ field: String = "Lernfeld 1", seconds: Int = 3600, notes: String = "", fieldId: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["date": date, "learningField": field, "durationSeconds": seconds, "notes": notes]
        if let fieldId { body["learningFieldId"] = fieldId }
        return body
    }
    @discardableResult
    func entry(_ app: Application, _ context: AuthContext, _ body: [String: Any]) async throws -> [String: Any] {
        try object(await api(app, context, .POST, "reports/entries", body, .created))
    }
    func week(_ app: Application, _ context: AuthContext, _ year: Int, _ week: Int, _ status: HTTPStatus = .ok) async throws -> [String: Any] {
        try object(await api(app, context, .GET, "reports/weeks/\(year)/\(week)", nil, status))
    }
    func weekEntries(_ app: Application, _ context: AuthContext, _ year: Int, _ week: Int) async throws -> [[String: Any]] {
        let value = try await self.week(app, context, year, week)["entries"] as? [[String: Any]]
        return try XCTUnwrap(value)
    }
    func reportText(_ app: Application, _ context: AuthContext, _ year: Int, _ week: Int) async throws -> (String, XCTHTTPResponse) {
        let response = try await api(app, context, .GET, "reports/weeks/\(year)/\(week)/text")
        return (response.body.string, response)
    }

    func scenarioReportLearningFields(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let created = try object(await api(app, context, .POST, "reports/learning-fields", ["number": 3, "name": "  Netzwerke  ", "sortOrder": 2], .created))
        let id = try XCTUnwrap(created["id"] as? String)
        try await eq(created["name"] as? String, "Netzwerke"); try await eq(created["number"] as? Int, 3)
        try await api(app, context, .POST, "reports/learning-fields", ["name": "ÄRZTE"], .created)
        // Names are unique per account, ignoring case (also for non-ASCII).
        try await eq(try errorCode(await api(app, context, .POST, "reports/learning-fields", ["name": "netzwerke"], .conflict)), "learning_field_exists")
        try await api(app, context, .POST, "reports/learning-fields", ["name": "ärzte"], .conflict)
        // Validation.
        try await api(app, context, .POST, "reports/learning-fields", ["name": "   "], .badRequest)
        try await api(app, context, .POST, "reports/learning-fields", ["name": String(repeating: "x", count: 121)], .badRequest)
        try await api(app, context, .POST, "reports/learning-fields", ["name": String(repeating: "x", count: 120)], .created)
        try await api(app, context, .POST, "reports/learning-fields", ["name": "N", "number": -1], .badRequest)
        try await api(app, context, .POST, "reports/learning-fields", ["number": 1], .badRequest)
        // A 120-scalar name made of emoji (4 bytes each) still fits.
        try await api(app, context, .POST, "reports/learning-fields", ["name": String(repeating: "🎓", count: 120)], .created)
        try await api(app, context, .POST, "reports/learning-fields", ["name": String(repeating: "🎓", count: 121)], .badRequest)
        // Sorting: sortOrder, then name.
        let names = try list(await api(app, context, .GET, "reports/learning-fields")).compactMap { $0["name"] as? String }
        try await eq(names.count, 4); try await eq(names.last, "Netzwerke")   // sortOrder 2 comes after the three with 0
        // Update (rename to own name differing in case is allowed, clash with another is not).
        let renamed = try object(await api(app, context, .PUT, "reports/learning-fields/" + id, ["name": "NETZWERKE", "number": 4, "sortOrder": 0]))
        try await eq(renamed["name"] as? String, "NETZWERKE"); try await eq(renamed["number"] as? Int, 4)
        try await api(app, context, .PUT, "reports/learning-fields/" + id, ["name": "Ärzte"], .conflict)
        try await api(app, context, .PUT, "reports/learning-fields/" + UUID().uuidString, ["name": "Neu"], .notFound)
        try await api(app, context, .DELETE, "reports/learning-fields/" + id, nil, .noContent)
        try await api(app, context, .DELETE, "reports/learning-fields/" + id, nil, .notFound)
        // The freed name can be used again.
        try await api(app, context, .POST, "reports/learning-fields", ["name": "netzwerke"], .created)
    }

    func scenarioReportEntries(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let field = try object(await api(app, context, .POST, "reports/learning-fields", ["name": "Lernfeld 4"], .created))
        let fieldId = try XCTUnwrap(field["id"] as? String)

        // Create: the id wins, the current field name becomes the snapshot.
        let created = try await entry(app, context, entryBody("2026-10-12", "ignored", seconds: 5400, notes: "Notiz", fieldId: fieldId))
        let id = try XCTUnwrap(created["id"] as? String)
        try await eq(created["learningField"] as? String, "Lernfeld 4"); try await eq(created["learningFieldId"] as? String, fieldId)
        try await eq(created["version"] as? Int, 1); try await eq(created["draft"] as? Bool, false); XCTAssertNotNil(created["createdAt"])
        // Defaults: duration 0, notes empty; free text field name.
        let minimal = try await entry(app, context, ["date": "2026-10-13", "learningField": "Frei"])
        try await eq(minimal["durationSeconds"] as? Int, 0); try await eq(minimal["notes"] as? String, "")
        try await eq(minimal["learningFieldId"] as? String, nil)

        // Validation.
        try await api(app, context, .POST, "reports/entries", entryBody("2026-02-30"), .badRequest)
        try await api(app, context, .POST, "reports/entries", entryBody("12.10.2026"), .badRequest)
        try await api(app, context, .POST, "reports/entries", entryBody("2026-10-12", seconds: -1), .badRequest)
        try await api(app, context, .POST, "reports/entries", entryBody("2026-10-12", seconds: 86_401), .badRequest)
        try await api(app, context, .POST, "reports/entries", entryBody("2026-10-12", seconds: 86_400), .created)
        try await api(app, context, .POST, "reports/entries", ["date": "2026-10-12"], .badRequest)
        try await api(app, context, .POST, "reports/entries", entryBody("2026-10-12", " "), .badRequest)
        try await api(app, context, .POST, "reports/entries", entryBody("2026-10-12", String(repeating: "ä", count: 121)), .badRequest)
        try await api(app, context, .POST, "reports/entries", entryBody("2026-10-12", "ok", seconds: 1, notes: String(repeating: "ä", count: 4000)), .created)
        try await api(app, context, .POST, "reports/entries", entryBody("2026-10-12", "ok", seconds: 1, notes: String(repeating: "ä", count: 4001)), .badRequest)
        // 4000 scalars of 4 bytes each fit as well (and 4001 do not).
        try await api(app, context, .POST, "reports/entries", entryBody("2026-10-12", "ok", seconds: 1, notes: String(repeating: "😀", count: 4000)), .created)
        try await api(app, context, .POST, "reports/entries", entryBody("2026-10-12", "ok", seconds: 1, notes: String(repeating: "😀", count: 4001)), .badRequest)
        // A decomposed character counts as two scalars.
        try await api(app, context, .POST, "reports/entries", entryBody("2026-10-12", "ok", seconds: 1, notes: String(repeating: "e\u{301}", count: 2001)), .badRequest)
        try await api(app, context, .POST, "reports/entries", entryBody("2026-10-12", "ok", fieldId: "not-a-uuid"), .badRequest)
        try await api(app, context, .POST, "reports/entries", entryBody("2026-10-12", "ok", fieldId: UUID().uuidString), .notFound)

        // Update with If-Match.
        var update = entryBody("2026-10-14", "Lernfeld 4", seconds: 600, notes: "neu", fieldId: fieldId)
        let updated = try object(await api(app, context, .PUT, "reports/entries/" + id, update, version: 1))
        try await eq(updated["version"] as? Int, 2); try await eq(updated["date"] as? String, "2026-10-14"); try await eq(updated["durationSeconds"] as? Int, 600)
        try await eq(try errorCode(await api(app, context, .PUT, "reports/entries/" + id, update, .preconditionFailed, version: 1)), "stale_version")
        try await api(app, context, .PUT, "reports/entries/" + id, update, .preconditionFailed)   // no If-Match at all
        try await api(app, context, .PUT, "reports/entries/" + id, update, .preconditionFailed, version: 99)
        update["durationSeconds"] = -5
        try await api(app, context, .PUT, "reports/entries/" + id, update, .badRequest, version: 2)
        // A rejected update changes nothing.
        let stored = try await week(app, context, 2026, 42)
        let entries = try XCTUnwrap(stored["entries"] as? [[String: Any]])
        try await eq(entries.first { $0["id"] as? String == id }?["version"] as? Int, 2)
        // Quoted ETag-style If-Match values are accepted.
        update["durationSeconds"] = 700
        try await timeRequest(app, context, .PUT, "reports/entries/" + id, update, status: .ok, extra: ["If-Match": "\"2\""])

        try await api(app, context, .DELETE, "reports/entries/" + id, nil, .noContent)
        try await api(app, context, .DELETE, "reports/entries/" + id, nil, .notFound)
        try await api(app, context, .PUT, "reports/entries/" + id, update, .notFound, version: 3)
    }

    func scenarioReportSnapshots(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let field = try object(await api(app, context, .POST, "reports/learning-fields", ["name": "Alt"], .created))
        let fieldId = try XCTUnwrap(field["id"] as? String)
        let first = try await entry(app, context, entryBody("2026-10-12", seconds: 100, fieldId: fieldId))
        // Renaming keeps the snapshot of existing entries; new entries get the new name.
        try await api(app, context, .PUT, "reports/learning-fields/" + fieldId, ["name": "Neu"])
        let second = try await entry(app, context, entryBody("2026-10-12", seconds: 200, fieldId: fieldId))
        var rows = try await weekEntries(app, context, 2026, 42)
        try await eq(rows.map { $0["learningField"] as? String }, ["Alt", "Neu"])
        // Updating an entry re-reads the current name.
        let firstId = try XCTUnwrap(first["id"] as? String)
        let refreshed = try object(await api(app, context, .PUT, "reports/entries/" + firstId, entryBody("2026-10-12", seconds: 100, fieldId: fieldId), version: 1))
        try await eq(refreshed["learningField"] as? String, "Neu")
        // Deleting the field keeps entries and their snapshots; the dangling id is cleared.
        try await api(app, context, .DELETE, "reports/learning-fields/" + fieldId, nil, .noContent)
        rows = try await weekEntries(app, context, 2026, 42)
        try await eq(rows.count, 2); try await eq(rows.map { $0["learningField"] as? String }, ["Neu", "Neu"])
        XCTAssertTrue(rows.allSatisfy { $0["learningFieldId"] == nil })
        // The entry can still be edited by free text, but not by the deleted id.
        let secondId = try XCTUnwrap(second["id"] as? String)
        try await api(app, context, .PUT, "reports/entries/" + secondId, entryBody("2026-10-12", "Frei", seconds: 200), version: 1)
        try await api(app, context, .PUT, "reports/entries/" + secondId, entryBody("2026-10-12", "x", fieldId: fieldId), .notFound, version: 2)
    }

    func scenarioReportWeeks(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        // Week boundaries.
        let w53 = try await week(app, context, 2020, 53)
        try await eq(w53["startDate"] as? String, "2020-12-28"); try await eq(w53["endDate"] as? String, "2021-01-03")
        let w1 = try await week(app, context, 2025, 1)
        try await eq(w1["startDate"] as? String, "2024-12-30"); try await eq(w1["endDate"] as? String, "2025-01-05")
        try await eq(try await week(app, context, 2021, 1)["startDate"] as? String, "2021-01-04")
        try await eq(try await week(app, context, 2026, 53)["startDate"] as? String, "2026-12-28")   // 2026 has 53 weeks
        for (year, number) in [(2021, 53), (2025, 53), (2024, 53), (2026, 54), (2026, 0), (2026, -1), (1800, 1), (9999, 1)] {
            try await api(app, context, .GET, "reports/weeks/\(year)/\(number)", nil, .badRequest)
            try await api(app, context, .GET, "reports/weeks/\(year)/\(number)/text", nil, .badRequest)
            try await api(app, context, .PUT, "reports/weeks/\(year)/\(number)", ["status": "done"], .badRequest)
        }
        try await api(app, context, .GET, "reports/weeks/abc/1", nil, .badRequest)
        try await api(app, context, .GET, "reports/weeks/2026/x", nil, .badRequest)
        // Dates belong to the right ISO week.
        try await entry(app, context, entryBody("2020-12-31", "A"))
        try await entry(app, context, entryBody("2021-01-03", "B"))
        try await entry(app, context, entryBody("2021-01-04", "C"))
        try await entry(app, context, entryBody("2024-12-29", "D"))
        try await entry(app, context, entryBody("2024-12-30", "E"))
        func fields(_ year: Int, _ number: Int) async throws -> [String] {
            try await weekEntries(app, context, year, number).compactMap { $0["learningField"] as? String }
        }
        try await eq(try await fields(2020, 53), ["A", "B"]); try await eq(try await fields(2021, 1), ["C"])
        try await eq(try await fields(2024, 52), ["D"]); try await eq(try await fields(2025, 1), ["E"])
        try await eq(try await fields(2025, 2), [])

        // Totals per learning field, in order of first appearance (date, then creation).
        try await entry(app, context, entryBody("2026-10-14", "Netzwerke", seconds: 1800))
        try await entry(app, context, entryBody("2026-10-12", "Datenbanken", seconds: 3600))
        try await entry(app, context, entryBody("2026-10-12", "Netzwerke", seconds: 900))
        try await entry(app, context, entryBody("2026-10-18", "Datenbanken", seconds: 60))
        try await entry(app, context, entryBody("2026-10-19", "Außerhalb", seconds: 5000))   // next week
        let week42 = try await week(app, context, 2026, 42)
        try await eq(week42["totalSeconds"] as? Int, 1800 + 3600 + 900 + 60)
        try await eq(week42["startDate"] as? String, "2026-10-12"); try await eq(week42["endDate"] as? String, "2026-10-18")
        try await eq(week42["status"] as? String, "draft"); try await eq(week42["sourceCount"] as? Int, 0)
        let totals = try XCTUnwrap(week42["byLearningField"] as? [[String: Any]])
        try await eq(totals.map { $0["learningField"] as? String }, ["Datenbanken", "Netzwerke"])
        try await eq(totals.map { $0["seconds"] as? Int }, [3660, 2700])
        let order = try XCTUnwrap(week42["entries"] as? [[String: Any]])
        try await eq(order.map { $0["date"] as? String }, ["2026-10-12", "2026-10-12", "2026-10-14", "2026-10-18"])
        try await eq(order.prefix(2).map { $0["learningField"] as? String }, ["Datenbanken", "Netzwerke"])

        // Status: only a marker, entries stay editable.
        let done = try object(await api(app, context, .PUT, "reports/weeks/2026/42", ["status": "done"]))
        try await eq(done["status"] as? String, "done"); try await eq(done["totalSeconds"] as? Int, 6360)
        try await entry(app, context, entryBody("2026-10-15", "Nach Abschluss", seconds: 1))
        try await eq(try await week(app, context, 2026, 42)["status"] as? String, "done")
        try await eq(try object(await api(app, context, .PUT, "reports/weeks/2026/42", ["status": "draft"]))["status"] as? String, "draft")
        try await api(app, context, .PUT, "reports/weeks/2026/42", ["status": "locked"], .badRequest)
        try await api(app, context, .PUT, "reports/weeks/2026/42", [:], .badRequest)
        try await eq(try await week(app, context, 2026, 41)["status"] as? String, "draft")
        let rows = try await ReportWeekStatusRecord.query(on: app.db).count(); try await eq(rows, 1)   // upsert, no duplicates
    }

    func scenarioReportTrackedWork(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        // No work model and no time data: nothing to show.
        try await eq(try await week(app, context, 2026, 42)["trackedWorkSeconds"] as? Int, 0)
        try await planningModel(app, context)
        // The ADR example day (8:07-12:00 and 13:00-16:02 local, 7:15 evaluated) on Monday 2026-10-12.
        try await api(app, context, .POST, "time/segments", segmentBody("2026-10-12T06:07:00Z", "2026-10-12T10:00:00Z"), .created)
        try await api(app, context, .POST, "time/segments", segmentBody("2026-10-12T11:00:00Z", "2026-10-12T14:02:00Z"), .created)
        let day = try object(await api(app, context, .GET, "time/days/2026-10-12"))
        let evaluated = try XCTUnwrap(day["evaluatedWorkSeconds"] as? Int)
        try await eq(evaluated, 26_100)
        try await eq(try await week(app, context, 2026, 42)["trackedWorkSeconds"] as? Int, 26_100)
        // A second day adds up; neighbouring weeks are unaffected.
        try await api(app, context, .POST, "time/segments", segmentBody("2026-10-14T06:00:00Z", "2026-10-14T10:00:00Z"), .created)
        let wednesday = try object(await api(app, context, .GET, "time/days/2026-10-14"))
        let both = 26_100 + (try XCTUnwrap(wednesday["evaluatedWorkSeconds"] as? Int))
        try await eq(try await week(app, context, 2026, 42)["trackedWorkSeconds"] as? Int, both)
        try await eq(try await week(app, context, 2026, 41)["trackedWorkSeconds"] as? Int, 0)
        // A week that lies before the first work model still renders (days outside a model never fail the view).
        _ = try await week(app, context, 2025, 30)
        // The tracked time is a hint only: entries do not change it.
        try await entry(app, context, entryBody("2026-10-12", "A", seconds: 60))
        try await eq(try await week(app, context, 2026, 42)["trackedWorkSeconds"] as? Int, both)
    }

    func scenarioReportText(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        // Empty week.
        let (empty, response) = try await reportText(app, context, 2026, 43)
        try await eq(empty, "Berichtsheft KW 43/2026 (19.10.2026 – 25.10.2026)\n\nSumme: 0:00 h\n")
        try await eq(response.headers.first(name: .contentType), "text/plain; charset=utf-8")
        try await eq(response.headers.first(name: .cacheControl), "no-store")
        // Entries are created out of day order; the output is ordered by day, then creation.
        try await entry(app, context, entryBody("2026-10-14", "Lernfeld 5", seconds: 2700, notes: "Übung €"))
        try await Task.sleep(nanoseconds: 30_000_000)
        try await entry(app, context, entryBody("2026-10-12", "Lernfeld 3: Äpfel", seconds: 5400, notes: "Zeile eins\nZeile zwei\r\n\r\nDritte ß\rVierte\u{2028}Fünfte"))
        try await Task.sleep(nanoseconds: 30_000_000)
        try await entry(app, context, entryBody("2026-10-12", "Berufsschule", seconds: 3600))
        try await Task.sleep(nanoseconds: 30_000_000)
        try await entry(app, context, entryBody("2026-10-18", "=SUMME(A1) | <b>fett</b>", seconds: 59, notes: "  =1+1\t* markiert  "))
        let expected = """
        Berichtsheft KW 42/2026 (12.10.2026 – 18.10.2026)

        Montag, 12.10.2026
        Lernfeld 3: Äpfel | 1:30 h | Zeile eins / Zeile zwei / Dritte ß / Vierte / Fünfte
        Berufsschule | 1:00 h

        Mittwoch, 14.10.2026
        Lernfeld 5 | 0:45 h | Übung €

        Sonntag, 18.10.2026
        =SUMME(A1) | <b>fett</b> | 0:00 h | =1+1\t* markiert

        Summe: 3:15 h

        """
        try await eq(try await reportText(app, context, 2026, 42).0, expected)
        // 24 h and over-midnight durations render as h:mm.
        try await entry(app, context, entryBody("2026-10-20", "Lang", seconds: 86_400))
        try await eq(try await reportText(app, context, 2026, 43).0,
                     "Berichtsheft KW 43/2026 (19.10.2026 – 25.10.2026)\n\nDienstag, 20.10.2026\nLang | 24:00 h\n\nSumme: 24:00 h\n")
        // Year-crossing week.
        try await eq(try await reportText(app, context, 2020, 53).0.hasPrefix("Berichtsheft KW 53/2020 (28.12.2020 – 03.01.2021)\n"), true)
    }

    func scenarioReportSources(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let other = try await second(app, auth, context)
        try await api(app, context, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "maxUploadBytes": 600])
        let fileId = try fileID(await fileUpload(app, context, "notiz.txt", AuthTests.txt))
        let foreignFile = try fileID(await fileUpload(app, other, "fremd.txt", AuthTests.txt))

        let note = try object(await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42, "note": "Meeting-Notizen", "date": "2026-10-13"], .created))
        let noteId = try XCTUnwrap(note["id"] as? String)
        try await eq(note["year"] as? Int, 2026); try await eq(note["date"] as? String, "2026-10-13"); XCTAssertNil(note["fileId"]); XCTAssertNil(note["file"])
        let file = try object(await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42, "fileId": fileId], .created))
        let fileSourceId = try XCTUnwrap(file["id"] as? String)
        try await eq(file["fileId"] as? String, fileId); try await eq((file["file"] as? [String: Any])?["name"] as? String, "notiz.txt")
        try await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42, "note": "Beides", "fileId": fileId], .created)

        // Validation: something is required, files must be owned, the date must lie in the week.
        try await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42], .badRequest)
        try await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42, "note": "  \n"], .badRequest)
        try await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42, "note": String(repeating: "ö", count: 4001)], .badRequest)
        try await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42, "note": String(repeating: "ö", count: 4000)], .created)
        try await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42, "note": "x", "date": "2026-10-19"], .badRequest)
        try await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42, "note": "x", "date": "2026-10-18"], .created)
        try await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42, "note": "x", "date": "2026-13-01"], .badRequest)
        try await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 54, "note": "x"], .badRequest)
        try await api(app, context, .POST, "reports/sources", ["year": 2025, "week": 53, "note": "x"], .badRequest)
        try await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42, "fileId": foreignFile], .notFound)
        try await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42, "fileId": UUID().uuidString], .notFound)
        // Foreign file with a note is refused as well.
        try await api(app, context, .POST, "reports/sources", ["year": 2026, "week": 42, "note": "n", "fileId": foreignFile], .notFound)

        // List, count, delete.
        try await eq(try list(await api(app, context, .GET, "reports/sources?year=2026&week=42")).count, 5)
        try await eq(try list(await api(app, context, .GET, "reports/sources?year=2026&week=41")).count, 0)
        try await api(app, context, .GET, "reports/sources?year=2026", nil, .badRequest)
        try await api(app, context, .GET, "reports/sources?year=2025&week=53", nil, .badRequest)
        try await eq(try await week(app, context, 2026, 42)["sourceCount"] as? Int, 5)
        try await api(app, context, .DELETE, "reports/sources/" + noteId, nil, .noContent)
        try await api(app, context, .DELETE, "reports/sources/" + noteId, nil, .notFound)
        try await eq(try await week(app, context, 2026, 42)["sourceCount"] as? Int, 4)
        // Removing the source keeps the file; removing the file keeps the source (without metadata).
        _ = try await download(app, context, fileId)
        try await api(app, context, .DELETE, "reports/sources/" + fileSourceId, nil, .noContent)
        try await api(app, context, .DELETE, "files/" + fileId, nil, .noContent)
        let remaining = try list(await api(app, context, .GET, "reports/sources?year=2026&week=42"))
        try await eq(remaining.count, 3)
        XCTAssertTrue(remaining.allSatisfy { $0["file"] == nil })
    }

    func scenarioReportIsolation(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        let other = try await second(app, auth, owner)
        try await api(app, owner, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "maxUploadBytes": 600])
        let field = try object(await api(app, owner, .POST, "reports/learning-fields", ["name": "Privat"], .created))
        let fieldId = try XCTUnwrap(field["id"] as? String)
        let created = try await entry(app, owner, entryBody("2026-10-12", seconds: 777, notes: "Geheim", fieldId: fieldId))
        let entryId = try XCTUnwrap(created["id"] as? String)
        let fileId = try fileID(await fileUpload(app, owner, "a.txt", AuthTests.txt))
        let source = try object(await api(app, owner, .POST, "reports/sources", ["year": 2026, "week": 42, "note": "Quelle", "fileId": fileId], .created))
        let sourceId = try XCTUnwrap(source["id"] as? String)
        try await api(app, owner, .PUT, "reports/weeks/2026/42", ["status": "done"])

        // Every resource by direct id answers 404 for another account, and nothing changes.
        try await api(app, other, .PUT, "reports/learning-fields/" + fieldId, ["name": "Gekapert"], .notFound)
        try await api(app, other, .DELETE, "reports/learning-fields/" + fieldId, nil, .notFound)
        try await api(app, other, .PUT, "reports/entries/" + entryId, entryBody("2026-10-12", "Gekapert"), .notFound, version: 1)
        try await api(app, other, .DELETE, "reports/entries/" + entryId, nil, .notFound)
        try await api(app, other, .DELETE, "reports/sources/" + sourceId, nil, .notFound)
        try await api(app, other, .POST, "reports/entries", entryBody("2026-10-12", "x", fieldId: fieldId), .notFound)
        try await api(app, other, .POST, "reports/sources", ["year": 2026, "week": 42, "fileId": fileId], .notFound)
        // Lists and week views of the other account are empty and default.
        try await eq(try list(await api(app, other, .GET, "reports/learning-fields")).count, 0)
        try await eq(try list(await api(app, other, .GET, "reports/sources?year=2026&week=42")).count, 0)
        let view = try await week(app, other, 2026, 42)
        try await eq((view["entries"] as? [Any])?.count, 0); try await eq(view["status"] as? String, "draft"); try await eq(view["sourceCount"] as? Int, 0)
        try await eq(try await reportText(app, other, 2026, 42).0, "Berichtsheft KW 42/2026 (12.10.2026 – 18.10.2026)\n\nSumme: 0:00 h\n")
        // The owner's data is untouched.
        let mine = try await week(app, owner, 2026, 42)
        try await eq((mine["entries"] as? [[String: Any]])?.first?["learningField"] as? String, "Privat")
        try await eq(mine["status"] as? String, "done"); try await eq(mine["sourceCount"] as? Int, 1)
        try await eq(try list(await api(app, owner, .GET, "reports/learning-fields")).count, 1)
        // Setting a status in one account does not touch the other one.
        try await api(app, other, .PUT, "reports/weeks/2026/42", ["status": "done"])
        try await eq(try await week(app, owner, 2026, 42)["status"] as? String, "done")
        try await api(app, other, .PUT, "reports/weeks/2026/42", ["status": "draft"])
        try await eq(try await week(app, owner, 2026, 42)["status"] as? String, "done")
    }

    func scenarioReportNeverShared(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, owner)
        try await planningModel(app, owner)
        try await api(app, owner, .POST, "time/segments", segmentBody("2026-10-12T06:07:00Z", "2026-10-12T10:00:00Z"), .created)
        try await entry(app, owner, entryBody("2026-10-12", "Streng-Geheim-Feld", seconds: 321, notes: "Streng-Geheim-Notiz"))
        try await api(app, owner, .POST, "reports/sources", ["year": 2026, "week": 42, "note": "Streng-Geheim-Quelle"], .created)
        let share = try object(await api(app, owner, .POST, "shares", ["recipientHandle": "member", "scopes": ["plan": true, "actual": true, "vacation": true]], .created))
        let shareId = try XCTUnwrap(share["id"] as? String)
        // The shared view carries plan, actual time and vacation, but no report data of any kind.
        let view = try await api(app, member, .GET, "shares/incoming/\(shareId)/view?from=2026-10-12&to=2026-10-18")
        let body = view.body.string.lowercased()
        XCTAssertTrue(body.contains("2026-10-12"))
        for forbidden in ["streng-geheim", "learningfield", "report", "berichtsheft", "lernfeld", "notes"] {
            XCTAssertFalse(body.contains(forbidden), "shared view leaks '\(forbidden)'")
        }
        // The recipient cannot reach the owner's report data in any way.
        try await eq((try await week(app, member, 2026, 42)["entries"] as? [Any])?.count, 0)
        // Share scopes do not know a report scope: it is refused or ignored, never stored.
        let scoped = try await timeRequest(app, owner, .PATCH, "shares/" + shareId, ["scopes": ["reports": true]], status: .ok)
        XCTAssertFalse(scoped.body.string.lowercased().contains("report"))
        try await eq((try await week(app, member, 2026, 42)["entries"] as? [Any])?.count, 0)
    }

    func scenarioReportAccess(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let id = UUID().uuidString
        let calls: [(HTTPMethod, String, [String: Any]?)] = [
            (.GET, "reports/learning-fields", nil), (.POST, "reports/learning-fields", ["name": "x"]),
            (.PUT, "reports/learning-fields/" + id, ["name": "x"]), (.DELETE, "reports/learning-fields/" + id, nil),
            (.POST, "reports/entries", entryBody("2026-10-12")), (.PUT, "reports/entries/" + id, entryBody("2026-10-12")),
            (.DELETE, "reports/entries/" + id, nil), (.GET, "reports/weeks/2026/42", nil), (.PUT, "reports/weeks/2026/42", ["status": "done"]),
            (.GET, "reports/weeks/2026/42/text", nil), (.GET, "reports/sources?year=2026&week=42", nil),
            (.POST, "reports/sources", ["year": 2026, "week": 42, "note": "x"]), (.DELETE, "reports/sources/" + id, nil),
        ]
        let recovery = try await auth.issueSession(for: context.account, recovery: true, on: app.db)
        for (method, path, body) in calls {
            // Without a session: 401. Without CSRF token on writes: 403. Recovery sessions: 403.
            let anonymous = try await timeRequest(app, nil, method, path, body, status: .unauthorized)
            try await eq(try errorCode(anonymous), "unauthorized")
            if method != .GET {
                var head = headers(context, csrf: false)
                if body != nil { head.contentType = .json }
                let response = try await app.testable().sendRequest(method, "/api/v1/" + path, headers: head,
                    body: try body.map { ByteBuffer(data: try JSONSerialization.data(withJSONObject: $0)) })
                XCTAssertEqual(response.status, .forbidden, "\(method) \(path)")
                try await eq(try errorCode(response), "csrf_invalid")
            }
            let restricted = try await timeRequest(app, recovery, method, path, body, status: .forbidden)
            try await eq(try errorCode(restricted), "recovery_session_restricted")
        }
        // Nothing was created by the rejected writes.
        try await eq(try list(await api(app, context, .GET, "reports/learning-fields")).count, 0)
        let rows = try await ReportEntryRecord.query(on: app.db).count(); try await eq(rows, 0)
        // Malformed bodies.
        try await api(app, context, .POST, "reports/entries", nil, .badRequest)
        try await api(app, context, .POST, "reports/entries", ["date": 5, "learningField": "x"], .badRequest)
        try await api(app, context, .POST, "reports/learning-fields", ["name": 5], .badRequest)
        try await api(app, context, .DELETE, "reports/entries/not-a-uuid", nil, .notFound)
    }

    var reportScenarios: [Scenario] {
        [scenarioReportLearningFields, scenarioReportEntries, scenarioReportSnapshots, scenarioReportWeeks, scenarioReportTrackedWork,
         scenarioReportText, scenarioReportSources, scenarioReportIsolation, scenarioReportNeverShared, scenarioReportAccess]
    }

    func testReportsRESTSQLite() async throws {
        for scenario in reportScenarios { try await withApp(scenario) }
    }

    func testReportsRESTMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"]
        for scenario in reportScenarios { try await withApp(environment: environment, scenario) }
    }
}

final class ReportCalendarTests: XCTestCase {
    /// The arithmetic must agree with Foundation's calendar configured for ISO weeks.
    func testISOWeeksMatchFoundationCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!; calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        var date = try LocalDate("2015-01-01"); let last = try LocalDate("2040-12-31"); var checked = 0
        while date <= last {
            let instant = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))!
            let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: instant)
            let week = try ReportCalendar.week(year: parts.yearForWeekOfYear!, week: parts.weekOfYear!)
            XCTAssertTrue(week.days.contains(date), "\(date) not in KW \(parts.weekOfYear!)/\(parts.yearForWeekOfYear!)")
            XCTAssertEqual(ReportCalendar.isoWeekday(week.start), 1); XCTAssertEqual(ReportCalendar.isoWeekday(week.end), 7)
            date = date.addingDays(1); checked += 1
        }
        XCTAssertGreaterThan(checked, 9000)
    }

    func testYearsWithFiftyThreeWeeks() throws {
        let long = [2015, 2020, 2026, 2032, 2037]
        for year in 2015...2040 {
            let has53 = (try? ReportCalendar.week(year: year, week: 53)) != nil
            XCTAssertEqual(has53, long.contains(year), "\(year)")
        }
        XCTAssertThrowsError(try ReportCalendar.week(year: 2026, week: 54))
        XCTAssertThrowsError(try ReportCalendar.week(year: 2026, week: 0))
        XCTAssertThrowsError(try ReportCalendar.week(year: 1899, week: 1))
        XCTAssertEqual(try ReportCalendar.week(year: 2020, week: 53).end.description, "2021-01-03")
        XCTAssertEqual(try ReportCalendar.week(year: 2025, week: 1).start.description, "2024-12-30")
    }

    func testDurationAndLineFormatting() {
        XCTAssertEqual(ReportText.duration(0), "0:00"); XCTAssertEqual(ReportText.duration(59), "0:00")
        XCTAssertEqual(ReportText.duration(3600), "1:00"); XCTAssertEqual(ReportText.duration(5459), "1:30")
        XCTAssertEqual(ReportText.duration(86_400), "24:00"); XCTAssertEqual(ReportText.duration(-5), "0:00")
        XCTAssertEqual(ReportText.singleLine("a\nb\r\nc\rd\u{2029}e\u{85}f"), "a / b / c / d / e / f")
        XCTAssertEqual(ReportText.singleLine("\n\n  a  \n\n"), "a"); XCTAssertEqual(ReportText.singleLine(""), "")
    }
}
