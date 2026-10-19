import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// B6: Absence.attachmentCount, GET /absences?hasAttachment=, GET /files/{id}?disposition=inline.
// The two scenarios run from the storage scenario list (SQLite and, gated, MariaDB).

extension AuthTests {
    func absenceJSON(_ app: Application, _ context: AuthContext, _ id: String) async throws -> [String: Any] {
        try object(await api(app, context, .GET, "absences/\(id)"))
    }

    func absenceId(_ created: [String: Any]) throws -> String { try XCTUnwrap(created["id"] as? String) }

    func scenarioAttachmentCount(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, admin)
        let a1 = try await absenceId(createAbsence(app, admin, absenceBody("2026-10-12", "2026-10-13", kind: "sick", status: "taken")))
        let a2 = try await absenceId(createAbsence(app, admin, absenceBody("2026-10-20", kind: "sick", status: "taken")))
        let a3 = try await absenceId(createAbsence(app, admin, absenceBody("2026-10-27", kind: "sick", status: "taken")))
        let m1 = try await absenceId(createAbsence(app, member, absenceBody("2026-10-12", kind: "sick", status: "taken")))

        // The create response always carries the field.
        let created = try object(await api(app, admin, .POST, "absences", absenceBody("2026-11-03", kind: "sick", status: "taken"), .created))
        try await eq(created["attachmentCount"] as? Int, 0)

        let f1 = try fileID(await fileUpload(app, admin, "a.txt", Data("a\n".utf8)))
        let f2 = try fileID(await fileUpload(app, admin, "b.txt", Data("b\n".utf8)))
        let foreign = try fileID(await fileUpload(app, member, "m.txt", Data("m\n".utf8)))
        try await api(app, admin, .POST, "absences/\(a1)/attachments", ["fileId": f1], .created)
        try await api(app, admin, .POST, "absences/\(a1)/attachments", ["fileId": f1], .created)   // idempotent link
        try await api(app, admin, .POST, "absences/\(a1)/attachments", ["fileId": f2], .created)
        try await api(app, admin, .POST, "absences/\(a2)/attachments", ["fileId": f1], .created)   // same file, other absence
        try await api(app, member, .POST, "absences/\(m1)/attachments", ["fileId": foreign], .created)

        let range = "from=2026-10-01&to=2026-12-31"
        func counts(_ context: AuthContext, _ query: String = "") async throws -> [String: Int] {
            var result: [String: Int] = [:]
            for row in try list(await api(app, context, .GET, "absences?\(range)\(query)")) {
                result[try XCTUnwrap(row["id"] as? String)] = try XCTUnwrap(row["attachmentCount"] as? Int)
            }
            return result
        }
        try await eq(await counts(admin)[a1], 2); try await eq(await counts(admin)[a2], 1); try await eq(await counts(admin)[a3], 0)
        try await eq(await absenceJSON(app, admin, a1)["attachmentCount"] as? Int, 2)
        try await eq(await absenceJSON(app, admin, a3)["attachmentCount"] as? Int, 0)
        // Isolation: a member only sees counts of their own links and cannot read the admin's absences.
        try await eq(await counts(member), [m1: 1])
        try await api(app, member, .GET, "absences/\(a1)", nil, .notFound)

        // Update (If-Match) returns the current count.
        let updated = try object(await api(app, admin, .PUT, "absences/\(a1)", absenceBody("2026-10-12", "2026-10-13", kind: "sick", status: "taken"), version: 1))
        try await eq(updated["attachmentCount"] as? Int, 2)

        // Filter.
        let with = try await counts(admin, "&hasAttachment=true")
        try await eq(Set(with.keys), Set([a1, a2]))
        let without = try await counts(admin, "&hasAttachment=false")
        XCTAssertFalse(without.keys.contains(a1)); XCTAssertEqual(without[a3], 0)
        for bad in ["yes", "1", "TRUE", "", "true,false"] {
            let response = try await api(app, admin, .GET, "absences?\(range)&hasAttachment=\(bad)", nil, .badRequest)
            try await eq(errorCode(response), "bad_request")
        }

