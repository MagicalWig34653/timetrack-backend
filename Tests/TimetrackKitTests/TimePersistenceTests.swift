import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

extension AuthTests {
    func timeUnwrap<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }
    func testSQLiteTimeConstraintsAndMultipleConnections() async throws {
        let path = "/tmp/c6-time-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await exerciseTimePersistence(environment: ["SQLITE_PATH": path])
    }
    func testMariaDBTimeConstraintsRESTAndMultipleConnections() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        try await exerciseTimePersistence(environment: ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"])
    }
    func exerciseTimePersistence(environment: [String: String]) async throws {
        try await withApp(environment: environment) { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody(), status: .created)
            let connections = (0..<4).map { _ in app.databases.database(logger: app.logger, on: app.eventLoopGroup.next())! }
            let outcomes = await withTaskGroup(of: String.self) { group in
                for i in 0..<16 {
                    group.addTask {
                        do {
                            _ = try await TimeServices.session(context, auth: auth, db: connections[i % 4]) {
                                try await $0.timer.act(.init(clientEventId: UUID()), action: "start")
                            }
                            return "started"
                        } catch let error as APIError { return error.code }
                        catch { return String(describing: type(of: error)) }
                    }
                }
                var results: [String] = []; for await result in group { results.append(result) }; return results
            }
            XCTAssertEqual(outcomes.filter { $0 == "started" }.count, 1)
            XCTAssertEqual(outcomes.filter { $0 == "timer_already_running" }.count, 15, outcomes.description)
            let running = try timeUnwrap(try await SegmentRecord.query(on: app.db).filter(\.$running == 1).first())
            // Bypass the service to prove the database rejects a second active row.
            let duplicate = SegmentRecord(); duplicate.accountId = try context.account.requireID()
            duplicate.rawStartedAt = Date(); duplicate.startedAt = Date(); duplicate.kind = "work"; duplicate.source = "timer"
            duplicate.version = 1; duplicate.needsReview = false; duplicate.revisions = 0; duplicate.running = 1
            do { try await duplicate.create(on: app.db); XCTFail("Expected running uniqueness constraint") } catch {}
            duplicate.id = UUID(); duplicate.running = nil
            do { try await duplicate.create(on: app.db); XCTFail("Expected running marker check") } catch {}
            let count = try await SegmentRecord.query(on: app.db).filter(\.$running == 1).count(); XCTAssertEqual(count, 1)
            try await timeRequest(app, context, .POST, "time/timer/stop", ["clientEventId": UUID().uuidString])
            let stored = try timeUnwrap(try await SegmentRecord.find(running.id, on: app.db))
            XCTAssertNil(stored.rawEndedAt); XCTAssertEqual(stored.rawStartedAt, running.rawStartedAt)
            let opening = AdjustmentRecord(); opening.accountId = try context.account.requireID(); opening.kind = "opening"
            opening.date = "2026-10-01"; opening.seconds = 100; opening.reason = "Opening"; opening.opening = 1
            try await opening.create(on: app.db)
            let secondOpening = AdjustmentRecord(); secondOpening.accountId = opening.accountId; secondOpening.kind = opening.kind
            secondOpening.date = opening.date; secondOpening.seconds = opening.seconds; secondOpening.reason = opening.reason; secondOpening.opening = 1
            do { try await secondOpening.create(on: app.db); XCTFail("Expected opening uniqueness constraint") } catch {}
            let event = TimerEventRecord(); event.accountId = try context.account.requireID(); event.clientEventId = UUID(); event.action = "start"; event.result = try stored.dto()
            try await event.create(on: app.db)
            let secondEvent = TimerEventRecord(); secondEvent.accountId = event.accountId; secondEvent.clientEventId = event.clientEventId
            secondEvent.action = event.action; secondEvent.result = event.result
            do { try await secondEvent.create(on: app.db); XCTFail("Expected timer event uniqueness constraint") } catch {}
            let placeId = try resourceID(await timeRequest(app, context, .POST, "places", placeBody(), status: .created))
            let token = try object(await timeRequest(app, context, .POST, "me/device-tokens", ["name": "Database test"], status: .created))
            let bearer: HTTPHeaders = ["Authorization": "Bearer " + (try XCTUnwrap(token["token"] as? String))]
            let body = automationBody(placeId, "arrival", "2026-10-12T08:00:00Z")
            try await timeRequest(app, nil, .POST, "automation/events", body, extra: bearer)
            try await timeRequest(app, nil, .POST, "automation/events", body, extra: bearer)
            let events = try await AutomationEventRecord.query(on: app.db).count(); XCTAssertEqual(events, 1)
            let row = try timeUnwrap(try await AutomationEventRecord.query(on: app.db).first())
            let secondAutomation = AutomationEventRecord(); secondAutomation.accountId = row.accountId; secondAutomation.eventId = row.eventId
            secondAutomation.deviceId = row.deviceId; secondAutomation.placeId = row.placeId; secondAutomation.type = row.type
            secondAutomation.sequence = row.sequence; secondAutomation.occurredAt = row.occurredAt; secondAutomation.payload = row.payload; secondAutomation.result = row.result
            do { try await secondAutomation.create(on: app.db); XCTFail("Expected automation event uniqueness constraint") } catch {}
            let day = try object(await timeRequest(app, context, .GET, "time/days/2026-10-12"))
            XCTAssertEqual(day["targetSeconds"] as? Int, 27720)
        }
    }
    func testTimeModelGapsNullableUpdatesAndFractionalInstants() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let empty = try object(await timeRequest(app, context, .GET, "time/days/2026-10-12"))
            XCTAssertTrue(empty["modelId"] is NSNull); XCTAssertEqual(empty["targetSeconds"] as? Int, 0)
            let segment = try await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-12T08:00:00.125Z", "2026-10-12T09:00:00.125Z"), status: .created)
            XCTAssertEqual(try object(segment)["rawStartedAt"] as? String, "2026-10-12T08:00:00.125Z")
            let day = try object(await timeRequest(app, context, .GET, "time/days/2026-10-12"))
            XCTAssertEqual(day["evaluatedWorkSeconds"] as? Int, 3600)
            try await timeRequest(app, context, .PUT, "time/days/2026-10-12", ["mark": "school_credit", "creditSeconds": 7200, "note": "Saved"])
            let preserved = try object(await timeRequest(app, context, .PUT, "time/days/2026-10-12", ["skipFixedBreaks": true]))
            XCTAssertEqual(preserved["markCreditSeconds"] as? Int, 7200); XCTAssertEqual(preserved["note"] as? String, "Saved")
            let cleared = try object(await timeRequest(app, context, .PUT, "time/days/2026-10-12", ["creditSeconds": NSNull(), "note": NSNull()]))
            XCTAssertTrue(cleared["markCreditSeconds"] is NSNull); XCTAssertTrue(cleared["note"] is NSNull)
        }
    }
}
