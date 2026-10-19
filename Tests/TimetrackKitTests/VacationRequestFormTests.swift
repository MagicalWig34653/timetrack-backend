import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// B7: vacation request form template (PDF) and mapping per account. Scenarios run on SQLite and, gated, on MariaDB.

extension AuthTests {
    static let formPDF = Data("%PDF-1.7\n".utf8) + Data((0..<400).map { UInt8($0 % 251) })

    @discardableResult
    func formRequest(_ app: Application, _ context: AuthContext?, _ method: HTTPMethod, _ path: String, body: Data? = nil,
                     type: String? = nil, name: String? = nil, _ status: HTTPStatus = .ok,
                     file: StaticString = #filePath, line: UInt = #line) async throws -> XCTHTTPResponse {
        var head = context.map { headers($0) } ?? [:]
        if let type { head.replaceOrAdd(name: .contentType, value: type) }
        if let name { head.replaceOrAdd(name: "X-File-Name", value: name) }
        let response = try await app.testable().sendRequest(method, "/api/v1/vacation/request-form" + path, headers: head, body: body.map { ByteBuffer(data: $0) })
        XCTAssertEqual(response.status, status, response.body.string, file: file, line: line)
        return response
    }

    func putForm(_ app: Application, _ context: AuthContext?, _ data: Data = AuthTests.formPDF, name: String? = "Urlaubsantrag%20J%C3%BCrgen.pdf",
                 type: String? = "application/pdf", _ status: HTTPStatus = .ok) async throws -> XCTHTTPResponse {
        try await formRequest(app, context, .PUT, "/file", body: data, type: type, name: name, status)
    }
    func putMapping(_ app: Application, _ context: AuthContext?, _ json: String, _ status: HTTPStatus = .ok) async throws -> XCTHTTPResponse {
        try await formRequest(app, context, .PUT, "/mapping", body: Data(json.utf8), type: "application/json", status)
    }

