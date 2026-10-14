import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// C12: import REST scenarios. Each scenario runs on SQLite and (gated on MARIADB_TEST_HOST) on MariaDB.
extension AuthTests {
    static let importCSV = """
        Datum;Beginn;Ende;Ort;Art;Notiz
        03.11.2026;08:00;12:00;Büro;Arbeit;=HYPERLINK("http://example.invalid","x")
        03.11.2026;12:30;16:45;büro;;
        04.11.2026;08:00;12:00;Garten;;
        05.11.2026;17:00;09:00;;;
        Summe;;;;;
        xx.11.2026;08:00;09:00;;;
        03.11.2026;08:00;12:00;Büro;Arbeit;again
        06.11.2026;09:30;11:00;;;
        06.11.2026;10:00;11:00;;;

        """

    func importMapping(headerRow: Int = 1, extra: [String: Any] = [:]) -> [String: Any] {
        ["sheet": "CSV", "headerRow": headerRow, "timezone": "Europe/Berlin", "dateFormat": "dd.MM.yyyy", "timeFormat": "HH:mm",
         "columns": ["date": 0, "start": 1, "end": 2, "place": 3, "kind": 4, "note": 5]].merging(extra) { _, new in new }
    }

    @discardableResult
    func importUpload(_ app: Application, _ context: AuthContext?, _ name: String, _ data: Data, _ status: HTTPStatus = .created,
                      field: String = "file", csrf: Bool = true) async throws -> XCTHTTPResponse {
        let boundary = "TTBOUNDARY"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var head = context.map { headers($0, csrf: csrf) } ?? [:]
        head.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=\(boundary)")
        let response = try await app.testable().sendRequest(.POST, "/api/v1/imports", headers: head, body: ByteBuffer(data: body))
        XCTAssertEqual(response.status, status, response.body.string)
        return response
    }

    func importJob(_ app: Application, _ context: AuthContext, _ csv: String = AuthTests.importCSV, name: String = "zeiten.csv") async throws -> String {
        let job = try object(await importUpload(app, context, name, Data(csv.utf8)))
        try await eq(job["status"] as? String, "uploaded")
        return try XCTUnwrap(job["id"] as? String)
    }

    func importSegments(_ app: Application, _ context: AuthContext, voided: Bool = false) async throws -> [[String: Any]] {
        let list = try await api(app, context, .GET, "time/segments?from=2026-11-01T00:00:00Z&to=2026-12-01T00:00:00Z&includeVoided=\(voided)")
        return try XCTUnwrap(json(list) as? [[String: Any]])
    }

    func importSetup(_ app: Application, _ auth: AuthService, handle: String = "admin", admin: AuthContext? = nil) async throws -> AuthContext {
        let (context, _) = try await registered(auth, db: app.db, handle: handle, admin: admin)
        var place = placeBody(); place["name"] = "Büro"
        try await api(app, context, .POST, "places", place, .created)
        // Existing manual segment on 06.11.2026 09:00-10:00 (Berlin) used for overlap detection.
        try await api(app, context, .POST, "time/segments", segmentBody("2026-11-06T08:00:00Z", "2026-11-06T09:00:00Z"), .created)
        return context
    }

