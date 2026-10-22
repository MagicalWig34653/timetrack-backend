import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// W1: departure stops manually started timers (part A) and unauthenticated trigger links (part B).
extension AuthTests {
    // MARK: Part A

    private func deviceBearer(_ app: Application, _ context: AuthContext) async throws -> HTTPHeaders {
        let created = try object(await timeRequest(app, context, .POST, "me/device-tokens", ["name": "Phone"], status: .created))
        return ["Authorization": "Bearer " + (try XCTUnwrap(created["token"] as? String))]
    }
    private func event(_ app: Application, _ bearer: HTTPHeaders, _ place: String, _ type: String, _ instant: String) async throws -> [String: Any] {
        try object(await timeRequest(app, nil, .POST, "automation/events", automationBody(place, type, instant), extra: bearer))
    }
    private func openSegment(_ app: Application, _ context: AuthContext, _ start: String, place: String? = nil) async throws -> String {
        var body = segmentBody(start)
        if let place { body["placeId"] = place }
        return try resourceID(await timeRequest(app, context, .POST, "time/segments", body, status: .created))
    }
    private func endedAt(_ app: Application, _ context: AuthContext, _ segment: String) async throws -> String? {
        try object(await timeRequest(app, context, .GET, "time/segments/" + segment))["endedAt"] as? String
    }

