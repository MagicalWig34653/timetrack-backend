import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// Package M1: correcting a work model version in place (PUT) and previewing the effect (POST .../preview).
extension AuthTests {
    private func balance(_ app: Application, _ context: AuthContext) async throws -> Int {
        let value = try object(await timeRequest(app, context, .GET, "time/account"))
        return try XCTUnwrap(value["balanceSeconds"] as? Int)
    }

    func workModelCorrectionPreviewMatchesActualChange(_ environment: [String: String]) async throws {
        try await withApp(environment: environment) { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let modelId = try resourceID(await timeRequest(app, context, .POST, "work-models", modelBody("2026-08-03"), status: .created))
            for day in ["2026-08-03", "2026-08-04", "2026-08-05"] {
                try await timeRequest(app, context, .POST, "time/segments", segmentBody("\(day)T06:00:00Z", "\(day)T14:00:00Z"), status: .created)
            }
            let before = try await balance(app, context)
            var same = modelBody("2026-08-03")
            // Identical values: preview is neutral and so is the evaluation after the correction.
            let neutral = try object(await timeRequest(app, context, .POST, "work-models/\(modelId)/preview", same))
            XCTAssertEqual(neutral["differenceSeconds"] as? Int, 0); XCTAssertEqual(neutral["changedFields"] as? [String], [])
            let kept = try object(await timeRequest(app, context, .PUT, "work-models/\(modelId)", same))
            XCTAssertEqual(kept["version"] as? Int, 2)
            let afterSame = try await balance(app, context)
            XCTAssertEqual(afterSame, before)

            same["weeklyTargetSeconds"] = 100_800   // 28 h instead of 38.5 h: 7560 s less target per workday
            let preview = try object(await timeRequest(app, context, .POST, "work-models/\(modelId)/preview", same))
            XCTAssertEqual(preview["balanceBeforeSeconds"] as? Int, before)
            XCTAssertEqual(preview["changedFields"] as? [String], ["weeklyTargetSeconds"])
            XCTAssertEqual(preview["affectedFrom"] as? String, "2026-08-03")
            XCTAssertTrue(preview["affectedTo"] is NSNull || preview["affectedTo"] == nil)
            let difference = try XCTUnwrap(preview["differenceSeconds"] as? Int)
            XCTAssertGreaterThan(difference, 0); XCTAssertEqual(difference % 7560, 0)
            // The preview does not persist.
            let unchanged = try await balance(app, context)
            XCTAssertEqual(unchanged, before)
            try await timeRequest(app, context, .PUT, "work-models/\(modelId)", same)
            let after = try await balance(app, context)
            XCTAssertEqual(after - before, difference); XCTAssertEqual(after, preview["balanceAfterSeconds"] as? Int)
            let audit = try await AccountAuditRecord.query(on: app.db).filter(\.$action == "work_model.updated").count()
            XCTAssertEqual(audit, 2)
        }
    }