    func scenarioImportFlow(_ app: Application, _ auth: AuthService) async throws {
        let context = try await importSetup(app, auth)
        // Uploading creates nothing.
        let id = try await importJob(app, context)
        try await eq(try await importSegments(app, context).count, 1)
        let job = try object(await api(app, context, .GET, "imports/\(id)"))
        try await eq(job["kind"] as? String, "csv"); try await eq(job["sheets"] as? [String], ["CSV"]); try await eq((job["sha256"] as? String)?.count, 64)
        // Raw preview: first rows, empty cells as null.
        let raw = try object(await api(app, context, .GET, "imports/\(id)/preview"))
        let rawRows = try XCTUnwrap(raw["rows"] as? [[Any]]); try await eq(rawRows.count, 10); try await eq(rawRows[0].first as? String, "Datum")
        // State machine: not ready before a mapping exists.
        var response = try await api(app, context, .POST, "imports/\(id)/commit", nil, .conflict); try await eq(errorCode(response), "import_not_ready")
        response = try await api(app, context, .POST, "imports/\(id)/rollback", nil, .conflict); try await eq(errorCode(response), "import_not_ready")
        // Invalid mappings are 400 and store nothing.
        try await api(app, context, .PUT, "imports/\(id)/mapping", importMapping(extra: ["columns": ["date": 0, "start": 1]]), .badRequest)
        try await api(app, context, .PUT, "imports/\(id)/mapping", importMapping(extra: ["dateFormat": "dd/MM/yyyy"]), .badRequest)
        try await api(app, context, .PUT, "imports/\(id)/mapping", importMapping(extra: ["timezone": "Mars/Base"]), .badRequest)
        try await eq(try object(await api(app, context, .GET, "imports/\(id)"))["status"] as? String, "uploaded")

        let preview = try object(await api(app, context, .PUT, "imports/\(id)/mapping", importMapping()))
        try await eq(preview["rows"] as? Int, 8); try await eq(preview["valid"] as? Int, 3); try await eq(preview["duplicates"] as? Int, 1)
        let errors = try XCTUnwrap(preview["errors"] as? [[String: Any]])
        try await eq(errors.map { "\($0["row"] as! Int):\($0["code"] as! String)" }, ["4:unknown_place", "5:end_before_start", "7:date_invalid", "9:overlap"])
        try await eq((preview["sample"] as? [[String: Any]])?.count, 3)
        try await eq(preview["skippedSummaryRows"] as? Int, 1)
        try await eq(try await importSegments(app, context).count, 1)   // a preview never writes
        try await eq(try object(await api(app, context, .GET, "imports/\(id)"))["status"] as? String, "mapped")

        // Errors block the commit unless explicitly ignored.
        response = try await api(app, context, .POST, "imports/\(id)/commit", nil, .conflict); try await eq(errorCode(response), "import_has_errors")
        try await eq(try await importSegments(app, context).count, 1)
        let result = try object(await api(app, context, .POST, "imports/\(id)/commit", ["ignoreErrors": true]))
        try await eq(result["created"] as? Int, 3); try await eq(result["skipped"] as? Int, 5)
        let batchId = try XCTUnwrap(result["batchId"] as? String)
        let segments = try await importSegments(app, context)
        let imported = segments.filter { $0["source"] as? String == "import" }
        try await eq(imported.count, 3)
        try await eq(imported.map { $0["startedAt"] as! String }.sorted(), ["2026-11-03T07:00:00Z", "2026-11-03T11:30:00Z", "2026-11-06T09:00:00Z"])
        // Formula-like text stays plain text and the place was matched case-insensitively.
        let first = try XCTUnwrap(imported.first { $0["startedAt"] as? String == "2026-11-03T07:00:00Z" })
        try await eq(first["note"] as? String, "=HYPERLINK(\"http://example.invalid\",\"x\")")
        let placeIds = Set(imported.filter { $0["startedAt"] as? String != "2026-11-06T09:00:00Z" }.compactMap { $0["placeId"] as? String })
        try await eq(placeIds.count, 1)
        // Committed jobs cannot be committed again, discarded or re-mapped.
        response = try await api(app, context, .POST, "imports/\(id)/commit", nil, .conflict); try await eq(errorCode(response), "import_not_ready")
        response = try await api(app, context, .DELETE, "imports/\(id)", nil, .conflict); try await eq(errorCode(response), "import_not_ready")
        response = try await api(app, context, .PUT, "imports/\(id)/mapping", importMapping(), .conflict); try await eq(errorCode(response), "import_not_ready")
        response = try await api(app, context, .GET, "imports/\(id)/preview", nil, .conflict); try await eq(errorCode(response), "import_not_ready")
        try await eq(try object(await api(app, context, .GET, "imports/\(id)"))["status"] as? String, "committed")

        // Same file again: no duplicates, nothing created.
        let again = try await importJob(app, context)
        let repeatPreview = try object(await api(app, context, .PUT, "imports/\(again)/mapping", importMapping()))
        try await eq(repeatPreview["valid"] as? Int, 0); try await eq(repeatPreview["duplicates"] as? Int, 4)
        let repeatResult = try object(await api(app, context, .POST, "imports/\(again)/commit", ["ignoreErrors": true]))
        try await eq(repeatResult["created"] as? Int, 0); try await eq(repeatResult["skipped"] as? Int, 8)
        try await eq(try await importSegments(app, context).count, 4)

        // Rollback of unchanged segments voids them and marks the job.
        let rolled = try object(await api(app, context, .POST, "imports/\(id)/rollback"))
        try await eq(rolled["batchId"] as? String, batchId); try await eq(rolled["rolledBack"] as? Int, 3)
        try await eq(try await importSegments(app, context).count, 1)
        try await eq(try await importSegments(app, context, voided: true).count, 4)
        try await eq(try object(await api(app, context, .GET, "imports/\(id)"))["status"] as? String, "rolled_back")
        response = try await api(app, context, .POST, "imports/\(id)/rollback", nil, .conflict); try await eq(errorCode(response), "import_not_ready")

        // Import once more, then change one segment: rollback is refused and names exactly that segment.
        let third = try await importJob(app, context)
        try await api(app, context, .PUT, "imports/\(third)/mapping", importMapping())
        try await eq(try object(await api(app, context, .POST, "imports/\(third)/commit", ["ignoreErrors": true]))["created"] as? Int, 3)
        let fresh = try await importSegments(app, context).filter { $0["source"] as? String == "import" }
        let changed = try XCTUnwrap(fresh.first { $0["startedAt"] as? String == "2026-11-03T07:00:00Z" })
        let changedId = try XCTUnwrap(changed["id"] as? String)
        try await api(app, context, .PATCH, "time/segments/\(changedId)", ["note": "edited", "reason": "typo"], version: 1)
        let conflict = try await api(app, context, .POST, "imports/\(third)/rollback", nil, .conflict)
        try await eq(errorCode(conflict), "rollback_conflict")
        try await eq(((try object(conflict))["conflicts"] as? [String]), [changedId])
        try await eq(try await importSegments(app, context).filter { $0["source"] as? String == "import" }.count, 3)   // nothing was voided
        try await eq(try object(await api(app, context, .GET, "imports/\(third)"))["status"] as? String, "committed")
    }

