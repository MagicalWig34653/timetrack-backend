import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

extension AuthTests {
    func automationBody(_ place: String, _ type: String, _ instant: String, eventId: String = UUID().uuidString) -> [String: Any] {
        ["eventId": eventId, "deviceId": "shortcut", "placeId": place, "type": type, "occurredAt": instant]
    }
    func testAutomationDirectSuggestOffPassByAndOrdering() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let tokenResponse = try object(await timeRequest(app, context, .POST, "me/device-tokens", ["name": "Phone"], status: .created))
            let token = try XCTUnwrap(tokenResponse["token"] as? String)
            let bearer: HTTPHeaders = ["Authorization": "Bearer " + token]
            let direct = try resourceID(await timeRequest(app, context, .POST, "places", placeBody(), status: .created))
            let arrival = automationBody(direct, "arrival", "2026-10-12T06:07:00Z")
            let recorded = try object(await timeRequest(app, nil, .POST, "automation/events", arrival, extra: bearer))
            XCTAssertEqual(recorded["result"] as? String, "recorded")
            let confirmation = automationBody(direct, "presence_confirmed", "2026-10-12T06:12:00Z")
            let booked = try object(await timeRequest(app, nil, .POST, "automation/events", confirmation, extra: bearer))
            XCTAssertEqual(booked["result"] as? String, "booked")
            let replay = try object(await timeRequest(app, nil, .POST, "automation/events", confirmation, extra: bearer))
            XCTAssertEqual(replay["segmentId"] as? String, booked["segmentId"] as? String)
            XCTAssertEqual(replay["result"] as? String, "booked")
            let segmentId = try XCTUnwrap(booked["segmentId"] as? String)
            let segment = try object(await timeRequest(app, context, .GET, "time/segments/" + segmentId))
            XCTAssertEqual(segment["startedAt"] as? String, "2026-10-12T06:07:00Z")
            let unordered = try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(direct, "departure", "2026-10-12T06:10:00Z"), extra: bearer))
            XCTAssertEqual(unordered["result"] as? String, "needs_review")
            let departure = try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(direct, "departure", "2026-10-12T10:00:00Z"), extra: bearer))
            XCTAssertEqual(departure["result"] as? String, "booked")
            let stopped = try object(await timeRequest(app, context, .GET, "time/segments/" + segmentId))
            XCTAssertEqual(stopped["endedAt"] as? String, "2026-10-12T10:00:00Z")
            let suggest = try resourceID(await timeRequest(app, context, .POST, "places", placeBody("suggest"), status: .created))
            try await timeRequest(app, nil, .POST, "automation/events", automationBody(suggest, "arrival", "2026-10-12T11:00:00Z"), extra: bearer)
            let suggestion = try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(suggest, "presence_confirmed", "2026-10-12T11:05:00Z"), extra: bearer))
            XCTAssertEqual(suggestion["result"] as? String, "suggested")
            let suggestionId = try XCTUnwrap(suggestion["suggestionId"] as? String)
            try await timeRequest(app, nil, .POST, "automation/events", automationBody(suggest, "departure", "2026-10-12T14:02:00Z"), extra: bearer)
            try await timeRequest(app, context, .GET, "time/suggestions")
            try await timeRequest(app, context, .POST, "time/suggestions/" + suggestionId + "/accept")
            let resolved = try object(await timeRequest(app, context, .POST, "time/suggestions/" + suggestionId + "/accept", status: .conflict))
            XCTAssertEqual((resolved["error"] as? [String: String])?["code"], "suggestion_resolved")
            let off = try resourceID(await timeRequest(app, context, .POST, "places", placeBody("off"), status: .created))
            for type in ["arrival", "presence_confirmed", "departure", "cancel"] {
                let result = try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(off, type, "2026-10-13T08:00:00Z"), extra: bearer))
                XCTAssertEqual(result["result"] as? String, "recorded")
            }
            try await timeRequest(app, nil, .POST, "automation/events", automationBody(direct, "arrival", "2026-10-13T08:00:00Z"), extra: bearer)
            let passBy = try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(direct, "departure", "2026-10-13T08:01:00Z"), extra: bearer))
            XCTAssertEqual(passBy["result"] as? String, "ignored")
            let lateConfirm = try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(direct, "presence_confirmed", "2026-10-13T08:06:00Z"), extra: bearer))
            XCTAssertEqual(lateConfirm["result"] as? String, "ignored")
            let count = try await SegmentRecord.query(on: app.db).count(); XCTAssertEqual(count, 2)
        }
    }
    func testDeviceTokenScopeExpiryRevocationAndCSRF() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let created = try object(await timeRequest(app, context, .POST, "me/device-tokens", ["name": "Phone", "expiresInDays": 1], status: .created))
            let token = try XCTUnwrap(created["token"] as? String); let id = try XCTUnwrap(created["id"] as? String)
            let bearer: HTTPHeaders = ["Authorization": "Bearer " + token]
            let rows = try await DeviceTokenRecord.query(on: app.db).all()
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].tokenHash, Secrets.hash(token)); XCTAssertNotEqual(rows[0].tokenHash, token)
            let list = try await timeRequest(app, context, .GET, "me/device-tokens")
            XCTAssertFalse(list.body.string.contains(token))
            try await timeRequest(app, nil, .GET, "work-models", status: .unauthorized, extra: bearer)
            try await timeRequest(app, nil, .GET, "auth/session", status: .unauthorized, extra: bearer)
            try await timeRequest(app, context, .GET, "work-models", status: .unauthorized, extra: bearer)
            try await timeRequest(app, context, .POST, "automation/events", [:], status: .unauthorized)
            try await timeRequest(app, context, .POST, "automation/events", [:], status: .unauthorized, extra: bearer)
            try await timeRequest(app, context, .POST, "places", placeBody(), status: .forbidden, extra: ["X-CSRF-Token": "wrong"])
            let recovery = try await auth.issueSession(for: context.account, recovery: true, on: app.db)
            try await timeRequest(app, recovery, .GET, "work-models", status: .forbidden)
            rows[0].expiresAt = Date().addingTimeInterval(-1); try await rows[0].update(on: app.db)
            try await timeRequest(app, nil, .POST, "automation/events", [:], status: .unauthorized, extra: bearer)
            rows[0].expiresAt = nil; try await rows[0].update(on: app.db)
            try await timeRequest(app, context, .DELETE, "me/device-tokens/" + id, status: .noContent)
            try await timeRequest(app, nil, .POST, "automation/events", [:], status: .unauthorized, extra: bearer)
        }
    }
    func testTimeIsolationEveryDirectResourceAndForeignReferences() async throws {
        try await withApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let (other, _) = try await registered(auth, db: app.db, handle: "other", admin: owner)
            let modelId = try resourceID(await timeRequest(app, owner, .POST, "work-models", modelBody(), status: .created))
            let placeId = try resourceID(await timeRequest(app, owner, .POST, "places", placeBody("suggest"), status: .created))
            let segmentId = try resourceID(await timeRequest(app, owner, .POST, "time/segments", segmentBody("2026-10-12T06:00:00Z", "2026-10-12T07:00:00Z"), status: .created))
            let token = try object(await timeRequest(app, owner, .POST, "me/device-tokens", ["name": "Owner"], status: .created))
            let tokenId = try XCTUnwrap(token["id"] as? String)
            let bearer: HTTPHeaders = ["Authorization": "Bearer " + (try XCTUnwrap(token["token"] as? String))]
            try await timeRequest(app, nil, .POST, "automation/events", automationBody(placeId, "arrival", "2026-10-12T08:00:00Z"), extra: bearer)
            let result = try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(placeId, "presence_confirmed", "2026-10-12T08:05:00Z"), extra: bearer))
            let suggestionId = try XCTUnwrap(result["suggestionId"] as? String)
            try await timeRequest(app, other, .GET, "work-models/" + modelId, status: .notFound)
            try await timeRequest(app, other, .PATCH, "work-models/" + modelId, ["validTo": "2026-10-31"], status: .notFound)
            try await timeRequest(app, other, .PUT, "places/" + placeId, placeBody(), status: .notFound)
            try await timeRequest(app, other, .DELETE, "places/" + placeId, status: .notFound)
            try await timeRequest(app, other, .GET, "time/segments/" + segmentId, status: .notFound)
            try await timeRequest(app, other, .PATCH, "time/segments/" + segmentId, ["reason": "Foreign"], status: .notFound, extra: ["If-Match": "1"])
            try await timeRequest(app, other, .DELETE, "time/segments/" + segmentId + "?reason=Foreign", status: .notFound)
            try await timeRequest(app, other, .POST, "time/suggestions/" + suggestionId + "/accept", status: .notFound)
            try await timeRequest(app, other, .POST, "time/suggestions/" + suggestionId + "/reject", status: .notFound)
            try await timeRequest(app, other, .DELETE, "me/device-tokens/" + tokenId, status: .notFound)
            var input = segmentBody("2026-10-12T10:00:00Z", "2026-10-12T11:00:00Z"); input["placeId"] = placeId
            try await timeRequest(app, other, .POST, "time/segments", input, status: .notFound)
            try await timeRequest(app, other, .POST, "time/timer/start", ["clientEventId": UUID().uuidString, "placeId": placeId], status: .notFound)
            let otherToken = try object(await timeRequest(app, other, .POST, "me/device-tokens", ["name": "Other"], status: .created))
            try await timeRequest(app, nil, .POST, "automation/events", automationBody(placeId, "arrival", "2026-10-12T10:00:00Z"), status: .notFound,
                                  extra: ["Authorization": "Bearer " + (try XCTUnwrap(otherToken["token"] as? String))])
            try await timeRequest(app, owner, .POST, "time/suggestions/" + suggestionId + "/reject", status: .noContent)
        }
    }
}

