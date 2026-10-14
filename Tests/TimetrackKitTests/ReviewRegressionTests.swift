import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

extension AuthTests {
    func testNewArrivalNeverClosesUnresolvedPreviousVisit() async throws {
        for scenario in ["confirmed", "passBy", "outOfOrder"] {
            try await withApp { app, auth in
                let (context, _) = try await registered(auth, db: app.db)
                let token = try object(await timeRequest(app, context, .POST, "me/device-tokens", ["name": "Phone"], status: .created))
                let bearer: HTTPHeaders = ["Authorization": "Bearer " + (try XCTUnwrap(token["token"] as? String))]
                let place = try resourceID(await timeRequest(app, context, .POST, "places", placeBody(), status: .created))
                try await timeRequest(app, nil, .POST, "automation/events", automationBody(place, "arrival", "2026-10-01T08:00:00Z"), extra: bearer)
                let first = try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(place, "presence_confirmed", "2026-10-01T08:05:00Z"), extra: bearer))
                let id = try XCTUnwrap(first["segmentId"] as? String)
                // Exercise an already-created end suggestion as well as the new arrival boundary.
                try await timeRequest(app, context, .GET, "time/suggestions")
                let arrival = automationBody(place, "arrival", scenario == "outOfOrder" ? "2026-10-01T08:02:00Z" : "2026-10-02T08:00:00Z")
                let second = try object(await timeRequest(app, nil, .POST, "automation/events", arrival, extra: bearer))
                XCTAssertEqual(second["result"] as? String, "needs_review", scenario)
                let replay = try object(await timeRequest(app, nil, .POST, "automation/events", arrival, extra: bearer))
                XCTAssertEqual(replay["result"] as? String, second["result"] as? String)
                if scenario != "passBy" {
                    let confirmation = try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(place, "presence_confirmed", "2026-10-02T08:05:00Z"), extra: bearer))
                    XCTAssertEqual(confirmation["result"] as? String, "needs_review")
                }
                let departure = automationBody(place, "departure", "2026-10-02T16:00:00Z")
                let end = try object(await timeRequest(app, nil, .POST, "automation/events", departure, extra: bearer))
                XCTAssertEqual(end["result"] as? String, "suggested", scenario)
                XCTAssertNotNil(end["suggestionId"] as? String)
                let duplicate = try object(await timeRequest(app, nil, .POST, "automation/events", departure, extra: bearer))
                XCTAssertEqual(duplicate["suggestionId"] as? String, end["suggestionId"] as? String)
                let segment = try object(await timeRequest(app, context, .GET, "time/segments/" + id))
                XCTAssertTrue(segment["endedAt"] is NSNull)
                XCTAssertTrue(segment["rawEndedAt"] is NSNull)
                XCTAssertEqual(segment["version"] as? Int, 1)
                let count = try await SegmentRecord.query(on: app.db).count()
                XCTAssertEqual(count, 1)
            }
        }
    }

    func testModelTransitionsConserveWorkAndAssignEachSegmentOnceThroughREST() async throws {
        let cases: [(Int, Int, String, String)] = [
            (0, 240, "Europe/Berlin", "Europe/Berlin"),
            (240, 0, "Europe/Berlin", "Europe/Berlin"),
            (0, 240, "Asia/Tokyo", "America/New_York"),
            (240, 0, "America/New_York", "Asia/Tokyo")
        ]
        for (oldBoundary, newBoundary, oldZone, newZone) in cases {
            try await withApp { app, auth in
                let (context, _) = try await registered(auth, db: app.db)
                var old = modelBody("2026-10-10")
                old["weeklyTargetSeconds"] = 0; old["roundingEnabled"] = false
                old["timezone"] = oldZone; old["dayBoundaryMinutes"] = oldBoundary
                let oldID = try resourceID(await timeRequest(app, context, .POST, "work-models", old, status: .created))
                var next = old; next["validFrom"] = "2026-10-13"
                next["timezone"] = newZone; next["dayBoundaryMinutes"] = newBoundary
                let newID = try resourceID(await timeRequest(app, context, .POST, "work-models", next, status: .created))
                var ids: [String] = []
                // Hourly samples cover both timezone overlap/gap directions and both boundaries.
                let start = try XCTUnwrap(timeInstant("2026-10-12T00:00:00Z"))
                let formatter = ISO8601DateFormatter()
                for hour in 0..<48 {
                    let instant = start.addingTimeInterval(Double(hour * 3600))
                    ids.append(try resourceID(await timeRequest(app, context, .POST, "time/segments",
                        segmentBody(formatter.string(from: instant), formatter.string(from: instant.addingTimeInterval(1800))), status: .created)))
                }
                let response = try await timeRequest(app, context, .GET, "time/days?from=2026-10-10&to=2026-10-14")
                let days = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [[String: Any]])
                let assigned = days.flatMap { $0["segmentIds"] as? [String] ?? [] }
                XCTAssertEqual(assigned.count, ids.count)
                XCTAssertEqual(Set(assigned), Set(ids))
                XCTAssertEqual(days.reduce(0) { $0 + ($1["rawWorkSeconds"] as? Int ?? 0) }, 48 * 1800)
                XCTAssertEqual(days.reduce(0) { $0 + ($1["evaluatedWorkSeconds"] as? Int ?? 0) }, 48 * 1800)
                for day in days {
                    XCTAssertEqual(day["modelId"] as? String, (day["date"] as! String) < "2026-10-13" ? oldID : newID)
                }
                if oldZone == "Europe/Berlin" {
                    let transitionDay = try XCTUnwrap(days.first { $0["date"] as? String == "2026-10-13" })
                    XCTAssertTrue((transitionDay["segmentIds"] as? [String] ?? []).contains(ids[24]))
                }
                let account = try object(await timeRequest(app, context, .GET, "time/account?asOf=2026-10-14"))
                XCTAssertEqual(account["balanceSeconds"] as? Int, 48 * 1800)
            }
        }
    }
}

