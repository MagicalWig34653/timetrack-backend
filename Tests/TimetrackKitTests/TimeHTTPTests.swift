import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

extension AuthTests {
    @discardableResult
    func timeRequest(_ app: Application, _ context: AuthContext?, _ method: HTTPMethod, _ path: String,
                     _ body: [String: Any]? = nil, status: HTTPStatus = .ok, extra: HTTPHeaders = [:],
                     file: StaticString = #filePath, line: UInt = #line) async throws -> XCTHTTPResponse {
        var head = context.map { headers($0) } ?? [:]
        for (name, value) in extra { head.replaceOrAdd(name: name, value: value) }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        if data != nil { head.contentType = .json }
        let response = try await app.testable().sendRequest(method, "/api/v1/" + path, headers: head, body: data.map(ByteBuffer.init(data:)))
        XCTAssertEqual(response.status, status, response.body.string, file: file, line: line)
        return response
    }
    func object(_ response: XCTHTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
    }
    func resourceID(_ response: XCTHTTPResponse) throws -> String { try XCTUnwrap(object(response)["id"] as? String) }
    func modelBody(_ start: String = "2026-10-01") -> [String: Any] {
        ["validFrom": start, "weeklyTargetSeconds": 138600, "workdays": [1, 2, 3, 4, 5]]
    }
    func placeBody(_ mode: String = "direct") -> [String: Any] {
        ["name": "Office", "kind": "office", "automationMode": mode, "confirmAfterSeconds": 300]
    }
    func segmentBody(_ start: String, _ end: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["kind": "work", "startedAt": start]
        if let end { body["endedAt"] = end }; return body
    }
    func testTimeRESTModelsPlacesSegmentsDaysAndAccount() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let model = try await timeRequest(app, context, .POST, "work-models", modelBody(), status: .created)
            let modelId = try resourceID(model)
            try await timeRequest(app, context, .GET, "work-models")
            try await timeRequest(app, context, .GET, "work-models/" + modelId)
            let place = try await timeRequest(app, context, .POST, "places", placeBody(), status: .created)
            let placeId = try resourceID(place)
            try await timeRequest(app, context, .PUT, "places/" + placeId, placeBody("suggest"))
            try await timeRequest(app, context, .GET, "places")
            var first = segmentBody("2026-10-12T06:07:00Z", "2026-10-12T10:00:00Z"); first["placeId"] = placeId
            let segment = try await timeRequest(app, context, .POST, "time/segments", first, status: .created)
            let segmentId = try resourceID(segment)
            try await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-12T11:00:00Z", "2026-10-12T14:02:00Z"), status: .created)
            let day = try object(await timeRequest(app, context, .GET, "time/days/2026-10-12"))
            XCTAssertEqual(day["rawWorkSeconds"] as? Int, 24900); XCTAssertEqual(day["evaluatedWorkSeconds"] as? Int, 26100)
            XCTAssertEqual((day["segments"] as? [Any])?.count, 2)
            try await timeRequest(app, context, .GET, "time/segments?from=2026-10-12T00:00:00Z&to=2026-10-13T00:00:00Z")
            try await timeRequest(app, context, .GET, "time/segments/" + segmentId)
            let days = try await timeRequest(app, context, .GET, "time/days?from=2026-10-12&to=2026-10-14")
            XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(days.body.readableBytesView)) as? [Any])?.count, 3)
            try await timeRequest(app, context, .GET, "time/days?from=2026-01-01&to=2026-10-14", status: .badRequest)
            let preference = try object(await timeRequest(app, context, .PUT, "time/days/2026-10-13", ["mark": "holiday", "creditSeconds": 3600, "skipFixedBreaks": true, "note": "Holiday"]))
            XCTAssertEqual(preference["targetSeconds"] as? Int, 0); XCTAssertEqual(preference["markCreditSeconds"] as? Int, 3600)
            XCTAssertEqual(preference["note"] as? String, "Holiday")
            try await timeRequest(app, context, .POST, "time/account/adjustments", ["kind": "opening", "date": "2026-10-12", "seconds": 1000, "reason": "Opening"], status: .created)
            try await timeRequest(app, context, .POST, "time/account/adjustments", ["kind": "correction", "date": "2026-10-12", "seconds": 200, "reason": "Correction"], status: .created)
            let balance = try object(await timeRequest(app, context, .GET, "time/account?asOf=2026-10-12"))
            XCTAssertEqual(balance["balanceSeconds"] as? Int, -420)
            try await timeRequest(app, context, .POST, "time/account/adjustments", ["kind": "opening", "date": "2026-10-12", "seconds": 0, "reason": "Duplicate"], status: .conflict)
            try await timeRequest(app, context, .DELETE, "places/" + placeId, status: .noContent)
            try await timeRequest(app, context, .GET, "time/segments/" + segmentId)
            try await timeRequest(app, context, .PATCH, "work-models/" + modelId, ["validTo": "2026-10-31"])
        }
    }

    func testLegalProfileSelectionAndSchoolLessons() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let catalogue = try await timeRequest(app, context, .GET, "legal-profiles")
            let profiles = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(catalogue.body.readableBytesView)) as? [[String: Any]])
            XCTAssertEqual(Set(profiles.compactMap { $0["id"] as? String }), ["arbzg-adult-de", "jarbschg-minor-de"])
            let adult = try object(await timeRequest(app, context, .POST, "work-models", modelBody("2026-10-01"), status: .created))
            XCTAssertEqual(adult["legalProfileId"] as? String, "arbzg-adult-de")
            var minor = modelBody("2026-10-12")
            minor["legalProfileId"] = "jarbschg-minor-de"
            let selected = try object(await timeRequest(app, context, .POST, "work-models", minor, status: .created))
            XCTAssertEqual(selected["legalProfileId"] as? String, "jarbschg-minor-de")
            try await timeRequest(app, context, .POST, "time/segments", [
                "kind": "school", "startedAt": "2026-10-12T06:00:00Z", "endedAt": "2026-10-12T11:00:00Z"
            ], status: .created)
            let day = try object(await timeRequest(app, context, .PUT, "time/days/2026-10-12", ["schoolLessonCount": 6]))
            XCTAssertEqual(day["creditSeconds"] as? Int, 28_800)
            XCTAssertEqual(day["legalProfileId"] as? String, "jarbschg-minor-de")
            XCTAssertEqual(day["schoolLessonCount"] as? Int, 6)
            let previous = try object(await timeRequest(app, context, .GET, "time/days/2026-10-11"))
            XCTAssertEqual(previous["legalProfileId"] as? String, "arbzg-adult-de")
        }
    }
    func testTimeCorrectionOverlapAndVoiding() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let first = try await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-12T06:07:00Z", "2026-10-12T10:00:00Z"), status: .created)
            let id = try resourceID(first)
            let overlap = try object(await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-12T07:00:00Z", "2026-10-12T11:00:00Z"), status: .conflict))
            XCTAssertEqual((overlap["error"] as? [String: String])?["code"], "segment_overlap")
            let corrected = try object(await timeRequest(app, context, .PATCH, "time/segments/" + id, ["startedAt": "2026-10-12T06:00:00Z", "reason": "Clock correction"], extra: ["If-Match": "1"]))
            XCTAssertEqual(corrected["version"] as? Int, 2); XCTAssertEqual(corrected["revisions"] as? Int, 1)
            XCTAssertEqual(corrected["rawStartedAt"] as? String, "2026-10-12T06:07:00Z")
            let stale = try object(await timeRequest(app, context, .PATCH, "time/segments/" + id, ["reason": "Stale"], status: .preconditionFailed, extra: ["If-Match": "1"]))
            XCTAssertEqual((stale["error"] as? [String: String])?["code"], "stale_version")
            try await timeRequest(app, context, .DELETE, "time/segments/" + id + "?reason=Duplicate", status: .noContent)
            let voided = try object(await timeRequest(app, context, .GET, "time/segments/" + id))
            XCTAssertEqual(voided["voided"] as? Bool, true)
            let revisions = try await RevisionRecord.query(on: app.db).all()
            XCTAssertEqual(revisions.count, 2); XCTAssertFalse(revisions[0].before.voided)
            try await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-12T07:00:00Z", "2026-10-12T11:00:00Z"), status: .created)
        }
    }
    func testReopenFinishedSegmentWithGuards() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let (other, _) = try await registered(auth, db: app.db, handle: "second", admin: context)
            let first = try await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-12T06:00:00Z", "2026-10-12T10:00:00Z"), status: .created)
            let firstId = try resourceID(first)
            let second = try await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-12T11:00:00Z", "2026-10-12T12:00:00Z"), status: .created)
            let secondId = try resourceID(second)
            // A later segment exists: the first one cannot be reopened.
            let later = try object(await timeRequest(app, context, .PATCH, "time/segments/" + firstId, ["endedAt": NSNull(), "reason": "Continue"], status: .conflict, extra: ["If-Match": "1"]))
            XCTAssertEqual((later["error"] as? [String: String])?["code"], "segment_overlap")
            // Another account cannot reopen it.
            try await timeRequest(app, other, .PATCH, "time/segments/" + secondId, ["endedAt": NSNull(), "reason": "Continue"], status: .notFound, extra: ["If-Match": "1"])
            // Absent endedAt does not reopen.
            let untouched = try object(await timeRequest(app, context, .PATCH, "time/segments/" + secondId, ["note": "n", "reason": "Note"], extra: ["If-Match": "1"]))
            XCTAssertFalse(untouched["endedAt"] is NSNull)
            // The latest segment can be reopened; raw capture and source/kind/note stay.
            let reopened = try object(await timeRequest(app, context, .PATCH, "time/segments/" + secondId, ["endedAt": NSNull(), "reason": "Continue"], extra: ["If-Match": "2"]))
            XCTAssertTrue(reopened["endedAt"] is NSNull); XCTAssertEqual(reopened["rawEndedAt"] as? String, "2026-10-12T12:00:00Z")
            XCTAssertEqual(reopened["note"] as? String, "n"); XCTAssertEqual(reopened["source"] as? String, "manual"); XCTAssertEqual(reopened["kind"] as? String, "work")
            XCTAssertEqual(reopened["version"] as? Int, 3)
            let timer = try object(await timeRequest(app, context, .GET, "time/timer"))
            XCTAssertEqual(timer["id"] as? String, secondId)
            let revisions = try await RevisionRecord.query(on: app.db).filter(\.$segmentId == UUID(uuidString: secondId)!).sort(\.$createdAt).all()
            XCTAssertEqual(revisions.last?.reason, "Reopened: Continue")
            XCTAssertNotNil(revisions.last?.before.endedAt); XCTAssertNil(revisions.last?.after.endedAt)
            // A running segment blocks reopening another one (and a second timer).
            let blocked = try object(await timeRequest(app, context, .PATCH, "time/segments/" + firstId, ["endedAt": NSNull(), "reason": "Continue"], status: .conflict, extra: ["If-Match": "1"]))
            XCTAssertNotNil(blocked["error"])
            try await timeRequest(app, context, .POST, "time/timer/stop", ["clientEventId": UUID().uuidString])
            // Voiding the later segment frees the earlier one; with a running timer the code is timer_already_running.
            try await timeRequest(app, context, .DELETE, "time/segments/" + secondId + "?reason=Mistake", status: .noContent)
            let running = try await timeRequest(app, context, .POST, "time/timer/start", ["clientEventId": UUID().uuidString])
            let runningConflict = try object(await timeRequest(app, context, .PATCH, "time/segments/" + firstId, ["endedAt": NSNull(), "reason": "Continue"], status: .conflict, extra: ["If-Match": "1"]))
            XCTAssertEqual((runningConflict["error"] as? [String: String])?["code"], "timer_already_running")
            _ = running
        }
    }
    func testTimeTimerIdempotencyAndConcurrency() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let empty = try await timeRequest(app, context, .GET, "time/timer")
            XCTAssertEqual(empty.body.string, "null")
            let event = UUID().uuidString
            let first = try await timeRequest(app, context, .POST, "time/timer/start", ["clientEventId": event])
            let second = try await timeRequest(app, context, .POST, "time/timer/start", ["clientEventId": event])
            XCTAssertEqual(try resourceID(first), try resourceID(second))
            try await timeRequest(app, context, .POST, "time/timer/start", ["clientEventId": UUID().uuidString], status: .conflict)
            let stop = UUID().uuidString
            let stopped = try await timeRequest(app, context, .POST, "time/timer/stop", ["clientEventId": stop])
            let replay = try await timeRequest(app, context, .POST, "time/timer/stop", ["clientEventId": stop])
            XCTAssertEqual(try object(stopped)["endedAt"] as? String, try object(replay)["endedAt"] as? String)
            try await timeRequest(app, context, .POST, "time/timer/stop", ["clientEventId": UUID().uuidString], status: .conflict)
            let header = headers(context)
            let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        let data = try JSONSerialization.data(withJSONObject: ["clientEventId": UUID().uuidString])
                        var head = header; head.contentType = .json
                        return try await app.testable().sendRequest(.POST, "/api/v1/time/timer/start", headers: head, body: ByteBuffer(data: data)).status
                    }
                }
                var statuses: [HTTPStatus] = []; for try await status in group { statuses.append(status) }; return statuses
            }
            XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1)
            XCTAssertEqual(statuses.filter { $0 == .conflict }.count, 7)
            let running = try await SegmentRecord.query(on: app.db).filter(\.$running == 1).count()
            XCTAssertEqual(running, 1)
        }
    }
    func testTimeHistoryAndDST() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            var model = modelBody("2026-01-01"); model["roundingEnabled"] = false
            try await timeRequest(app, context, .POST, "work-models", model, status: .created)
            try await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z"), status: .created)
            let before = try object(await timeRequest(app, context, .GET, "time/days/2026-03-29"))
            XCTAssertEqual(before["rawWorkSeconds"] as? Int, 23 * 3600)
            var next = modelBody("2026-10-01"); next["weeklyTargetSeconds"] = 100000
            try await timeRequest(app, context, .POST, "work-models", next, status: .created)
            let after = try object(await timeRequest(app, context, .GET, "time/days/2026-03-29"))
            XCTAssertEqual(before["modelId"] as? String, after["modelId"] as? String)
            XCTAssertEqual(before["evaluatedWorkSeconds"] as? Int, after["evaluatedWorkSeconds"] as? Int)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-09-01"), status: .conflict)
        }
    }
}