extension AuthTests {
    func testAutomationMissingDepartureAndAcceptedStartEndSuggestion() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let token = try object(await timeRequest(app, context, .POST, "me/device-tokens", ["name": "Phone"], status: .created))
            let bearer: HTTPHeaders = ["Authorization": "Bearer " + (try XCTUnwrap(token["token"] as? String))]
            let place = try resourceID(await timeRequest(app, context, .POST, "places", placeBody(), status: .created))
            try await timeRequest(app, nil, .POST, "automation/events", automationBody(place, "arrival", "2026-10-01T08:00:00Z"), extra: bearer)
            let booked = try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(place, "presence_confirmed", "2026-10-01T08:05:00Z"), extra: bearer))
            let segmentId = try XCTUnwrap(booked["segmentId"] as? String)
            let list = try await timeRequest(app, context, .GET, "time/suggestions")
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .custom { try XCTUnwrap(timeInstant($0.singleValueContainer().decode(String.self))) }
            let suggestions = try decoder.decode([SuggestionDTO].self, from: Data(list.body.readableBytesView))
            XCTAssertEqual(suggestions.count, 1); XCTAssertEqual(suggestions.first?.type, "end"); XCTAssertNil(suggestions.first?.proposedEndedAt)
            let running = try object(await timeRequest(app, context, .GET, "time/segments/" + segmentId))
            XCTAssertTrue(running["endedAt"] is NSNull); XCTAssertEqual(running["needsReview"] as? Bool, true)
            try await timeRequest(app, context, .POST, "time/suggestions/" + suggestions[0].id.uuidString + "/accept", ["endedAt": "2026-10-01T16:00:00Z"])
            try await timeRequest(app, context, .PUT, "places/" + place, placeBody("suggest"))
            try await timeRequest(app, nil, .POST, "automation/events", automationBody(place, "arrival", "2026-10-02T08:00:00Z"), extra: bearer)
            let proposed = try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(place, "presence_confirmed", "2026-10-02T08:05:00Z"), extra: bearer))
            try await timeRequest(app, context, .POST, "time/suggestions/" + (try XCTUnwrap(proposed["suggestionId"] as? String)) + "/accept")
            let end = try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(place, "departure", "2026-10-02T16:00:00Z"), extra: bearer))
            XCTAssertEqual(end["result"] as? String, "suggested")
            try await timeRequest(app, context, .POST, "time/suggestions/" + (try XCTUnwrap(end["suggestionId"] as? String)) + "/accept")
            let count = try await SegmentRecord.query(on: app.db).filter(\.$running == 1).count(); XCTAssertEqual(count, 0)
        }
    }
    func testAutomationRateLimitAndInvalidTimeInputs() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let token = try object(await timeRequest(app, context, .POST, "me/device-tokens", ["name": "Phone"], status: .created))
            let id = try XCTUnwrap(token["id"] as? String)
            for _ in 0..<120 { try await RateLimitEvent(key: "device:" + id, occurredAt: Date()).create(on: app.db) }
            try await timeRequest(app, nil, .POST, "automation/events", [:], status: .tooManyRequests,
                                  extra: ["Authorization": "Bearer " + (try XCTUnwrap(token["token"] as? String))])
            try await timeRequest(app, context, .GET, "time/days/2026-02-30", status: .badRequest)
            var model = modelBody(); model["timezone"] = "Invalid/Zone"
            try await timeRequest(app, context, .POST, "work-models", model, status: .badRequest)
            try await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-12T08:00:00Z", "2026-10-12T07:00:00Z"), status: .badRequest)
        }
    }
}
