import Foundation
import Fluent
import XCTVapor
import Crypto
@testable import TimetrackKit

// C18: notifications REST, settings, subscriptions, scheduler, push delivery and leases.
// Each scenario runs on SQLite and (gated on MARIADB_TEST_HOST) on MariaDB.

extension AuthTests {
    typealias NotificationScenario = (Application, AuthService, NotificationRuntime, FakePushService) async throws -> Void

    func scenarioNotificationSettings(_ app: Application, _ auth: AuthService, _ runtime: NotificationRuntime, _ fake: FakePushService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let defaults = try object(await api(app, a, .GET, "notifications/settings"))
        let categories = try await need(defaults["categories"] as? [String: [String: Any]])
        try await eq(Set(categories.keys), Set(NotificationKind.reminders))
        try await eq(categories["running_timer"]?["thresholdMinutes"] as? Int, 600)
        try await eq(categories["report_gap"]?["weekday"] as? Int, 5); try await eq(categories["report_gap"]?["time"] as? String, "15:00")
        try await eq(defaults["quietStart"] as? String, "22:00"); try await eq(defaults["quietEnd"] as? String, "07:00")
        func put(_ body: [String: Any], _ status: HTTPStatus = .ok) async throws -> XCTHTTPResponse { try await api(app, a, .PUT, "notifications/settings", body, status) }
        let saved = try object(await put(["categories": ["running_timer": ["inApp": false, "push": true, "thresholdMinutes": 120]], "quietStart": NSNull(), "quietEnd": NSNull()]))
        let savedCategories = try await need(saved["categories"] as? [String: [String: Any]])
        try await eq(savedCategories["running_timer"]?["inApp"] as? Bool, false); try await eq(savedCategories["running_timer"]?["thresholdMinutes"] as? Int, 120)
        try await eq(savedCategories["report_gap"]?["inApp"] as? Bool, true)   // missing category: default
        XCTAssertTrue(saved["quietStart"] is NSNull)
        let again = try object(await api(app, a, .GET, "notifications/settings"))
        XCTAssertTrue(again["quietEnd"] is NSNull)
        try await eq((again["categories"] as? [String: [String: Any]])?["running_timer"]?["thresholdMinutes"] as? Int, 120)
        // Validation.
        let ok: [String: Any] = ["inApp": true, "push": false]
        let invalid: [[String: Any]] = [
            ["categories": ["unknown": ok]], ["categories": ["system": ok]],
            ["categories": ["running_timer": ok.merging(["thresholdMinutes": 29]) { $1 }]], ["categories": ["running_timer": ok.merging(["thresholdMinutes": 1441]) { $1 }]],
            ["categories": ["pending_suggestions": ok.merging(["thresholdMinutes": 60]) { $1 }]],
            ["categories": ["report_gap": ok.merging(["weekday": 0]) { $1 }]], ["categories": ["report_gap": ok.merging(["weekday": 8]) { $1 }]],
            ["categories": ["running_timer": ok.merging(["weekday": 1]) { $1 }]],
            ["categories": ["report_gap": ok.merging(["time": "24:00"]) { $1 }]], ["categories": ["report_gap": ok.merging(["time": "9:00"]) { $1 }]],
            ["categories": ["report_gap": ok.merging(["time": "12:60"]) { $1 }]],
            ["categories": [String: Any](), "quietStart": "22:00"], ["categories": [String: Any](), "quietEnd": "07:00"],
            ["categories": [String: Any](), "quietStart": "25:00", "quietEnd": "07:00"], ["categories": [String: Any](), "quietStart": "ab:cd", "quietEnd": "07:00"],
            ["categories": ["running_timer": ["inApp": true]]], ["nothing": true],
        ]
        for body in invalid { _ = try await put(body, .badRequest) }
        _ = try await put(["categories": ["report_gap": ok.merging(["weekday": 7, "time": "23:59"]) { $1 }], "quietStart": "00:00", "quietEnd": "06:30"])
        // Session and CSRF.
        try await timeRequest(app, nil, .GET, "notifications/settings", status: .unauthorized)
        let noCSRF = try await app.testable().sendRequest(.PUT, "/api/v1/notifications/settings", headers: headers(a, csrf: false).with(contentType: .json),
                                                          body: ByteBuffer(string: #"{"categories":{}}"#))
        try await eq(noCSRF.status, .forbidden)
        let recovery = try await auth.issueSession(for: a.account, recovery: true, on: app.db)
        try await timeRequest(app, recovery, .GET, "notifications/settings", status: .forbidden)
        try await timeRequest(app, recovery, .GET, "notifications", status: .forbidden)
        try await timeRequest(app, recovery, .POST, "me/push-subscriptions", TestSubscription(endpoint: fake.endpoint()).body, status: .forbidden)
    }

    func scenarioNotificationList(_ app: Application, _ auth: AuthService, _ runtime: NotificationRuntime, _ fake: FakePushService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let b = try await second(app, auth, a)
        var ids: [UUID] = []
        for index in 0..<5 {
            ids.append(try await seedNotification(app.db, a, key: "k\(index)", at: notificationDate("2026-10-12T10:00:0\(index)Z"), read: index == 0))
        }
        let foreign = try await seedNotification(app.db, b, key: "k0", at: notificationDate("2026-10-12T10:00:09Z"))   // same dedup key, other account
        let all = try object(await api(app, a, .GET, "notifications"))
        try await eq((all["items"] as? [[String: Any]])?.count, 5); try await eq(all["unreadCount"] as? Int, 4)
        let first = try await need((all["items"] as? [[String: Any]])?.first)
        try await eq(first["id"] as? String, ids[4].uuidString); try await eq(first["read"] as? Bool, false); try await eq(first["kind"] as? String, "system")
        XCTAssertNotNil(first["createdAt"] as? String)
        // Cursor pagination.
        let page1 = try object(await api(app, a, .GET, "notifications?limit=2"))
        let items1 = try await need(page1["items"] as? [[String: Any]]); try await eq(items1.map { $0["id"] as? String }, [ids[4].uuidString, ids[3].uuidString])
        let cursor = try await need(items1.last?["createdAt"] as? String)
        let page2 = try object(await api(app, a, .GET, "notifications?limit=2&before=\(cursor)"))
        try await eq((page2["items"] as? [[String: Any]])?.map { $0["id"] as? String }, [ids[2].uuidString, ids[1].uuidString])
        let page3 = try object(await api(app, a, .GET, "notifications?limit=2&before=\((page2["items"] as? [[String: Any]])?.last?["createdAt"] as? String ?? "")"))
        try await eq((page3["items"] as? [[String: Any]])?.map { $0["id"] as? String }, [ids[0].uuidString])
        try await eq(page3["unreadCount"] as? Int, 4)
        for bad in ["limit=0", "limit=101", "before=yesterday", "limit=x"] { try await timeRequest(app, a, .GET, "notifications?\(bad)", status: .badRequest) }
        try await eq((try object(await api(app, a, .GET, "notifications?unreadOnly=true"))["items"] as? [[String: Any]])?.count, 4)
        // Mark read: foreign ids have no effect.
        var marked = try object(await api(app, a, .POST, "notifications/read", ["ids": [ids[4].uuidString, foreign.uuidString]]))
        try await eq(marked["unreadCount"] as? Int, 3)
        try await eq(try await NotificationRecord.find(foreign, on: app.db)?.readAt == nil, true)
        try await timeRequest(app, a, .POST, "notifications/read", ["ids": []], status: .badRequest)
        try await timeRequest(app, a, .POST, "notifications/read", [:], status: .badRequest)
        try await timeRequest(app, a, .POST, "notifications/read", ["ids": Array(repeating: UUID().uuidString, count: 201)], status: .badRequest)
        marked = try object(await api(app, a, .POST, "notifications/read", ["all": true]))
        try await eq(marked["unreadCount"] as? Int, 0)
        try await eq(try await NotificationRecord.find(foreign, on: app.db)?.readAt == nil, true)
        try await eq(try object(await api(app, b, .GET, "notifications"))["unreadCount"] as? Int, 1)
        // Delete and isolation by direct id.
        try await timeRequest(app, b, .DELETE, "notifications/\(ids[0].uuidString)", status: .notFound)
        try await timeRequest(app, a, .DELETE, "notifications/\(foreign.uuidString)", status: .notFound)
        try await timeRequest(app, a, .DELETE, "notifications/\(UUID().uuidString)", status: .notFound)
        try await timeRequest(app, a, .DELETE, "notifications/not-a-uuid", status: .notFound)
        try await timeRequest(app, a, .DELETE, "notifications/\(ids[0].uuidString)", status: .noContent)
        try await timeRequest(app, a, .DELETE, "notifications/\(ids[0].uuidString)", status: .notFound)
        try await eq((try object(await api(app, a, .GET, "notifications"))["items"] as? [[String: Any]])?.count, 4)
        try await eq((try object(await api(app, b, .GET, "notifications"))["items"] as? [[String: Any]])?.count, 1)
        // CSRF on writes.
        let response = try await app.testable().sendRequest(.DELETE, "/api/v1/notifications/\(ids[1].uuidString)", headers: headers(a, csrf: false))
        try await eq(response.status, .forbidden)
    }

    func scenarioPushSubscriptions(_ app: Application, _ auth: AuthService, _ runtime: NotificationRuntime, _ fake: FakePushService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let b = try await second(app, auth, a)
        let config = try object(await api(app, a, .GET, "push/config"))
        try await eq(config["available"] as? Bool, true)
        let publicKey = try await need(config["vapidPublicKey"] as? String); try await eq(Data(base64URL: publicKey)?.count, 65)
        let sub = TestSubscription(endpoint: fake.endpoint("one"))
        let created = try object(await api(app, a, .POST, "me/push-subscriptions", sub.body, .created))
        let id = try await need(created["id"] as? String)
        try await eq(created["host"] as? String, "127.0.0.1")
        XCTAssertNil(created["endpoint"]); XCTAssertNil(created["keys"]); let createdText = try String(data: JSONSerialization.data(withJSONObject: created), encoding: .utf8) ?? ""; XCTAssertFalse(createdText.contains("one"))
        // Idempotent by endpoint.
        let repeated = try object(await api(app, a, .POST, "me/push-subscriptions", sub.body, .created))
        try await eq(repeated["id"] as? String, id)
        try await eq(try await PushSubscriptionRecord.query(on: app.db).count(), 1)
        // The same endpoint on another account is its own subscription.
        let other = try object(await api(app, b, .POST, "me/push-subscriptions", sub.body, .created))
        XCTAssertNotEqual(other["id"] as? String, id)
        // Validation.
        let good = TestSubscription(endpoint: fake.endpoint())
        func variant(_ change: (inout [String: Any]) -> Void) -> [String: Any] { var body = good.body; change(&body); return body }
        func keys(_ p256dh: String? = nil, _ authKey: String? = nil) -> [String: Any] {
            ["endpoint": fake.endpoint(), "keys": ["p256dh": p256dh ?? good.key.publicKey.x963Representation.base64URL, "auth": authKey ?? good.auth.base64URL]]
        }
        let compressed = good.key.publicKey.compressedRepresentation.base64URL
        let badBodies: [[String: Any]] = [
            variant { $0["endpoint"] = "http://push.example.test/a" }, variant { $0["endpoint"] = "ftp://push.example.test/a" }, variant { $0["endpoint"] = "not a url" },
            variant { $0["endpoint"] = "https://user:pw@push.example.test/a" }, variant { $0["endpoint"] = "https://push.example.test/a#frag" },
            variant { $0["endpoint"] = "https://push.example.test/" + String(repeating: "a", count: 2100) }, variant { $0["endpoint"] = "" },
            keys(compressed), keys("AAAA"), keys(Data(repeating: 4, count: 65).base64URL), keys(nil, "AAAA"), keys(nil, Data(repeating: 1, count: 17).base64URL),
            keys(nil, ""), variant { $0["userAgent"] = String(repeating: "u", count: 201) }, ["endpoint": fake.endpoint()],
        ]
        for body in badBodies { try await timeRequest(app, a, .POST, "me/push-subscriptions", body, status: .badRequest) }
        _ = try await api(app, a, .POST, "me/push-subscriptions", variant { $0["endpoint"] = "https://fcm.googleapis.com/ok" }, .created)
        // Listing and isolation by direct id.
        try await eq(try list(await api(app, a, .GET, "me/push-subscriptions")).count, 2)
        try await eq(try list(await api(app, b, .GET, "me/push-subscriptions")).count, 1)
        try await timeRequest(app, b, .DELETE, "me/push-subscriptions/\(id)", status: .notFound)
        try await timeRequest(app, b, .POST, "me/push-subscriptions/\(id)/test", status: .notFound)
        try await timeRequest(app, a, .DELETE, "me/push-subscriptions/\(UUID().uuidString)", status: .notFound)
        fake.reset()
        // Test push: generic payload, rate limit 5 per hour.
        for _ in 0..<5 { try await timeRequest(app, a, .POST, "me/push-subscriptions/\(id)/test", status: .accepted) }
        try await timeRequest(app, a, .POST, "me/push-subscriptions/\(id)/test", status: .tooManyRequests)
        try await eq(fake.received.count, 5)
        let plain = try WebPushCrypto.decrypt(try await need(fake.received.first).body, userAgentKey: sub.key, authSecret: sub.auth)
        let message = try await need(JSONSerialization.jsonObject(with: plain) as? [String: String])
        try await eq(message["title"], "Timetrack"); try await eq(message["url"], "/settings/notifications")
        try await eq(try await PushSubscriptionRecord.find(UUID(uuidString: id), on: app.db)?.lastSuccessAt != nil, true)
        try await timeRequest(app, a, .DELETE, "me/push-subscriptions/\(id)", status: .noContent)
        try await timeRequest(app, a, .DELETE, "me/push-subscriptions/\(id)", status: .notFound)
        // Limit of 10 per account.
        try await PushSubscriptionRecord.query(on: app.db).delete()
        for index in 0..<10 { _ = try await api(app, a, .POST, "me/push-subscriptions", TestSubscription(endpoint: fake.endpoint("l\(index)")).body, .created) }
        let overflow = try await timeRequest(app, a, .POST, "me/push-subscriptions", TestSubscription(endpoint: fake.endpoint("l10")).body, status: .conflict)
        try await eq(try errorCode(overflow), "too_many_subscriptions")
        _ = try await api(app, a, .POST, "me/push-subscriptions", TestSubscription(endpoint: fake.endpoint("l3")).body, .created)   // existing endpoint still fine at the limit
        _ = try await api(app, b, .POST, "me/push-subscriptions", TestSubscription(endpoint: fake.endpoint("l10")).body, .created)
    }

    func scenarioPushUnavailable(_ app: Application, _ auth: AuthService, _ runtime: NotificationRuntime, _ fake: FakePushService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let config = try object(await api(app, a, .GET, "push/config"))
        try await eq(config["available"] as? Bool, false); XCTAssertNil(config["vapidPublicKey"])
        let failure = try await timeRequest(app, a, .POST, "me/push-subscriptions", TestSubscription(endpoint: fake.endpoint()).body, status: .notImplemented)
        try await eq(try errorCode(failure), "push_unavailable")
        try await timeRequest(app, a, .POST, "me/push-subscriptions/\(UUID().uuidString)/test", status: .notImplemented)
        // In-app notifications keep working without push.
        _ = try await seedSegment(app.db, a, start: notificationDate("2026-10-12T05:00:00Z"))
        await runtime.scheduler.runOnce(now: notificationDate("2026-10-12T17:00:00Z"))
        let list = try object(await api(app, a, .GET, "notifications"))
        try await eq((list["items"] as? [[String: Any]])?.first?["kind"] as? String, "running_timer")
        try await eq(try await PushOutboxRecord.query(on: app.db).count(), 0)
    }

    func scenarioReminders(_ app: Application, _ auth: AuthService, _ runtime: NotificationRuntime, _ fake: FakePushService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let b = try await second(app, auth, a)
        let scheduler = runtime.scheduler
        let owner = try a.account.requireID()
        // running_timer: threshold 600 min, once per segment, German in-app text with details.
        let start = notificationDate("2026-10-12T05:30:00Z")   // 07:30 Berlin
        let segment = try await seedSegment(app.db, a, start: start, note: "Geheime Notiz")
        _ = try await seedSegment(app.db, b, start: start)
        await scheduler.runOnce(now: start.addingTimeInterval(599 * 60))
        try await eq(try await notificationCount(app.db, a), 0)
        await scheduler.runOnce(now: start.addingTimeInterval(601 * 60))
        await scheduler.runOnce(now: start.addingTimeInterval(700 * 60))   // dedup: the same segment again
        try await eq(try await notificationCount(app.db, a, kind: "running_timer"), 1)
        let timerNote = try await need(try await NotificationRecord.query(on: app.db).filter(\.$accountId == owner).first())
        try await eq(timerNote.dedupKey, "running_timer:\(segment.uuidString)"); try await eq(timerNote.title, "Timer läuft noch")
        XCTAssertTrue(timerNote.body.contains("07:30 Uhr")); XCTAssertFalse(timerNote.body.contains("Geheime"))
        try await eq(try await notificationCount(app.db, b, kind: "running_timer"), 1)
        // Custom threshold, and a stopped segment never reminds.
        _ = try await api(app, a, .PUT, "notifications/settings", ["categories": ["running_timer": ["inApp": true, "push": true, "thresholdMinutes": 30]]])
        try await endRunning(app.db, a)
        let segment2 = try await seedSegment(app.db, a, start: notificationDate("2026-10-13T08:00:00Z"))
        _ = try await seedSegment(app.db, a, start: notificationDate("2026-10-13T01:00:00Z"), end: notificationDate("2026-10-13T02:00:00Z"))
        await scheduler.runOnce(now: notificationDate("2026-10-13T08:31:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "running_timer"), 2)
        let second = try await NotificationRecord.query(on: app.db).filter(\.$dedupKey == "running_timer:\(segment2.uuidString)").first()
        XCTAssertNotNil(second)
        // pending_suggestions: older than 30 min, at most one per 6 h.
        let suggestion = SuggestionRecord(); suggestion.id = UUID(); suggestion.accountId = owner
        let created = notificationDate("2026-10-14T09:00:00Z")
        suggestion.payload = SuggestionDTO(id: suggestion.id!, type: "start", placeId: nil, proposedStartedAt: created, proposedEndedAt: nil, segmentId: nil, createdAt: created)
        try await suggestion.create(on: app.db)
        await scheduler.runOnce(now: created.addingTimeInterval(29 * 60))
        try await eq(try await notificationCount(app.db, a, kind: "pending_suggestions"), 0)
        await scheduler.runOnce(now: created.addingTimeInterval(31 * 60))
        await scheduler.runOnce(now: created.addingTimeInterval(32 * 60))
        await scheduler.runOnce(now: created.addingTimeInterval(5 * 3600))
        try await eq(try await notificationCount(app.db, a, kind: "pending_suggestions"), 1)
        await scheduler.runOnce(now: created.addingTimeInterval(6 * 3600 + 40 * 60))
        try await eq(try await notificationCount(app.db, a, kind: "pending_suggestions"), 2)
        suggestion.resolvedAt = created; try await suggestion.update(on: app.db)
        await scheduler.runOnce(now: created.addingTimeInterval(20 * 3600))
        try await eq(try await notificationCount(app.db, a, kind: "pending_suggestions"), 2)
        // document_submission: pending > 3 days, once per absence and local day.
        let absence = AbsenceRecord(); absence.id = UUID(); absence.accountId = owner; absence.kind = "sick"
        absence.startDate = "2026-10-01"; absence.endDate = "2026-10-02"; absence.halfDayStart = false; absence.halfDayEnd = false
        absence.status = "approved"; absence.documentStatus = "pending"; absence.version = 1
        absence.createdAt = notificationDate("2026-10-01T08:00:00Z"); absence.updatedAt = absence.createdAt
        try await absence.create(on: app.db)
        await scheduler.runOnce(now: notificationDate("2026-10-04T07:00:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "document_submission"), 0)
        await scheduler.runOnce(now: notificationDate("2026-10-04T09:00:00Z"))
        await scheduler.runOnce(now: notificationDate("2026-10-04T15:00:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "document_submission"), 1)
        await scheduler.runOnce(now: notificationDate("2026-10-05T09:00:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "document_submission"), 2)
        let doc = try await need(try await NotificationRecord.query(on: app.db).filter(\.$kind == "document_submission").first())
        XCTAssertTrue(doc.body.contains("01.10.2026")); try await eq(doc.title, "Unterlagen offen")
        absence.documentStatus = "submitted"; try await absence.update(on: app.db)
        await scheduler.runOnce(now: notificationDate("2026-10-06T09:00:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "document_submission"), 2)
        // Foreign data never leaks into another account.
        try await eq(try await notificationCount(app.db, b, kind: "document_submission"), 0)
        try await eq(try await notificationCount(app.db, b, kind: "pending_suggestions"), 0)
    }

    func scenarioReportGapAndDST(_ app: Application, _ auth: AuthService, _ runtime: NotificationRuntime, _ fake: FakePushService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let scheduler = runtime.scheduler
        let owner = try a.account.requireID()
        // Default zone Europe/Berlin, Friday 15:00 local. 2026-10-23 is CEST (13:00Z), 2026-10-30 is CET (14:00Z).
        await scheduler.runOnce(now: notificationDate("2026-10-23T12:59:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "report_gap"), 0)
        await scheduler.runOnce(now: notificationDate("2026-10-23T13:00:00Z"))
        await scheduler.runOnce(now: notificationDate("2026-10-23T13:05:00Z"))
        await scheduler.runOnce(now: notificationDate("2026-10-25T10:00:00Z"))   // still the same ISO week
        try await eq(try await notificationCount(app.db, a, kind: "report_gap"), 1)
        let first = try await need(try await NotificationRecord.query(on: app.db).filter(\.$kind == "report_gap").first())
        try await eq(first.dedupKey, "report_gap:2026-W43"); try await eq(first.title, "Berichtsheft-Erinnerung")
        await scheduler.runOnce(now: notificationDate("2026-10-30T13:30:00Z"))   // 14:30 CET, before 15:00
        try await eq(try await notificationCount(app.db, a, kind: "report_gap"), 1)
        await scheduler.runOnce(now: notificationDate("2026-10-30T14:00:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "report_gap"), 2)
        // An entry in the week, or a week marked done, suppresses the reminder.
        let entry = ReportEntryRecord(); entry.id = UUID(); entry.accountId = owner; entry.date = "2026-11-03"; entry.learningFieldName = "LF1"
        entry.durationSeconds = 3600; entry.notes = ""; entry.version = 1; entry.draft = false; entry.createdAt = Date(); entry.updatedAt = Date()
        try await entry.create(on: app.db)
        await scheduler.runOnce(now: notificationDate("2026-11-06T14:30:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "report_gap"), 2)
        let done = ReportWeekStatusRecord(); done.id = UUID(); done.accountId = owner; done.isoYear = 2026; done.isoWeek = 47; done.status = "done"
        try await done.create(on: app.db)
        await scheduler.runOnce(now: notificationDate("2026-11-20T14:30:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "report_gap"), 2)
        // Zone of the effective work model: New York, Friday 15:00 EST = 20:00Z (2026-11-27).
        var model = modelBody("2026-01-01"); model["timezone"] = "America/New_York"
        try await api(app, a, .POST, "work-models", model, .created)
        await scheduler.runOnce(now: notificationDate("2026-11-27T19:59:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "report_gap"), 2)
        await scheduler.runOnce(now: notificationDate("2026-11-27T20:00:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "report_gap"), 3)
        // Configured weekday/time: Monday 06:00 (week 49 begins 2026-11-30).
        _ = try await api(app, a, .PUT, "notifications/settings", ["categories": ["report_gap": ["inApp": true, "push": true, "weekday": 1, "time": "06:00"]]])
        await scheduler.runOnce(now: notificationDate("2026-11-30T10:59:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "report_gap"), 3)
        await scheduler.runOnce(now: notificationDate("2026-11-30T11:00:00Z"))
        try await eq(try await notificationCount(app.db, a, kind: "report_gap"), 4)
    }

    func scenarioTogglesAndQuietHours(_ app: Application, _ auth: AuthService, _ runtime: NotificationRuntime, _ fake: FakePushService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let scheduler = runtime.scheduler
        let owner = try a.account.requireID()
        let sub = TestSubscription(endpoint: fake.endpoint("quiet"))
        _ = try await api(app, a, .POST, "me/push-subscriptions", sub.body, .created)
        let all = ["running_timer", "pending_suggestions", "report_gap", "document_submission"]
        // Everything off: nothing is created.
        _ = try await api(app, a, .PUT, "notifications/settings", ["categories": Dictionary(uniqueKeysWithValues: all.map { ($0, ["inApp": false, "push": false] as [String: Any]) })])
        _ = try await seedSegment(app.db, a, start: notificationDate("2026-10-10T08:00:00Z"))
        await scheduler.runOnce(now: notificationDate("2026-10-12T08:00:00Z"))
        try await eq(try await notificationCount(app.db, a), 0)
        // In-app off, push on: hidden notification anchors the push.
        _ = try await api(app, a, .PUT, "notifications/settings", ["categories": ["running_timer": ["inApp": false, "push": true]], "quietStart": NSNull(), "quietEnd": NSNull()])
        await scheduler.runOnce(now: notificationDate("2026-10-12T08:00:00Z"))
        try await eq(try object(await api(app, a, .GET, "notifications"))["unreadCount"] as? Int, 0)
        try await eq((try object(await api(app, a, .GET, "notifications"))["items"] as? [[String: Any]])?.count, 0)
        try await eq(fake.received.count, 1)
        // In-app on, push off: visible, no push.
        let other = try await registered(auth, db: app.db, handle: "second", admin: a).0
        _ = try await seedSegment(app.db, other, start: notificationDate("2026-10-10T08:00:00Z"))
        _ = try await api(app, other, .PUT, "notifications/settings", ["categories": ["running_timer": ["inApp": true, "push": false]]])
        _ = try await api(app, other, .POST, "me/push-subscriptions", TestSubscription(endpoint: fake.endpoint("other")).body, .created)
        await scheduler.runOnce(now: notificationDate("2026-10-12T08:10:00Z"))
        try await eq(try await notificationCount(app.db, other, kind: "running_timer"), 1)
        try await eq(fake.received.filter { $0.path.hasSuffix("other") }.count, 0)
        // Quiet hours 22:00-07:00 Berlin: 2026-10-24T21:30Z is 23:30 CEST; clocks go back on 2026-10-25, so 07:00 CET is 06:00Z.
        fake.reset()
        _ = try await api(app, a, .PUT, "notifications/settings", ["categories": ["running_timer": ["inApp": true, "push": true]], "quietStart": "22:00", "quietEnd": "07:00"])
        try await endRunning(app.db, a)
        @Sendable func quietDeliveries() -> Int { fake.received.filter { $0.path.hasSuffix("quiet") }.count }
        let start = notificationDate("2026-10-24T08:00:00Z")
        let night = notificationDate("2026-10-24T21:30:00Z")
        _ = try await seedSegment(app.db, a, start: start)
        await scheduler.runOnce(now: night)
        let nightSegment = try await need(try await SegmentRecord.query(on: app.db).filter(\.$startedAt == start).first())
        let created = try await need(try await NotificationRecord.query(on: app.db).filter(\.$accountId == owner).filter(\.$dedupKey == "running_timer:" + nightSegment.requireID().uuidString).first())
        XCTAssertNil(created.deletedAt)   // in-app is immediate
        let outbox = try await need(try await PushOutboxRecord.query(on: app.db).filter(\.$notificationId == created.requireID()).first())
        try await eq(outbox.status, "deferred"); try await eq(outbox.nextAttemptAt, notificationDate("2026-10-25T06:00:00Z"))
        await scheduler.runOnce(now: notificationDate("2026-10-25T05:59:00Z"))
        try await eq(quietDeliveries(), 0)
        await scheduler.runOnce(now: notificationDate("2026-10-25T06:00:00Z"))
        try await eq(quietDeliveries(), 2)   // running_timer and the weekly report reminder
        try await eq(try await PushOutboxRecord.find(outbox.requireID(), on: app.db)?.status, "sent")
        await scheduler.runOnce(now: notificationDate("2026-10-25T06:05:00Z"))
        try await eq(quietDeliveries(), 2)   // not delivered twice
        // Outside the quiet window push goes out immediately.
        try await endRunning(app.db, a)
        let afternoon = notificationDate("2026-10-26T12:00:00Z")
        _ = try await seedSegment(app.db, a, start: afternoon.addingTimeInterval(-11 * 3600))
        await scheduler.runOnce(now: afternoon)
        try await eq(quietDeliveries(), 3)
    }

    func scenarioPushDelivery(_ app: Application, _ auth: AuthService, _ runtime: NotificationRuntime, _ fake: FakePushService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let scheduler = runtime.scheduler
        let owner = try a.account.requireID()
        let vapidKey = try await need(try object(await api(app, a, .GET, "push/config"))["vapidPublicKey"] as? String)
        _ = try await api(app, a, .PUT, "notifications/settings", ["categories": [String: Any](), "quietStart": NSNull(), "quietEnd": NSNull()])
        let sub = TestSubscription(endpoint: fake.endpoint("device"))
        let subID = try await need(try object(await api(app, a, .POST, "me/push-subscriptions", sub.body, .created))["id"] as? String)
        // A private place name and note exist in the data; they must not reach the push service.
        let place = try resourceID(await api(app, a, .POST, "places", ["name": "Geheimer Ort", "kind": "customer", "radiusMeters": 100, "latitude": 52.1, "longitude": 11.6, "automationMode": "direct"], .created))
        _ = place
        _ = try await seedSegment(app.db, a, start: notificationDate("2026-10-12T05:00:00Z"), note: "Vertrauliche Notiz")
        let now = notificationDate("2026-10-12T17:00:00Z")
        await scheduler.runOnce(now: now)
        try await eq(fake.received.count, 1)
        let request = try await need(fake.received.first)
        try await eq(request.headers["content-encoding"], "aes128gcm"); try await eq(request.headers["ttl"], "86400"); try await eq(request.headers["urgency"], "normal")
        XCTAssertLessThanOrEqual(request.headers["topic"]?.count ?? 99, 32); XCTAssertNotNil(request.headers["topic"])
        let authorization = try await need(request.headers["authorization"])
        XCTAssertTrue(authorization.hasSuffix(", k=" + vapidKey))
        let jwt = authorization.dropFirst("vapid t=".count).components(separatedBy: ", k=")[0].split(separator: ".").map(String.init)
        let publicKey = try P256.Signing.PublicKey(x963Representation: XCTUnwrap(Data(base64URL: vapidKey)))
        XCTAssertTrue(publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(Data(base64URL: jwt[2]))), for: Data((jwt[0] + "." + jwt[1]).utf8)))
        let claims = try await need(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64URL: jwt[1]))) as? [String: Any])
        try await eq((claims["aud"] as? String)?.hasPrefix("http://127.0.0.1:"), true); try await eq(claims["sub"] as? String, "mailto:admin@example.test")
        let plain = try WebPushCrypto.decrypt(request.body, userAgentKey: sub.key, authSecret: sub.auth)
        let text = String(decoding: plain, as: UTF8.self)
        let payload = try await need(JSONSerialization.jsonObject(with: plain) as? [String: String])
        try await eq(Set(payload.keys), ["title", "body", "url", "tag", "kind"])
        try await eq(payload["title"], "Timer läuft noch"); try await eq(payload["kind"], "running_timer"); try await eq(payload["url"], "/")
        for secret in ["Geheimer", "Vertrauliche", "07:", "Uhr", "Std."] { XCTAssertFalse(text.contains(secret), secret) }
        // The in-app text is detailed, the push text is not.
        let inApp = try await need(try await NotificationRecord.query(on: app.db).first()); XCTAssertTrue(inApp.body.contains("Uhr"))
        let sentSub = try await PushSubscriptionRecord.find(UUID(uuidString: subID), on: app.db)
        XCTAssertNotNil(sentSub?.lastSuccessAt); try await eq(sentSub?.failureCount, 0)
        // Dedup: another run neither creates nor sends.
        await scheduler.runOnce(now: now.addingTimeInterval(60))
        try await eq(fake.received.count, 1); try await eq(try await notificationCount(app.db, a), 1)

        // 404 and 410 remove the subscription.
        for status in [404, 410] {
            fake.reset(); fake.script([status])
            let victim = TestSubscription(endpoint: fake.endpoint("gone\(status)"))
            let victimID = try await need(try object(await api(app, a, .POST, "me/push-subscriptions", victim.body, .created))["id"] as? String)
            _ = try await seedNotification(app.db, a, key: "gone\(status)", at: now)
            let note = try await need(try await NotificationRecord.query(on: app.db).filter(\.$dedupKey == "gone\(status)").first())
            let item = PushOutboxRecord(); item.notificationId = try note.requireID(); item.subscriptionId = UUID(uuidString: victimID)!
            item.status = "pending"; item.attempts = 0; item.nextAttemptAt = now; item.createdAt = now
            try await item.create(on: app.db)
            await scheduler.runOnce(now: now.addingTimeInterval(120))
            try await eq(try await PushSubscriptionRecord.find(UUID(uuidString: victimID), on: app.db) == nil, true)
            try await eq(try await PushOutboxRecord.query(on: app.db).filter(\.$subscriptionId == UUID(uuidString: victimID)!).count(), 0)
        }
        // 500 retries with backoff (60 s, 300 s), then the message is dropped as failed after 3 attempts; 429 counts the same.
        try await PushOutboxRecord.query(on: app.db).delete()
        fake.reset(); fake.script([500, 429, 503])
        let target = try await need(try await NotificationRecord.query(on: app.db).first())
        let retry = PushOutboxRecord(); retry.notificationId = try target.requireID(); retry.subscriptionId = UUID(uuidString: subID)!
        retry.status = "pending"; retry.attempts = 0; retry.nextAttemptAt = now; retry.createdAt = now
        try await retry.create(on: app.db)
        let base = now.addingTimeInterval(7200)
        await scheduler.runOnce(now: base)
        try await eq(fake.received.count, 1)
        var row = try await need(try await PushOutboxRecord.find(retry.requireID(), on: app.db))
        try await eq(row.status, "pending"); try await eq(row.attempts, 1); try await eq(row.nextAttemptAt, base.addingTimeInterval(60)); try await eq(row.errorCode, "http_500")
        await scheduler.runOnce(now: base.addingTimeInterval(30))
        try await eq(fake.received.count, 1)   // backoff not elapsed
        await scheduler.runOnce(now: base.addingTimeInterval(61))
        row = try await need(try await PushOutboxRecord.find(retry.requireID(), on: app.db))
        try await eq(row.attempts, 2); try await eq(row.status, "pending"); try await eq(row.nextAttemptAt, base.addingTimeInterval(61 + 300))
        await scheduler.runOnce(now: base.addingTimeInterval(400))
        row = try await need(try await PushOutboxRecord.find(retry.requireID(), on: app.db))
        try await eq(row.attempts, 3); try await eq(row.status, "failed"); try await eq(row.errorCode, "http_503")
        await scheduler.runOnce(now: base.addingTimeInterval(4000))
        try await eq(fake.received.count, 3)
        try await eq(try await PushSubscriptionRecord.find(UUID(uuidString: subID), on: app.db)?.failureCount, 3)
        // Other client errors fail immediately without retry.
        fake.reset(); fake.script([400])
        retry.status = "pending"; retry.attempts = 0; retry.nextAttemptAt = base; try await retry.update(on: app.db)
        await scheduler.runOnce(now: base.addingTimeInterval(5000))
        row = try await need(try await PushOutboxRecord.find(retry.requireID(), on: app.db))
        try await eq(row.status, "failed"); try await eq(row.errorCode, "http_400"); try await eq(fake.received.count, 1)
        _ = owner
    }

    func scenarioLeaseAndRuntime(_ app: Application, _ auth: AuthService, _ runtime: NotificationRuntime, _ fake: FakePushService) async throws {
        let now = notificationDate("2026-10-12T10:00:00Z")
        let other = NotificationRuntime(scheduler: runtime.scheduler, service: runtime.service, transport: HTTPPushTransport(group: app.eventLoopGroup), interval: 60)
        XCTAssertNotEqual(other.holder, runtime.holder)
        let first = await runtime.tick(now: now)
        let second = await other.tick(now: now.addingTimeInterval(1))
        try await eq(first, true); try await eq(second, false)
        try await eq(await runtime.tick(now: now.addingTimeInterval(30)), true)   // renewing keeps the lease
        try await eq(await other.tick(now: now.addingTimeInterval(60)), false)
        try await eq(await other.tick(now: now.addingTimeInterval(30 + 91)), true)   // expired lease can be taken over
        try await eq(await runtime.tick(now: now.addingTimeInterval(30 + 92)), false)
        try await eq(try await JobLeaseRecord.query(on: app.db).count(), 1)
        // Concurrent first acquisition on a fresh name: exactly one winner.
        try await JobLeaseRecord.query(on: app.db).delete()
        let db = app.db
        let winners = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<6 { group.addTask { (try? await JobLease.acquire("race", holder: "holder-\(index)", now: now, on: db)) ?? false } }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        try await eq(winners, 1)
        try await JobLease.release("race", holder: "holder-x", on: app.db)   // foreign holder cannot release
        try await eq(try await JobLeaseRecord.query(on: app.db).filter(\.$name == "race").first()?.expiresAt, now.addingTimeInterval(90))
        await other.stop()
    }

    var notificationScenarios: [(String, NotificationScenario)] {
        [("settings", scenarioNotificationSettings), ("list", scenarioNotificationList), ("subscriptions", scenarioPushSubscriptions),
         ("reminders", scenarioReminders), ("reportGap", scenarioReportGapAndDST), ("quiet", scenarioTogglesAndQuietHours),
         ("delivery", scenarioPushDelivery), ("lease", scenarioLeaseAndRuntime)]
    }

    func runNotificationScenarios(database: [String: String]) async throws {
        let fake = try await FakePushService()
        do {
            for (name, scenario) in notificationScenarios {
                fake.reset()
                do {
                    try await notificationApp(env: vapidEnvironment(), database: database, transport: HTTPPushTransport(group: .singletonMultiThreadedEventLoopGroup)) { app, auth, runtime in
                        try await scenario(app, auth, runtime, fake)
                    }
                } catch { XCTFail("scenario \(name) failed: \(error)"); throw error }
            }
            try await notificationApp(env: ["NOTIFICATIONS_ENABLED": "false"], database: database) { app, auth, runtime in
                try await self.scenarioPushUnavailable(app, auth, runtime, fake)
            }
        } catch { try? await fake.shutdown(); throw error }
        try await fake.shutdown()
    }

    func testNotificationsSQLite() async throws { try await runNotificationScenarios(database: [:]) }

    func testNotificationsMariaDB() async throws { try await runNotificationScenarios(database: try mariaDBEnvironment()) }

    func testBackgroundRunnerLifecycle() async throws {
        // NOTIFICATIONS_ENABLED decides whether the loop starts.
        let off = NotificationOptions(environment: ["NOTIFICATIONS_ENABLED": "false"])
        XCTAssertFalse(off.runnerEnabled(testing: false)); XCTAssertFalse(off.runnerEnabled(testing: true))
        XCTAssertTrue(NotificationOptions(environment: [:]).runnerEnabled(testing: false)); XCTAssertFalse(NotificationOptions(environment: [:]).runnerEnabled(testing: true))
        XCTAssertTrue(NotificationOptions(environment: ["NOTIFICATIONS_ENABLED": "true"]).runnerEnabled(testing: true))
        // Enabled: the loop ticks on its own and stops with the application.
        var env = vapidEnvironment(); env["NOTIFICATIONS_ENABLED"] = "true"
        try await notificationApp(env: env, interval: 0.1) { app, auth, runtime in
            let (a, _) = try await self.registered(auth, db: app.db)
            _ = try await self.seedSegment(app.db, a, start: Date().addingTimeInterval(-11 * 3600))
            try await app.asyncBoot()
            var found = 0
            for _ in 0..<50 where found == 0 {
                try await Task.sleep(nanoseconds: 100_000_000)
                found = try await self.notificationCount(app.db, a, kind: "running_timer")
            }
            try await self.eq(found, 1)
        }
        // Disabled: nothing runs even when due.
        try await notificationApp(env: ["NOTIFICATIONS_ENABLED": "false"], interval: 0.1) { app, auth, runtime in
            let (a, _) = try await self.registered(auth, db: app.db)
            _ = try await self.seedSegment(app.db, a, start: Date().addingTimeInterval(-11 * 3600))
            try await app.asyncBoot()
            try await Task.sleep(nanoseconds: 400_000_000)
            try await self.eq(try await self.notificationCount(app.db, a), 0)
            try await self.eq(try await JobLeaseRecord.query(on: app.db).count(), 0)
        }
    }
}

private extension HTTPHeaders {
    func with(contentType: HTTPMediaType) -> HTTPHeaders { var copy = self; copy.contentType = contentType; return copy }
}
