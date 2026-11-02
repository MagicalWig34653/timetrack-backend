import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// SEC-C: storage quota (SEC-06), export re-authentication and rate limit (SEC-07), anonymous counters (SEC-11).

extension AuthTests {
    func scenarioStorageQuota(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, admin)
        app.storageEnvironment.secretKey = { nil }

        // Defaults are visible and a custom quota is validated.
        let defaults = try object(await api(app, admin, .GET, "admin/storage"))
        try await eq(defaults["quotaBytes"] as? Int, 200 * 1024 * 1024); try await eq(defaults["quotaFiles"] as? Int, 500)
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "quotaFiles": -1], .badRequest)
        let saved = try object(await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "quotaFiles": 2, "quotaBytes": 1000000]))
        try await eq(saved["quotaFiles"] as? Int, 2)

        // File count: the third file is refused with a German message; other accounts are not affected.
        let first = try await fileUpload(app, member, "a.txt", Self.txt)
        try await fileUpload(app, member, "b.txt", Self.txt)
        let refused = try await fileUpload(app, member, "c.txt", Self.txt, .payloadTooLarge)
        try await eq(try errorCode(refused), "storage_quota_exceeded")
        XCTAssertTrue(refused.body.string.contains("Speicherkontingent"))
        try await fileUpload(app, admin, "admin.txt", Self.txt)

        // Deleting frees quota again.
        _ = try await app.testable().sendRequest(.DELETE, "/api/v1/files/" + (try fileID(first)), headers: headers(member))
        try await fileUpload(app, member, "c.txt", Self.txt)

        // Byte quota: 320 bytes cannot hold the 309-byte PDF next to the 28-byte text file.
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "quotaFiles": 0, "quotaBytes": 320])
        try await fileUpload(app, admin, "x.pdf", Self.pdf, .payloadTooLarge)
        // 0 disables the limits.
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "quotaFiles": 0, "quotaBytes": 0])
        try await fileUpload(app, admin, "x.pdf", Self.pdf)
    }

    func scenarioUploadRateLimit(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        app.storageEnvironment.secretKey = { nil }
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "quotaFiles": 0, "quotaBytes": 0])
        for index in 0..<StorageLimits.uploadRateLimit { try await fileUpload(app, admin, "f\(index).txt", Self.txt) }
        try await fileUpload(app, admin, "late.txt", Self.txt, .tooManyRequests)
    }

    func testStorageQuotaSQLite() async throws {
        try await withApp { app, auth in try await self.scenarioStorageQuota(app, auth) }
        try await withApp { app, auth in try await self.scenarioUploadRateLimit(app, auth) }
    }

    func testStorageQuotaMigrationIsRepeatable() async throws {
        try await withApp { app, _ in
            // Running the migration again (columns already present) and dropping nothing must not fail.
            try await AddStorageQuota().prepare(on: app.db)
            let exists = await columnExists(app.db, table: "storage_settings", column: "quota_bytes")
            XCTAssertTrue(exists)
        }
    }

    func testExportRequiresFreshSessionAndIsRateLimited() async throws {
        try await withApp { app, auth in
            let (member, _) = try await self.registered(auth, db: app.db)
            // A session older than ten minutes needs a new sign-in.
            try await self.stale(member, on: app.db)
            let denied = try await self.api(app, member, .GET, "me/export", nil, .forbidden)
            try await self.eq(try self.errorCode(denied), "reauth_required")
            try await self.eq(try await AccountAuditRecord.query(on: app.db).filter(\.$action == "account.exported").count(), 0)

            let fresh = try await self.freshSession(app, auth, "admin")
            for _ in 0..<AccountExportLimits.perWindow { try await self.api(app, fresh, .GET, "me/export") }
            let limited = try await self.api(app, fresh, .GET, "me/export", nil, .tooManyRequests)
            try await self.eq(try self.errorCode(limited), "export_rate_limited")
            // Older exports leave the window.
            try await AccountAuditRecord.query(on: app.db).set(\.$occurredAt, to: Date().addingTimeInterval(-3700)).update()
            try await self.api(app, fresh, .GET, "me/export")
        }
    }
}