final class ModelTransitionTests: XCTestCase {
    func testEngineAccountUsesSameUniqueAssignmentAndExcludesVoidedSegments() throws {
        for (oldBoundary, newBoundary, oldZone, newZone) in [
            (0, 240, "Europe/Berlin", "Europe/Berlin"),
            (240, 0, "Europe/Berlin", "Europe/Berlin"),
            (0, 240, "Asia/Tokyo", "America/New_York"),
            (240, 0, "America/New_York", "Asia/Tokyo")
        ] {
            let old = EngineWorkModel(validFrom: try LocalDate("2026-10-10"), validTo: try LocalDate("2026-10-12"),
                timezone: oldZone, weeklyTargetSeconds: 0, workdays: [], roundingEnabled: false, dayBoundaryMinutes: oldBoundary)
            let next = EngineWorkModel(validFrom: try LocalDate("2026-10-13"), timezone: newZone,
                weeklyTargetSeconds: 0, workdays: [], roundingEnabled: false, dayBoundaryMinutes: newBoundary)
            let start = try XCTUnwrap(timeInstant("2026-10-12T00:00:00Z"))
            let segments = (0..<48).map { hour in
                EngineSegment(start: start.addingTimeInterval(Double(hour * 3600)),
                    end: start.addingTimeInterval(Double(hour * 3600 + 1800)))
            } + [EngineSegment(start: start, end: start.addingTimeInterval(999), voided: true)]
            let now = try XCTUnwrap(timeInstant("2026-10-15T12:00:00Z"))
            let snapshot = TimeEvaluationSnapshot(models: [next, old], segments: segments, preferences: [:])
            let days = try (10...14).map { try snapshot.evaluate(LocalDate("2026-10-\($0)"), now: now) }
            XCTAssertEqual(days.flatMap(\.segmentIds).count, 48)
            XCTAssertEqual(Set(days.flatMap(\.segmentIds)), Set(segments.filter { !$0.voided }.map(\.id)))
            XCTAssertEqual(days.reduce(0) { $0 + $1.rawWorkSeconds }, 86400)
            let account = try TimeEngine.accountBalance(accountStart: LocalDate("2026-10-10"), asOf: LocalDate("2026-10-14"),
                timezone: newZone, models: [next, old], segments: segments, now: now)
            XCTAssertEqual(account.balanceSeconds, 86400)
        }
    }
}