    func scenarioImportDiscardTemplatesAndIsolation(_ app: Application, _ auth: AuthService) async throws {
        let context = try await importSetup(app, auth)
        let other = try await importSetup(app, auth, handle: "other", admin: context)
        let id = try await importJob(app, context)
        try await api(app, context, .PUT, "imports/\(id)/mapping", importMapping())
        // Foreign accounts see nothing, by direct ID, on every route.
        for (method, path, body) in [(HTTPMethod.GET, "imports/\(id)", nil), (.GET, "imports/\(id)/preview", nil), (.DELETE, "imports/\(id)", nil),
                                      (.PUT, "imports/\(id)/mapping", importMapping()), (.POST, "imports/\(id)/commit", ["ignoreErrors": true]),
                                      (.POST, "imports/\(id)/rollback", nil)] as [(HTTPMethod, String, [String: Any]?)] {
            let response = try await api(app, other, method, path, body, .notFound)
            try await eq(errorCode(response), "not_found")
        }
        try await api(app, context, .GET, "imports/not-a-uuid", nil, .notFound)
        try await eq(try object(await api(app, context, .GET, "imports/\(id)"))["status"] as? String, "mapped")
        // Templates are per account.
        let template = try object(await api(app, context, .POST, "import-templates", ["name": "Excel Büro", "mapping": importMapping()], .created))
        let templateId = try XCTUnwrap(template["id"] as? String)
        try await eq((template["mapping"] as? [String: Any])?["dateFormat"] as? String, "dd.MM.yyyy")
        try await eq(try (json(await api(app, context, .GET, "import-templates")) as? [[String: Any]])?.count, 1)
        try await eq(try (json(await api(app, other, .GET, "import-templates")) as? [[String: Any]])?.count, 0)
        try await api(app, other, .DELETE, "import-templates/\(templateId)", nil, .notFound)
        try await api(app, context, .POST, "import-templates", ["name": "", "mapping": importMapping()], .badRequest)
        try await api(app, context, .POST, "import-templates", ["name": String(repeating: "x", count: 81), "mapping": importMapping()], .badRequest)
        try await api(app, context, .POST, "import-templates", ["name": "bad", "mapping": importMapping(extra: ["columns": ["date": 0]])], .badRequest)
        try await api(app, context, .DELETE, "import-templates/\(templateId)", nil, .noContent)
        try await api(app, context, .DELETE, "import-templates/\(templateId)", nil, .notFound)
        // Discard removes the job and its stored file.
        try await api(app, context, .DELETE, "imports/\(id)", nil, .noContent)
        try await api(app, context, .GET, "imports/\(id)", nil, .notFound)
        try await eq(try await ImportFileRecord.query(on: app.db).count(), 0)
        try await eq(try await ImportMappingRecord.query(on: app.db).count(), 0)
        // Authentication, CSRF and recovery sessions.
        try await importUpload(app, nil, "a.csv", Data("a;b\n".utf8), .unauthorized)
        try await importUpload(app, context, "a.csv", Data("a;b\n".utf8), .forbidden, csrf: false)
        try await timeRequest(app, nil, .GET, "imports/\(id)", status: .unauthorized)
        let recovery = try await auth.issueSession(for: context.account, recovery: true, on: app.db)
        try await importUpload(app, recovery, "a.csv", Data("a;b\n".utf8), .forbidden)
        try await api(app, recovery, .GET, "import-templates", nil, .forbidden)
    }