    func workModelCorrectionValidationOverlapAndNeighbourAdjustment(_ environment: [String: String]) async throws {
        try await withApp(environment: environment) { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let first = try resourceID(await timeRequest(app, context, .POST, "work-models", modelBody("2026-06-01"), status: .created))
            let second = try resourceID(await timeRequest(app, context, .POST, "work-models", modelBody("2026-09-01"), status: .created))
            var invalid = modelBody("2026-09-01"); invalid["weeklyTargetSeconds"] = -1
            try await timeRequest(app, context, .PUT, "work-models/\(second)", invalid, status: .badRequest)
            try await timeRequest(app, context, .POST, "work-models/\(second)/preview", invalid, status: .badRequest)
            var reversed = modelBody("2026-09-01"); reversed["validTo"] = "2026-08-01"
            try await timeRequest(app, context, .PUT, "work-models/\(second)", reversed, status: .badRequest)
            // validFrom not after the predecessor's validFrom, open predecessor extended over successor, successor overlap.
            try await timeRequest(app, context, .PUT, "work-models/\(second)", modelBody("2026-06-01"), status: .conflict)
            try await timeRequest(app, context, .PUT, "work-models/\(first)", modelBody("2026-06-01"), status: .conflict)        // open end runs into the successor
            var overlong = modelBody("2026-06-01"); overlong["validTo"] = "2026-09-01"
            try await timeRequest(app, context, .PUT, "work-models/\(first)", overlong, status: .conflict)
            // Moving the successor's start earlier shortens the predecessor, later keeps them adjacent.
            let moved = try object(await timeRequest(app, context, .PUT, "work-models/\(second)", modelBody("2026-08-15")))
            XCTAssertEqual(moved["validFrom"] as? String, "2026-08-15")
            var predecessor = try object(await timeRequest(app, context, .GET, "work-models/\(first)"))
            XCTAssertEqual(predecessor["validTo"] as? String, "2026-08-14")
            let preview = try object(await timeRequest(app, context, .POST, "work-models/\(second)/preview", modelBody("2026-09-10")))
            XCTAssertEqual(preview["previousValidTo"] as? String, "2026-09-09")
            try await timeRequest(app, context, .PUT, "work-models/\(second)", modelBody("2026-09-10"))
            predecessor = try object(await timeRequest(app, context, .GET, "work-models/\(first)"))
            XCTAssertEqual(predecessor["validTo"] as? String, "2026-09-09")
            // A rejected correction leaves everything untouched.
            try await timeRequest(app, context, .PUT, "work-models/\(second)", modelBody("2026-05-01"), status: .conflict)
            let list = try JSONSerialization.jsonObject(with: Data(await timeRequest(app, context, .GET, "work-models").body.readableBytesView)) as? [[String: Any]]
            XCTAssertEqual(list?.map { $0["validFrom"] as? String }, ["2026-06-01", "2026-09-10"])
        }
    }

    func workModelCorrectionOptimisticVersionAndAccountIsolation(_ environment: [String: String]) async throws {
        try await withApp(environment: environment) { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let (other, _) = try await registered(auth, db: app.db, handle: "member", admin: context)
            let id = try resourceID(await timeRequest(app, context, .POST, "work-models", modelBody("2026-08-03"), status: .created))
            var body = modelBody("2026-08-03"); body["roundingEnabled"] = false
            try await timeRequest(app, context, .PUT, "work-models/\(id)", body, status: .preconditionFailed, extra: ["If-Match": "7"])
            try await timeRequest(app, context, .PUT, "work-models/\(id)", body, extra: ["If-Match": "\"1\""])
            try await timeRequest(app, context, .PUT, "work-models/\(id)", body, status: .preconditionFailed, extra: ["If-Match": "1"])
            try await timeRequest(app, context, .PUT, "work-models/\(id)", body, extra: ["If-Match": "2"])
            // Another account sees nothing and can change nothing.
            try await timeRequest(app, other, .PUT, "work-models/\(id)", body, status: .notFound)
            try await timeRequest(app, other, .POST, "work-models/\(id)/preview", body, status: .notFound)
            let stored = try object(await timeRequest(app, context, .GET, "work-models/\(id)"))
            XCTAssertEqual(stored["version"] as? Int, 3); XCTAssertEqual(stored["roundingEnabled"] as? Bool, false)
        }
    }

    private func runWorkModelCorrection(_ environment: [String: String]) async throws {
        try await workModelCorrectionPreviewMatchesActualChange(environment)
        try await workModelCorrectionValidationOverlapAndNeighbourAdjustment(environment)
        try await workModelCorrectionOptimisticVersionAndAccountIsolation(environment)
    }
    func testWorkModelCorrectionSQLite() async throws { try await runWorkModelCorrection([:]) }
    func testWorkModelCorrectionMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        try await runWorkModelCorrection(["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_m1", "DB_TLS": "off"])
    }
}