    func testDepartureStopsManuallyStartedTimer() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let bearer = try await deviceBearer(app, context)
            let direct = try resourceID(await timeRequest(app, context, .POST, "places", placeBody(), status: .created))
            // A segment created through the plain segment endpoint without an end counts as running (no arrival event at all).
            let manual = try await openSegment(app, context, "2026-10-12T06:00:00Z")
            let first = try await event(app, bearer, direct, "departure", "2026-10-12T09:30:00Z")
            XCTAssertEqual(first["result"] as? String, "booked")
            XCTAssertEqual(first["segmentId"] as? String, manual.uppercased())
            let manualEnd = try await endedAt(app, context, manual)
            XCTAssertEqual(manualEnd, "2026-10-12T09:30:00Z")
            // Started through the timer endpoint.
            let started = try object(await timeRequest(app, context, .POST, "time/timer/start", ["clientEventId": UUID().uuidString]))
            let startedAt = try XCTUnwrap(timeInstant(try XCTUnwrap(started["startedAt"] as? String)))
            let stopAt = ISO8601DateFormatter().string(from: startedAt.addingTimeInterval(3600))
            let result = try await event(app, bearer, direct, "departure", stopAt)
            XCTAssertEqual(result["result"] as? String, "booked")
            XCTAssertEqual(result["segmentId"] as? String, started["id"] as? String)
            let stoppedAt = try await endedAt(app, context, try XCTUnwrap(started["id"] as? String))
            XCTAssertEqual(stoppedAt, stopAt)
            let timer = try await timeRequest(app, context, .GET, "time/timer")
            XCTAssertEqual(timer.body.string, "null")
        }
    }

    func testDepartureWithoutRunningTimerIsHarmless() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let bearer = try await deviceBearer(app, context)
            let direct = try resourceID(await timeRequest(app, context, .POST, "places", placeBody(), status: .created))
            for instant in ["2026-10-12T09:30:00Z", "2026-10-12T09:45:00Z"] {
                let result = try await event(app, bearer, direct, "departure", instant)
                XCTAssertEqual(result["result"] as? String, "ignored")
            }
            let segments = try await SegmentRecord.query(on: app.db).count(); XCTAssertEqual(segments, 0)
        }
    }

    func testDepartureRespectsModeAndPassBy() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let bearer = try await deviceBearer(app, context)
            let direct = try resourceID(await timeRequest(app, context, .POST, "places", placeBody(), status: .created))
            let off = try resourceID(await timeRequest(app, context, .POST, "places", placeBody("off"), status: .created))
            let suggest = try resourceID(await timeRequest(app, context, .POST, "places", placeBody("suggest"), status: .created))
            let segment = try await openSegment(app, context, "2026-10-12T06:00:00Z")
            // Automation off for the place: only recorded, the timer keeps running.
            let offResult = try await event(app, bearer, off, "departure", "2026-10-12T08:00:00Z")
            XCTAssertEqual(offResult["result"] as? String, "recorded")
            let stillOpen1 = try await endedAt(app, context, segment); XCTAssertNil(stillOpen1)
            // Suggest mode: a proposal, the timer keeps running, accepting ends it at the event time.
            let proposed = try await event(app, bearer, suggest, "departure", "2026-10-12T09:00:00Z")
            XCTAssertEqual(proposed["result"] as? String, "suggested")
            let stillOpen2 = try await endedAt(app, context, segment); XCTAssertNil(stillOpen2)
            // Passing by (arrival without dwell, then departure) must not touch the running timer.
            _ = try await event(app, bearer, direct, "arrival", "2026-10-12T09:10:00Z")
            let passBy = try await event(app, bearer, direct, "departure", "2026-10-12T09:11:00Z")
            XCTAssertEqual(passBy["result"] as? String, "ignored")
            let stillOpen3 = try await endedAt(app, context, segment); XCTAssertNil(stillOpen3)
            try await timeRequest(app, context, .POST, "time/suggestions/" + (try XCTUnwrap(proposed["suggestionId"] as? String)) + "/accept")
            let accepted = try await endedAt(app, context, segment)
            XCTAssertEqual(accepted, "2026-10-12T09:00:00Z")
        }
    }

    func testDepartureIgnoresTimerBoundToAnotherPlaceAndKeepsArrivalFlow() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let bearer = try await deviceBearer(app, context)
            let office = try resourceID(await timeRequest(app, context, .POST, "places", placeBody(), status: .created))
            let school = try resourceID(await timeRequest(app, context, .POST, "places", placeBody(), status: .created))
            let bound = try await openSegment(app, context, "2026-10-12T06:00:00Z", place: school)
            let ignored = try await event(app, bearer, office, "departure", "2026-10-12T08:00:00Z")
            XCTAssertEqual(ignored["result"] as? String, "ignored")
            let stillOpen = try await endedAt(app, context, bound); XCTAssertNil(stillOpen)
            try await timeRequest(app, context, .DELETE, "time/segments/" + bound + "?reason=test", status: .noContent)
            // Arrival-started timers still end through the existing visit flow.
            _ = try await event(app, bearer, office, "arrival", "2026-10-13T06:00:00Z")
            let booked = try await event(app, bearer, office, "presence_confirmed", "2026-10-13T06:06:00Z")
            XCTAssertEqual(booked["result"] as? String, "booked")
            let departure = try await event(app, bearer, office, "departure", "2026-10-13T10:00:00Z")
            XCTAssertEqual(departure["result"] as? String, "booked")
            let ended = try await endedAt(app, context, try XCTUnwrap(booked["segmentId"] as? String))
            XCTAssertEqual(ended, "2026-10-13T10:00:00Z")
        }
    }

    // MARK: Part B

    @discardableResult
    private func trigger(_ app: Application, _ path: String, method: HTTPMethod = .GET, headers: HTTPHeaders = [:], status: HTTPStatus = .ok,
                         file: StaticString = #filePath, line: UInt = #line) async throws -> XCTHTTPResponse {
        let response = try await app.testable().sendRequest(method, path, headers: headers)
        XCTAssertEqual(response.status, status, response.body.string, file: file, line: line)
        XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store", file: file, line: line)
        return response
    }
    private func createLink(_ app: Application, _ context: AuthContext, label: String = "Door", actions: [String] = ["start", "stop", "toggle"],
                            place: String? = nil) async throws -> (id: String, token: String) {
        var body: [String: Any] = ["label": label, "actions": actions]
        if let place { body["placeId"] = place }
        let created = try object(await timeRequest(app, context, .POST, "me/trigger-links", body, status: .created))
        let token = try XCTUnwrap(created["token"] as? String)
        XCTAssertEqual(created["path"] as? String, "/t/" + token)
        XCTAssertGreaterThanOrEqual(token.count * 6, 256)
        return (try XCTUnwrap(created["id"] as? String), token)
    }
    private func triggerResult(_ response: XCTHTTPResponse) throws -> String { try XCTUnwrap(object(response)["result"] as? String) }
    private func linkList(_ response: XCTHTTPResponse) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [[String: Any]])
    }
    private func iso(_ offset: TimeInterval) -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset)) }

    func testTriggerLinkManagementStoresOnlyHash() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let link = try await createLink(app, context)
            let rows = try await TriggerLinkRecord.query(on: app.db).all()
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].tokenHash, Secrets.hash(link.token)); XCTAssertNotEqual(rows[0].tokenHash, link.token)
            let list = try await timeRequest(app, context, .GET, "me/trigger-links")
            XCTAssertFalse(list.body.string.contains(link.token)); XCTAssertFalse(list.body.string.contains(rows[0].tokenHash))
            XCTAssertNil(try linkList(list)[0]["token"])
            // Validation.
            try await timeRequest(app, context, .POST, "me/trigger-links", ["label": "x", "actions": []], status: .badRequest)
            try await timeRequest(app, context, .POST, "me/trigger-links", ["label": "x", "actions": ["delete"]], status: .badRequest)
            try await timeRequest(app, context, .POST, "me/trigger-links", ["label": " ", "actions": ["start"]], status: .badRequest)
            try await timeRequest(app, context, .POST, "me/trigger-links", ["label": "x", "actions": ["start"], "placeId": UUID().uuidString], status: .notFound)
            try await timeRequest(app, nil, .GET, "me/trigger-links", status: .unauthorized)
            try await timeRequest(app, context, .POST, "me/trigger-links", ["label": "x", "actions": ["start"]], status: .forbidden, extra: ["X-CSRF-Token": "wrong"])
            // Limit of active links.
            for index in 1..<TriggerLinkRules.maxActiveLinks { _ = try await createLink(app, context, label: "L\(index)") }
            let over = try await timeRequest(app, context, .POST, "me/trigger-links", ["label": "over", "actions": ["start"]], status: .conflict)
            XCTAssertEqual(try errorCode(over), "too_many_trigger_links")
            // Revocation is idempotent and other accounts cannot revoke.
            let other = try await second(app, auth, context)
            try await timeRequest(app, other, .DELETE, "me/trigger-links/" + link.id, status: .notFound)
            try await timeRequest(app, context, .DELETE, "me/trigger-links/" + link.id, status: .noContent)
            try await timeRequest(app, context, .DELETE, "me/trigger-links/" + link.id, status: .noContent)
            let after = try linkList(try await timeRequest(app, context, .GET, "me/trigger-links"))
            XCTAssertEqual(after.count, TriggerLinkRules.maxActiveLinks - 1)
            let otherList = try linkList(try await timeRequest(app, other, .GET, "me/trigger-links"))
            XCTAssertEqual(otherList.count, 0)
        }
    }

    func testTriggerLinkStartStopIdempotentBackdatedAndSeparated() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let other = try await second(app, auth, context)
            let link = try await createLink(app, context)
            // The second account has its own running timer which must stay untouched.
            let foreign = try await openSegment(app, other, "2026-10-12T06:00:00Z")
            let base = "/t/" + link.token
            let one = try await trigger(app, base + "/start?at=" + iso(-6600))
            XCTAssertEqual(try triggerResult(one), "started")
            XCTAssertEqual(one.headers.first(name: "Referrer-Policy"), "no-referrer")
            let segmentId = try XCTUnwrap(object(one)["segmentId"] as? String)
            let again = try await trigger(app, base + "/start")
            XCTAssertEqual(try triggerResult(again), "already_running"); XCTAssertEqual(try object(again)["segmentId"] as? String, segmentId)
            let ownId = try context.account.requireID()
            let count = try await SegmentRecord.query(on: app.db).filter(\.$accountId == ownId).count(); XCTAssertEqual(count, 1)
            _ = segmentId
            let stopAt = iso(-6000)
            let stopped = try await trigger(app, base + "/stop?at=" + stopAt)
            XCTAssertEqual(try triggerResult(stopped), "stopped")
            let ended = try await endedAt(app, context, segmentId); XCTAssertEqual(ended, stopAt)
            let stoppedAgain = try await trigger(app, base + "/stop")
            XCTAssertEqual(try triggerResult(stoppedAgain), "already_stopped")
            let foreignEnd = try await endedAt(app, other, foreign); XCTAssertNil(foreignEnd)
            // Plain text format, bad and out-of-window timestamps.
            let text = try await trigger(app, base + "/stop?format=text")
            XCTAssertEqual(text.body.string, "already_stopped\n")
            try await trigger(app, base + "/stop?at=yesterday", status: .badRequest)
            try await trigger(app, base + "/start?at=" + iso(-3 * 3600), status: .badRequest)
            try await trigger(app, base + "/start?at=" + iso(600), status: .badRequest)
            // Backdated start inside the window.
            let backdated = iso(-5400)
            let started = try await trigger(app, base + "/start?at=" + backdated)
            XCTAssertEqual(try triggerResult(started), "started")
            XCTAssertEqual(try object(started)["at"] as? String, backdated)
            try await trigger(app, base + "/stop?at=" + iso(-3600))
            // The link also stops a timer that was started manually.
            let manual = try await openSegment(app, context, iso(-1800))
            let manualStop = try await trigger(app, base + "/stop")
            XCTAssertEqual(try triggerResult(manualStop), "stopped")
            let manualEnd = try await endedAt(app, context, manual); XCTAssertNotNil(manualEnd)
            // Last use is tracked.
            let listed = try linkList(try await timeRequest(app, context, .GET, "me/trigger-links"))
            XCTAssertNotNil(listed[0]["lastUsedAt"] as? String); XCTAssertEqual(listed[0]["lastAction"] as? String, "stop")
        }
    }

    func testTriggerLinkToggleHeadPrefetchAndActionRestriction() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let link = try await createLink(app, context)
            let startOnly = try await createLink(app, context, label: "Start only", actions: ["start"])
            let base = "/t/" + link.token
            let first = try await trigger(app, base + "/toggle")
            XCTAssertEqual(try triggerResult(first), "started")
            // A repeated toggle inside the guard interval is a duplicate (retry or double prefetch).
            let duplicate = try await trigger(app, base + "/toggle")
            XCTAssertEqual(try triggerResult(duplicate), "already_running")
            let row = try await XCTUnwrapAsync(try await TriggerLinkRecord.find(UUID(uuidString: link.id), on: app.db))
            row.lastUsedAt = Date().addingTimeInterval(-60); try await row.update(on: app.db)
            let third = try await trigger(app, base + "/toggle")
            XCTAssertEqual(try triggerResult(third), "stopped")
            // HEAD and prefetch requests never act.
            try await trigger(app, base + "/start", method: .HEAD, status: .noContent)
            try await trigger(app, base + "/start", headers: ["Sec-Purpose": "prefetch"], status: .noContent)
            try await trigger(app, base + "/start", headers: ["Purpose": "prefetch"], status: .noContent)
            let running = try await SegmentRecord.query(on: app.db).filter(\.$running == 1).count(); XCTAssertEqual(running, 0)
            // A link only does what it was created for; the answer is the same 404 as for unknown tokens.
            try await trigger(app, "/t/" + startOnly.token + "/stop", status: .notFound)
            try await trigger(app, "/t/" + startOnly.token + "/toggle", status: .notFound)
            try await trigger(app, "/t/" + startOnly.token + "/other", status: .notFound)
            let ok = try await trigger(app, "/t/" + startOnly.token + "/start")
            XCTAssertEqual(try triggerResult(ok), "started")
        }
    }

    func testTriggerLinkUnknownRevokedExpiredAndNoOracle() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let link = try await createLink(app, context)
            let unknown = try await trigger(app, "/t/" + Secrets.token() + "/start", status: .notFound)
            let malformed = try await trigger(app, "/t/short/start", status: .notFound)
            XCTAssertEqual(unknown.body.string, malformed.body.string)
            // Revoked.
            try await trigger(app, "/t/" + link.token + "/start")
            try await timeRequest(app, context, .DELETE, "me/trigger-links/" + link.id, status: .noContent)
            let revoked = try await trigger(app, "/t/" + link.token + "/stop", status: .notFound)
            XCTAssertEqual(revoked.body.string, unknown.body.string)
            // Expired.
            let expiring = try await createLink(app, context, label: "Expiring")
            let row = try await XCTUnwrapAsync(try await TriggerLinkRecord.find(UUID(uuidString: expiring.id), on: app.db))
            row.expiresAt = Date().addingTimeInterval(-1); try await row.update(on: app.db)
            try await trigger(app, "/t/" + expiring.token + "/start", status: .notFound)
            // A disabled account no longer works.
            let alive = try await createLink(app, context, label: "Alive")
            let account = try await XCTUnwrapAsync(try await Account.find(context.account.requireID(), on: app.db))
            account.disabledAt = Date(); try await account.update(on: app.db)
            try await trigger(app, "/t/" + alive.token + "/start", status: .notFound)
        }
    }

    func testTriggerLinkRateLimits() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let link = try await createLink(app, context)
            let now = Date()
            for _ in 0..<TriggerLinkRules.linkLimit { try await RateLimitEvent(key: "trigger:" + link.id.uppercased(), occurredAt: now).create(on: app.db) }
            let limited = try await trigger(app, "/t/" + link.token + "/start", status: .tooManyRequests)
            XCTAssertNotNil(limited.headers.first(name: .retryAfter))
            let segments = try await SegmentRecord.query(on: app.db).count(); XCTAssertEqual(segments, 0)
        }
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let link = try await createLink(app, context)
            for _ in 0..<TriggerLinkRules.missLimit { try await trigger(app, "/t/" + Secrets.token() + "/start", status: .notFound) }
            // Further guesses are rejected before the lookup, even with a valid token from the same client.
            try await trigger(app, "/t/" + Secrets.token() + "/start", status: .tooManyRequests)
            try await trigger(app, "/t/" + link.token + "/start", status: .tooManyRequests)
        }
    }

    func testTriggerLinkPlaceBindingAndModes() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let office = try resourceID(await timeRequest(app, context, .POST, "places", placeBody(), status: .created))
            let off = try resourceID(await timeRequest(app, context, .POST, "places", placeBody("off"), status: .created))
            let suggest = try resourceID(await timeRequest(app, context, .POST, "places", placeBody("suggest"), status: .created))
            let bound = try await createLink(app, context, label: "Office", place: office)
            let free = try await createLink(app, context, label: "Free")
            // Bound link: the segment carries the place; a different place in the query is refused.
            let started = try await trigger(app, "/t/" + bound.token + "/start?at=" + iso(-6600))
            let segmentId = try XCTUnwrap(object(started)["segmentId"] as? String)
            let segment = try object(await timeRequest(app, context, .GET, "time/segments/" + segmentId))
            XCTAssertEqual((segment["placeId"] as? String)?.lowercased(), office.lowercased())
            try await trigger(app, "/t/" + bound.token + "/stop?place=" + suggest, status: .badRequest)
            try await trigger(app, "/t/" + bound.token + "/stop?place=" + UUID().uuidString, status: .badRequest)
            let stopped = try await trigger(app, "/t/" + bound.token + "/stop?at=" + iso(-6000))
            XCTAssertEqual(try triggerResult(stopped), "stopped")
            // A bound link leaves timers of another place alone.
            let other = try await openSegment(app, context, iso(-600), place: suggest)
            let skipped = try await trigger(app, "/t/" + bound.token + "/stop")
            XCTAssertEqual(try triggerResult(skipped), "ignored")
            let stillOpen1 = try await endedAt(app, context, other); XCTAssertNil(stillOpen1)
            // Unbound link with ?place=: the mode of that place applies (suggest -> proposal, off -> ignored).
            let proposal = try await trigger(app, "/t/" + free.token + "/stop?place=" + suggest)
            XCTAssertEqual(try triggerResult(proposal), "suggested")
            let stillOpen2 = try await endedAt(app, context, other); XCTAssertNil(stillOpen2)
            let offResult = try await trigger(app, "/t/" + free.token + "/stop?place=" + off)
            XCTAssertEqual(try triggerResult(offResult), "ignored")
            try await trigger(app, "/t/" + free.token + "/stop?place=not-a-uuid", status: .badRequest)
            let direct = try await trigger(app, "/t/" + free.token + "/stop")
            XCTAssertEqual(try triggerResult(direct), "stopped")
            let startProposal = try await trigger(app, "/t/" + free.token + "/start?place=" + suggest)
            XCTAssertEqual(try triggerResult(startProposal), "suggested")
        }
    }

    func testTriggerLinkModuleDisabledAndScrubber() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let link = try await createLink(app, context)
            try await setModules(app, context, ["automation": false])
            try await trigger(app, "/t/" + link.token + "/start", status: .notFound)
            try await setModules(app, context, ["automation": true])
            let ok = try await trigger(app, "/t/" + link.token + "/start")
            XCTAssertEqual(try triggerResult(ok), "started")
        }
        let token = Secrets.token()
        XCTAssertEqual(TriggerTokenScrubber.scrub("GET /t/\(token)/start?at=x HTTP/1.1"), "GET /t/[redacted]/start?at=x HTTP/1.1")
        XCTAssertEqual(TriggerTokenScrubber.scrub("GET /api/v1/time/timer"), "GET /api/v1/time/timer")
    }
}