    func scenarioImportUploadLimits(_ app: Application, _ auth: AuthService) async throws {
        let context = try await importSetup(app, auth)
        var response = try await importUpload(app, context, "big.csv", Data(count: 5 * 1024 * 1024 + 1), .payloadTooLarge)
        try await eq(errorCode(response), "file_too_large")
        response = try await importUpload(app, context, "evil.csv", try TestXLSX.build(sheets: [("S", [[.shared("a")]])]), .unsupportedMediaType)
        try await eq(errorCode(response), "unsupported_type")
        response = try await importUpload(app, context, "evil.xlsx", Data("a;b\n1;2\n".utf8), .unsupportedMediaType)
        try await eq(errorCode(response), "unsupported_type")
        response = try await importUpload(app, context, "x.pdf", Data("%PDF-1.4".utf8), .unsupportedMediaType)
        try await eq(errorCode(response), "unsupported_type")
        response = try await importUpload(app, context, "x.csv", Data([0x25, 0x50, 0x44, 0x46, 0x00, 0x01, 0x02]), .unsupportedMediaType)
        try await eq(errorCode(response), "unsupported_type")
        let bomb = try TestXLSX.build(sheets: [("S", [[.shared("a")]])], extra: [("xl/bomb.bin", Data(count: 60 * 1024 * 1024))])
        response = try await importUpload(app, context, "bomb.xlsx", bomb, .payloadTooLarge)
        try await eq(errorCode(response), "file_too_large")
        response = try await importUpload(app, context, "rows.csv", Data((0..<20_001).map { _ in "a;b" }.joined(separator: "\n").utf8), .badRequest)
        try await eq(errorCode(response), "too_many_rows")
        response = try await importUpload(app, context, "x.csv", Data("a;b".utf8), .badRequest, field: "other")
        try await eq(errorCode(response), "bad_request")
        response = try await importUpload(app, context, "empty.csv", Data(), .badRequest)
        try await timeRequest(app, context, .POST, "imports", ["file": "x"], status: .badRequest)
        try await eq(try await ImportJobRecord.query(on: app.db).count(), 0)
        // Hostile file names are reduced to a safe base name.
        let job = try object(await importUpload(app, context, "../../etc/pass\u{7}wd.csv", Data("a;b\n".utf8)))
        try await eq(job["filename"] as? String, "passwd.csv")
        // At most 20 open uploads per account.
        for _ in 0..<19 { try await importUpload(app, context, "a.csv", Data("a;b\n".utf8)) }
        try await importUpload(app, context, "a.csv", Data("a;b\n".utf8), .conflict)
    }

    func scenarioImportXLSX(_ app: Application, _ auth: AuthService) async throws {
        let context = try await importSetup(app, auth)
        let data = try TestXLSX.build(sheets: [("Info", [[.shared("nichts")]]), ("Zeiten", [
            [.shared("Datum"), .shared("Beginn"), .shared("Ende"), .shared("Notiz")],
            [.num("46329", style: 1), .num("0.3333333333333333", style: 2), .num("0.5", style: 2), .inline("=SUM(A1)")],
            [.num("46329", style: 1), .num("0.5416666666666666", style: 2), .formula("B3+0.2", cached: nil), .shared("ohne Wert")],
            [.num("46330", style: 1), .num("0.3333333333333333", style: 2), .formula("B4+0.25", cached: "0.5833333333333334"), .shared("mit Wert")],
            [.shared("Summe"), .empty, .empty, .empty],
        ])])
        let id = try object(await importUpload(app, context, "zeiten.xlsx", data))["id"] as! String
        try await eq(try object(await api(app, context, .GET, "imports/\(id)"))["sheets"] as? [String], ["Info", "Zeiten"])
        let raw = try object(await api(app, context, .GET, "imports/\(id)/preview?sheet=Zeiten"))
        try await eq((raw["rows"] as? [[Any]])?[1].first as? String, "2026-11-03")
        try await api(app, context, .GET, "imports/\(id)/preview?sheet=Nope", nil, .badRequest)
        let mapping = ["sheet": "Zeiten", "headerRow": 1, "dateFormat": "excel_serial", "timeFormat": "excel_fraction", "columns": ["date": 0, "start": 1, "end": 2, "note": 3]] as [String: Any]
        let preview = try object(await api(app, context, .PUT, "imports/\(id)/mapping", mapping))
        try await eq(preview["valid"] as? Int, 2); try await eq(preview["skippedSummaryRows"] as? Int, 1)
        try await eq((preview["errors"] as? [[String: Any]])?.map { $0["code"] as! String }, ["formula_without_value"])
        try await api(app, context, .POST, "imports/\(id)/commit", nil, .conflict)
        try await eq(try object(await api(app, context, .POST, "imports/\(id)/commit", ["ignoreErrors": true]))["created"] as? Int, 2)
        let imported = try await importSegments(app, context).filter { $0["source"] as? String == "import" }
        try await eq(imported.map { $0["startedAt"] as! String }.sorted(), ["2026-11-03T07:00:00Z", "2026-11-04T07:00:00Z"])
        try await eq(imported.map { $0["endedAt"] as! String }.sorted(), ["2026-11-03T11:00:00Z", "2026-11-04T13:00:00Z"])
        try await eq(imported.compactMap { $0["note"] as? String }.sorted(), ["=SUM(A1)", "mit Wert"])
    }