        // Detach lowers the count; deleting the file removes all links (voided attachments never count).
        try await api(app, admin, .DELETE, "absences/\(a1)/attachments/\(f2)", nil, .noContent)
        try await eq(await counts(admin)[a1], 1)
        try await api(app, admin, .DELETE, "files/" + f1, nil, .noContent)
        try await eq(await counts(admin)[a1], 0); try await eq(await counts(admin)[a2], 0)
        try await eq(Set(try await counts(admin, "&hasAttachment=true").keys), [])
        // A link to a file that is not stored (deleting/failed) does not count, even if the link row still exists.
        let f3 = try fileID(await fileUpload(app, admin, "c.txt", Data("c\n".utf8)))
        try await api(app, admin, .POST, "absences/\(a3)/attachments", ["fileId": f3], .created)
        try await eq(await counts(admin)[a3], 1)
        try await StoredFileRecord.query(on: app.db).filter(\.$id == UUID(uuidString: f3)!).set(\.$state, to: FileState.deleting.rawValue).update()
        try await eq(await counts(admin)[a3], 0)
        try await eq(await absenceJSON(app, admin, a3)["attachmentCount"] as? Int, 0)
        // The member's count is unaffected by all of this.
        try await eq(await counts(member), [m1: 1])
    }

    func scenarioInlineDownload(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, admin)
        let txt = try fileID(await fileUpload(app, admin, "Notiz.txt", AuthTests.txt))
        let pdf = try fileID(await fileUpload(app, admin, "Bescheid.pdf", AuthTests.pdf))
        let png = try fileID(await fileUpload(app, admin, "Foto.png", AuthTests.png))

        // Default stays attachment, no CSP needed.
        let plain = try await download(app, admin, txt)
        XCTAssertTrue(try XCTUnwrap(plain.headers.first(name: .contentDisposition)).hasPrefix("attachment;"))
        XCTAssertNil(plain.headers.first(name: "Content-Security-Policy"))

        for (id, type, name) in [(txt, "text/plain", "Notiz.txt"), (pdf, "application/pdf", "Bescheid.pdf"), (png, "image/png", "Foto.png")] {
            let response = try await app.testable().sendRequest(.GET, "/api/v1/files/\(id)?disposition=inline", headers: headers(admin))
            XCTAssertEqual(response.status, .ok)
            XCTAssertTrue(try XCTUnwrap(response.headers.first(name: .contentType)).hasPrefix(type))
            let disposition = try XCTUnwrap(response.headers.first(name: .contentDisposition))
            XCTAssertTrue(disposition.hasPrefix("inline;"), disposition)
            XCTAssertTrue(disposition.contains("filename=\"\(name)\""), disposition)
            XCTAssertEqual(response.headers.first(name: "X-Content-Type-Options"), "nosniff")
            let csp = try XCTUnwrap(response.headers.first(name: "Content-Security-Policy"))
            XCTAssertTrue(csp.hasPrefix("sandbox") && csp.contains("default-src 'none'"), csp)
            XCTAssertTrue(try XCTUnwrap(response.headers.first(name: .cacheControl)).contains("no-store"))
        }
        // Unknown or odd values fall back to attachment.
        for value in ["attachment", "Inline", "bogus", ""] {
            let response = try await app.testable().sendRequest(.GET, "/api/v1/files/\(txt)?disposition=\(value)", headers: headers(admin))
            XCTAssertEqual(response.status, .ok)
            XCTAssertTrue(try XCTUnwrap(response.headers.first(name: .contentDisposition)).hasPrefix("attachment;"), value)
            XCTAssertNil(response.headers.first(name: "Content-Security-Policy"), value)
        }
        // A stored type outside the whitelist (HEIC is uploadable) is never served inline.
        let heic = Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8) + Data(repeating: 0, count: 32)
        let heicId = try fileID(await fileUpload(app, admin, "Foto.heic", heic))
        let heicResponse = try await app.testable().sendRequest(.GET, "/api/v1/files/\(heicId)?disposition=inline", headers: headers(admin))
        XCTAssertEqual(heicResponse.status, .ok)
        XCTAssertTrue(try XCTUnwrap(heicResponse.headers.first(name: .contentDisposition)).hasPrefix("attachment;"))
        XCTAssertNil(heicResponse.headers.first(name: "Content-Security-Policy"))
        // Whitelist unit check: scriptable and unknown types are out, parameters are ignored, case-insensitive.
        for type in ["text/html", "image/svg+xml", "application/xhtml+xml", "application/javascript", "text/xml", "application/octet-stream", "image/heic", ""] {
            XCTAssertFalse(FilenameSanitizer.isInlineSafe(type), type)
        }
        for type in ["image/png", "image/jpeg", "image/gif", "image/webp", "application/pdf", "text/plain", "text/plain; charset=utf-8", "IMAGE/PNG"] {
            XCTAssertTrue(FilenameSanitizer.isInlineSafe(type), type)
        }
        // Account isolation is the same as for the normal download, also with the inline option.
        for query in ["", "?disposition=inline"] {
            let foreign = try await app.testable().sendRequest(.GET, "/api/v1/files/\(txt)\(query)", headers: headers(member))
            XCTAssertEqual(foreign.status, .notFound, query)
            XCTAssertNil(foreign.headers.first(name: "Content-Security-Policy"))
        }
        let anonymous = try await app.testable().sendRequest(.GET, "/api/v1/files/\(txt)?disposition=inline")
        XCTAssertEqual(anonymous.status, .unauthorized)
    }

    func testAbsenceListQueryCountIndependentOfAbsenceCount() async throws {
        try await withApp { app, auth in
            let (admin, _) = try await registered(auth, db: app.db)
            let file = try fileID(await fileUpload(app, admin, "a.txt", AuthTests.txt))
            let log = RequestQueryLog()
            app.middleware.use(RequestQueryLogMiddleware(log: log), at: .beginning)
            func listQueries() async throws -> Int {
                log.reset()
                let response = try await app.testable().sendRequest(.GET, "/api/v1/absences?from=2026-01-01&to=2026-12-31", headers: headers(admin))
                XCTAssertEqual(response.status, .ok)
                return log.all.count
            }
            var ids: [String] = []
            for day in 1...2 {
                let row = try await createAbsence(app, admin, absenceBody(String(format: "2026-03-%02d", day), kind: "sick", status: "taken"))
                ids.append(try XCTUnwrap(row["id"] as? String))
            }
            try await api(app, admin, .POST, "absences/\(ids[0])/attachments", ["fileId": file], .created)
            let few = try await listQueries()
            for day in 3...12 {
                let row = try await createAbsence(app, admin, absenceBody(String(format: "2026-04-%02d", day), kind: "sick", status: "taken"))
                let id = try XCTUnwrap(row["id"] as? String)
                try await api(app, admin, .POST, "absences/\(id)/attachments", ["fileId": file], .created)
            }
            let many = try await listQueries()
            print("B6-QUERIES list absences: 2 absences fluentQueries=\(few), 12 absences fluentQueries=\(many)")
            XCTAssertEqual(few, many)
        }
    }
}