    func scenarioRequestForm(local: Bool) -> Scenario {
        { app, auth in
            let directory = local ? try self.tempDirectory() : nil
            defer { directory.map { try? FileManager.default.removeItem(atPath: $0) } }
            let (admin, _) = try await self.registered(auth, db: app.db)
            try await self.configureLocal(app, admin, directory)
            let a = try await self.second(app, auth, admin, handle: "alpha")
            let b = try await self.second(app, auth, admin, handle: "bravo")
            let aId = try a.account.requireID()
            func stored() async throws -> Int {
                if let directory { return self.diskFiles(directory).count }
                return try await FileBlobRecord.query(on: app.db).count()
            }

            // Nothing stored: explicit nulls, 404 on the file, 409 on the mapping, DELETE idempotent.
            let empty = try self.object(await self.formRequest(app, a, .GET, ""))
            try await self.eq(empty["exists"] as? Bool, false)
            for key in ["fileName", "sizeBytes", "mapping", "updatedAt"] { XCTAssertTrue(empty[key] is NSNull, key) }
            try await self.formRequest(app, a, .GET, "/file", .notFound)
            try await self.eq(try self.errorCode(await self.putMapping(app, a, "{\"version\":1}", .conflict)), "no_template")
            try await self.formRequest(app, a, .DELETE, "", .noContent)

            // Authentication and CSRF.
            try await self.formRequest(app, nil, .GET, "", .unauthorized)
            try await self.putForm(app, nil, .init(), .unauthorized)
            try await self.formRequest(app, nil, .GET, "/file", .unauthorized)
            try await self.formRequest(app, nil, .DELETE, "", .unauthorized)

            // Validation: magic number, empty body, content type, size, bad file name encoding.
            try await self.eq(try self.errorCode(await self.putForm(app, a, Data("not a pdf at all".utf8), .badRequest)), "bad_request")
            try await self.putForm(app, a, Data(), .badRequest)
            try await self.eq(try self.errorCode(await self.putForm(app, a, type: "text/plain", .unsupportedMediaType)), "unsupported_type")
            try await self.putForm(app, a, name: "%ZZ", .badRequest)
            let limit = VacationRequestFormLimits.maxFileBytes
            let tooBig = Data("%PDF-1.4\n".utf8) + Data(repeating: 0x20, count: limit)
            try await self.eq(try self.errorCode(await self.putForm(app, a, tooBig, .payloadTooLarge)), "file_too_large")
            let exact = Data("%PDF-1.4\n".utf8) + Data(repeating: 0x20, count: limit - 9)
            try await self.eq(exact.count, limit)
            try await self.putForm(app, a, exact)   // exactly the limit is accepted
            try await self.formRequest(app, a, .DELETE, "", .noContent)
            try await self.eq(try await stored(), 0)

            // Store, read back, download.
            let created = try self.object(await self.putForm(app, a))
            try await self.eq(created["exists"] as? Bool, true)
            try await self.eq(created["fileName"] as? String, "Urlaubsantrag Jürgen.pdf")
            try await self.eq(created["sizeBytes"] as? Int, AuthTests.formPDF.count)
            try await self.eq((created["mapping"] as? [String: Any])?.count, 0)
            XCTAssertNotNil(created["updatedAt"] as? String)
            try await self.eq(try await stored(), 1)
            let download = try await self.formRequest(app, a, .GET, "/file")
            XCTAssertEqual(Data(download.body.readableBytesView), AuthTests.formPDF)
            XCTAssertEqual(download.headers.first(name: .contentType), "application/pdf")
            XCTAssertEqual(download.headers.first(name: "X-Content-Type-Options"), "nosniff")
            let disposition = try XCTUnwrap(download.headers.first(name: .contentDisposition))
            XCTAssertTrue(disposition.hasPrefix("attachment;") && disposition.contains("filename*=UTF-8''Urlaubsantrag%20J%C3%BCrgen.pdf"), disposition)

            // Default file name, and an extension is added to a bare name.
            try await self.eq(try self.object(await self.putForm(app, a, name: nil))["fileName"] as? String, "Urlaubsantrag.pdf")
            try await self.eq(try self.object(await self.putForm(app, a, name: "Form%20ohne%20Endung"))["fileName"] as? String, "Form ohne Endung.pdf")
            try await self.eq(try await stored(), 1)   // the replaced files are gone

            // Mapping: object only, round trip, kept when the PDF is replaced, size limit.
            let mapping = "{\"version\":1,\"fields\":{\"Name\":{\"source\":\"person.lastName\"}},\"overlays\":[{\"id\":\"x\",\"page\":0,\"x\":1.5}]}"
            let saved = try self.object(await self.putMapping(app, a, mapping))
            try await self.eq((saved["mapping"] as? [String: Any])?["version"] as? Int, 1)
            try await self.putMapping(app, a, "[1,2]", .badRequest)
            try await self.putMapping(app, a, "not json", .badRequest)
            try await self.formRequest(app, a, .PUT, "/mapping", .badRequest)
            let big = "{\"x\":\"" + String(repeating: "a", count: VacationRequestFormLimits.maxMappingBytes) + "\"}"
            try await self.eq(try self.errorCode(await self.putMapping(app, a, big, .payloadTooLarge)), "mapping_too_large")
            let fill = VacationRequestFormLimits.maxMappingBytes - "{\"x\":\"\"}".utf8.count
            try await self.putMapping(app, a, "{\"x\":\"" + String(repeating: "a", count: fill) + "\"}")   // exactly 64 KB
            try await self.putMapping(app, a, mapping)
            let replaced = try self.object(await self.putForm(app, a))
            try await self.eq((replaced["mapping"] as? [String: Any])?["version"] as? Int, 1)
            let reread = try self.object(await self.formRequest(app, a, .GET, ""))
            try await self.eq((reread["mapping"] as? [String: Any])?["version"] as? Int, 1)

            // Account isolation: b sees nothing of a's template and cannot touch it.
            try await self.eq(try self.object(await self.formRequest(app, b, .GET, ""))["exists"] as? Bool, false)
            try await self.formRequest(app, b, .GET, "/file", .notFound)
            try await self.putMapping(app, b, mapping, .conflict)
            try await self.formRequest(app, b, .DELETE, "", .noContent)
            try await self.eq(try self.object(await self.formRequest(app, a, .GET, ""))["exists"] as? Bool, true)
            let other = Data("%PDF-1.4\nother".utf8)
            try await self.putForm(app, b, other)
            let dla = try await self.formRequest(app, a, .GET, "/file"); XCTAssertEqual(Data(dla.body.readableBytesView), AuthTests.formPDF)
            let dlb = try await self.formRequest(app, b, .GET, "/file"); XCTAssertEqual(Data(dlb.body.readableBytesView), other)
            // The generic file endpoint stays account-bound for the template file as well.
            let aFile = try await StoredFileRecord.query(on: app.db).filter(\.$accountId == aId).first()
            try await self.download(app, b, try XCTUnwrap(aFile?.id).uuidString, .notFound)
            try await self.eq(try await stored(), 2)

            // Export: mapping entry plus the PDF itself.
            let export = try await self.api(app, a, .GET, "me/export")
            let files = try self.entries(Data(export.body.readableBytesView))
            let form = try XCTUnwrap(files["vacation-request-form.json"])
            let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: form) as? [String: Any])
            try await self.eq(exported["fileName"] as? String, "Urlaubsantrag Jürgen.pdf")
            try await self.eq((exported["mapping"] as? [String: Any])?["version"] as? Int, 1)
            let pdfPath = try XCTUnwrap(files.keys.first { $0.hasPrefix("files/") })
            XCTAssertEqual(files[pdfPath], AuthTests.formPDF)
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(files["manifest.json"])) as? [String: Any])
            try await self.eq(((manifest["counts"] as? [String: Any])?["vacation-request-form"]) as? Int, 1)
            let exportB = try self.entries(Data(try await self.api(app, b, .GET, "me/export").body.readableBytesView))   // b has its own template only
            XCTAssertNotNil(exportB["vacation-request-form.json"])
            XCTAssertFalse(exportB.values.contains(AuthTests.formPDF))

            // Delete removes row, file and object; second delete is still 204.
            try await self.formRequest(app, a, .DELETE, "", .noContent)
            try await self.formRequest(app, a, .DELETE, "", .noContent)
            try await self.eq(try self.object(await self.formRequest(app, a, .GET, ""))["exists"] as? Bool, false)
            try await self.eq(try await VacationRequestFormRecord.query(on: app.db).filter(\.$accountId == aId).count(), 0)
            try await self.eq(try await StoredFileRecord.query(on: app.db).filter(\.$accountId == aId).count(), 0)
            try await self.eq(try await stored(), 1)

            // Account deletion removes row, file and object of the deleting account only.
            try await self.putForm(app, a)
            try await self.putMapping(app, a, mapping)
            try await self.eq(try await stored(), 2)
            try await self.del(app, a, "me", confirm: "alpha")
            try await self.eq(try await VacationRequestFormRecord.query(on: app.db).filter(\.$accountId == aId).count(), 0)
            try await self.eq(try await StoredFileRecord.query(on: app.db).filter(\.$accountId == aId).count(), 0)
            try await self.eq(try await stored(), 1)
            try await self.eq(try self.object(await self.formRequest(app, b, .GET, ""))["exists"] as? Bool, true)
        }
    }

    /// Module gating follows the other /vacation routes (module `planning`).
    func scenarioRequestFormModule(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        try await putForm(app, admin)
        try await api(app, admin, .PUT, "admin/modules", ["modules": ["planning": false]])
        try await formRequest(app, admin, .GET, "", .notFound)
        try await putForm(app, admin, AuthTests.formPDF, name: "a.pdf", type: "application/pdf", .notFound)
        try await formRequest(app, admin, .GET, "/file", .notFound)
    }

    func testRequestFormSQLite() async throws {
        try await withApp(scenarioRequestForm(local: false))
        try await withApp(scenarioRequestForm(local: true))
    }

    func testRequestFormModuleSQLite() async throws { try await withApp(scenarioRequestFormModule) }

    func testRequestFormMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"]
        try await withApp(environment: environment, scenarioRequestForm(local: false))
        try await withApp(environment: environment, scenarioRequestFormModule)
    }
}