    func scenarioImportConcurrentCommit(_ app: Application, _ auth: AuthService) async throws {
        let context = try await importSetup(app, auth)
        let csv = "Datum;Beginn;Ende\n" + (1...12).map { String(format: "%02d.11.2026;08:00;12:00", $0 + 8) }.joined(separator: "\n") + "\n"
        let id = try await importJob(app, context, csv)
        var mapping = importMapping(); mapping["columns"] = ["date": 0, "start": 1, "end": 2]
        try await eq(try object(await api(app, context, .PUT, "imports/\(id)/mapping", mapping))["valid"] as? Int, 12)
        let head = headers(context)
        let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await app.testable().sendRequest(.POST, "/api/v1/imports/\(id)/commit", headers: head).status
                }
            }
            var all: [HTTPStatus] = []
            for try await status in group { all.append(status) }
            return all
        }
        try await eq(statuses.filter { $0 == .ok }.count, 1)
        try await eq(statuses.filter { $0 == .conflict }.count, 3)
        try await eq(try await importSegments(app, context).filter { $0["source"] as? String == "import" }.count, 12)
        try await eq(try await ImportBatchRecord.query(on: app.db).count(), 1)
    }

    func scenarioImportHeaderless(_ app: Application, _ auth: AuthService) async throws {
        // No header row, ISO dates, decimal hours as duration (7,7 h = 7:42), other time zone, kind default.
        let context = try await importSetup(app, auth)
        let id = try await importJob(app, context, "2026-11-10,8,7.7\n2026-11-11,8,\"7,7\"\n")
        let mapping: [String: Any] = ["sheet": "CSV", "headerRow": 0, "timezone": "UTC", "dateFormat": "yyyy-MM-dd", "timeFormat": "decimal_hours",
                                      "defaultKind": "school", "columns": ["date": 0, "start": 1, "duration": 2]]
        try await eq(try object(await api(app, context, .PUT, "imports/\(id)/mapping", mapping))["valid"] as? Int, 2)
        try await api(app, context, .POST, "imports/\(id)/commit")
        let imported = try await importSegments(app, context).filter { $0["source"] as? String == "import" }
        try await eq(imported.map { $0["endedAt"] as! String }.sorted(), ["2026-11-10T15:42:00Z", "2026-11-11T15:42:00Z"])
        try await eq(Set(imported.map { $0["kind"] as! String }), ["school"])
    }

    private var importScenarios: [Scenario] {
        [scenarioImportFlow, scenarioImportDiscardTemplatesAndIsolation, scenarioImportUploadLimits, scenarioImportXLSX,
         scenarioImportConcurrentCommit, scenarioImportHeaderless]
    }

    func testImportRESTSQLite() async throws {
        for scenario in importScenarios { try await withApp(scenario) }
    }

    func testImportRESTMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"]
        for scenario in importScenarios { try await withApp(environment: environment, scenario) }
    }

    /// Exercises the real streaming path (no in-memory shortcut): an oversize body must map to file_too_large.
    func testImportOversizeOverRealServer() async throws {
        try await withApp { app, auth in
            let context = try await importSetup(app, auth)
            try await app.testable(method: .running(port: 0)).test(.POST, "/api/v1/imports", beforeRequest: { request async throws in
                let boundary = "TTBOUNDARY"
                var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"big.csv\"\r\n\r\n".utf8)
                body.append(Data(repeating: 0x61, count: 6 * 1024 * 1024)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
                request.headers = headers(context)
                request.headers.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=\(boundary)")
                request.body = ByteBuffer(data: body)
            }, afterResponse: { response async throws in
                XCTAssertEqual(response.status, .payloadTooLarge)
                XCTAssertTrue(response.body.string.contains("file_too_large"))
            })
        }
    }
}
