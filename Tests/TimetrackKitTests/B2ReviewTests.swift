import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// B2: review items. (a) learning field name clash is 409, never 500; (b) pushsubscriptionchange; (c) PUSH_ALLOWED_HOSTS suggestion.

extension AuthTests {
    // MARK: (a) learning fields

    func learningFieldRace(database: [String: String]) async throws {
        try await withApp(environment: database) { app, auth in
            let (context, _) = try await self.registered(auth, db: app.db)
            let name = "Netzwerke \(UUID().uuidString.prefix(6))"
            let body = try JSONSerialization.data(withJSONObject: ["name": name])
            var head = self.headers(context); head.contentType = .json
            struct Sender: @unchecked Sendable {
                let tester: any XCTApplicationTester; let head: HTTPHeaders; let body: Data
                func send() async throws -> HTTPStatus {
                    try await tester.sendRequest(.POST, "/api/v1/reports/learning-fields", headers: head, body: ByteBuffer(data: body)).status
                }
            }
            let sender = Sender(tester: try app.testable(), head: head, body: body)
            let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for _ in 0..<12 {
                    group.addTask { try await sender.send() }
                }
                return try await group.reduce(into: [HTTPStatus]()) { $0.append($1) }
            }
            XCTAssertEqual(statuses.filter { $0 == .created }.count, 1, "\(statuses)")
            XCTAssertEqual(statuses.filter { $0 == .conflict }.count, 11, "\(statuses)")
            XCTAssertFalse(statuses.contains(.internalServerError))
            try await self.eq(try await LearningFieldRecord.query(on: app.db).count(), 1)

            // A unique-key violation that slips past the pre-check maps to the same 409 (here: forced insert of the same key).
            let clash = LearningFieldRecord()
            clash.accountId = try context.account.requireID(); clash.name = name; clash.nameKey = name.lowercased(); clash.sortOrder = 0; clash.createdAt = Date()
            do { try await ReportErrors.mappingNameClash { try await clash.create(on: app.db) }; XCTFail("expected 409") }
            catch let error as APIError { XCTAssertEqual(error.code, "learning_field_exists"); XCTAssertEqual(error.status, .conflict) }
            // Other errors pass through unchanged.
            struct Other: Error {}
            do { try await ReportErrors.mappingNameClash { throw Other() } } catch { XCTAssertTrue(error is Other) }
        }
    }
    func testLearningFieldRaceSQLite() async throws { try await learningFieldRace(database: [:]) }
    func testLearningFieldRaceMariaDB() async throws { try await learningFieldRace(database: try mariaDBEnvironment()) }

    // MARK: (b) pushsubscriptionchange

    func pushReplace(database: [String: String]) async throws {
        try await notificationApp(env: vapidEnvironment(), database: database) { app, auth, _ in
            let (owner, _) = try await self.registered(auth, db: app.db)
            let (other, _) = try await self.registered(auth, db: app.db, handle: "second", admin: owner)
            let old = TestSubscription(endpoint: "https://fcm.googleapis.com/fcm/send/b2-old")
            let created = try self.object(await self.api(app, owner, .POST, "me/push-subscriptions", old.body, .created))
            let id = try XCTUnwrap(created["id"] as? String)
            let subscriptionId = try XCTUnwrap(UUID(uuidString: id))
            // A queued push for the old subscription must follow the replacement.
            let notification = try await self.seedNotification(app.db, owner, key: "b2", at: Date())
            let outbox = PushOutboxRecord(); outbox.notificationId = notification; outbox.subscriptionId = subscriptionId; outbox.status = "pending"
            outbox.attempts = 0; outbox.nextAttemptAt = Date(); outbox.createdAt = Date(); try await outbox.create(on: app.db)

            // 1. Replacement: same row id, new endpoint and keys, outbox kept, one row only.
            let fresh = TestSubscription(endpoint: "https://updates.push.services.mozilla.com/wpush/v2/b2-new")
            var body = fresh.body; body["previousEndpoint"] = old.endpoint
            let replaced = try self.object(await self.api(app, owner, .POST, "me/push-subscriptions/replace", body, .ok))
            try await self.eq(replaced["id"] as? String, id)
            try await self.eq(replaced["host"] as? String, "updates.push.services.mozilla.com")
            let stored = try await PushSubscriptionRecord.query(on: app.db).all()
            try await self.eq(stored.count, 1)
            try await self.eq(stored[0].endpoint, fresh.endpoint); try await self.eq(stored[0].endpointHash, Secrets.hash(fresh.endpoint))
            try await self.eq(stored[0].p256dh, fresh.key.publicKey.x963Representation.base64URL)
            try await self.eq(try await PushOutboxRecord.query(on: app.db).filter(\.$subscriptionId == subscriptionId).count(), 1)

            // 2. Retrying the same event (old endpoint no longer stored, new one is) is harmless: 200, still one row.
            let retried = try self.object(await self.api(app, owner, .POST, "me/push-subscriptions/replace", body, .ok))
            try await self.eq(retried["id"] as? String, id)
            try await self.eq(try await PushSubscriptionRecord.query(on: app.db).count(), 1)

            // 3. The new endpoint is already registered under another row (second tab): that row wins, the stale one goes.
            let tab = TestSubscription(endpoint: "https://fcm.googleapis.com/fcm/send/b2-tab")
            let tabCreated = try self.object(await self.api(app, owner, .POST, "me/push-subscriptions", tab.body, .created))
            let tabId = try XCTUnwrap(tabCreated["id"] as? String)
            let next = TestSubscription(endpoint: tab.endpoint)
            var merge = next.body; merge["previousEndpoint"] = fresh.endpoint
            let merged = try self.object(await self.api(app, owner, .POST, "me/push-subscriptions/replace", merge, .ok))
            try await self.eq(merged["id"] as? String, tabId)
            try await self.eq(try await PushSubscriptionRecord.query(on: app.db).count(), 1)
            try await self.eq(try await PushOutboxRecord.query(on: app.db).count(), 0)   // the outbox of the removed row went with it
            try await self.eq(try await PushSubscriptionRecord.query(on: app.db).first()?.p256dh ?? "", next.key.publicKey.x963Representation.base64URL)

            // 4. Unknown or missing previous endpoint registers a new subscription (201).
            let third = TestSubscription(endpoint: "https://web.push.apple.com/b2-third")
            var unknown = third.body; unknown["previousEndpoint"] = "https://fcm.googleapis.com/fcm/send/never-stored"
            _ = try await self.api(app, owner, .POST, "me/push-subscriptions/replace", unknown, .created)
            let fourth = TestSubscription(endpoint: "https://fcm.googleapis.com/fcm/send/b2-fourth")
            _ = try await self.api(app, owner, .POST, "me/push-subscriptions/replace", fourth.body, .created)
            try await self.eq(try await PushSubscriptionRecord.query(on: app.db).count(), 3)

            // 5. Other accounts' subscriptions are never touched, even when their endpoint is given as previous endpoint.
            let foreign = TestSubscription(endpoint: "https://fcm.googleapis.com/fcm/send/b2-foreign")
            _ = try await self.api(app, other, .POST, "me/push-subscriptions", foreign.body, .created)
            let hijack = TestSubscription(endpoint: "https://fcm.googleapis.com/fcm/send/b2-hijack")
            var steal = hijack.body; steal["previousEndpoint"] = foreign.endpoint
            _ = try await self.api(app, owner, .POST, "me/push-subscriptions/replace", steal, .created)
            let otherId = try other.account.requireID(), ownerId = try owner.account.requireID()
            let foreignRows = try await PushSubscriptionRecord.query(on: app.db).filter(\.$accountId == otherId).all()
            try await self.eq(foreignRows.count, 1); try await self.eq(foreignRows[0].endpoint, foreign.endpoint)
            try await self.eq(foreignRows[0].p256dh, foreign.key.publicKey.x963Representation.base64URL)

            // 6. Validation failures leave everything unchanged (all-or-nothing).
            let before = try await PushSubscriptionRecord.query(on: app.db).filter(\.$accountId == ownerId).all().map(\.endpointHash).sorted()
            let goodKeys = fourth.body["keys"] as Any
            let badBodies: [[String: Any]] = [
                ["endpoint": "https://evil.example/x", "keys": goodKeys, "previousEndpoint": fourth.endpoint],
                ["endpoint": "http://fcm.googleapis.com/x", "keys": goodKeys, "previousEndpoint": fourth.endpoint],
                ["endpoint": "https://fcm.googleapis.com/x", "keys": ["p256dh": "short", "auth": "x"], "previousEndpoint": fourth.endpoint],
                ["endpoint": "https://fcm.googleapis.com/x", "keys": goodKeys, "previousEndpoint": ""],
            ]
            for bad in badBodies { _ = try await self.api(app, owner, .POST, "me/push-subscriptions/replace", bad, .badRequest) }
            _ = try await self.timeRequest(app, owner, .POST, "me/push-subscriptions/replace", nil, status: .badRequest)
            let after = try await PushSubscriptionRecord.query(on: app.db).filter(\.$accountId == ownerId).all().map(\.endpointHash).sorted()
            try await self.eq(after, before)

            // 7. Subscription limit still applies to registering; swapping an existing row is not limited.
            for index in 0..<6 {
                _ = try await self.api(app, owner, .POST, "me/push-subscriptions", TestSubscription(endpoint: "https://fcm.googleapis.com/fcm/send/fill-\(index)").body, .created)
            }
            try await self.eq(try await PushSubscriptionRecord.query(on: app.db).filter(\.$accountId == ownerId).count(), 10)
            var full = TestSubscription(endpoint: "https://fcm.googleapis.com/fcm/send/over").body; full["previousEndpoint"] = "https://fcm.googleapis.com/fcm/send/none"
            _ = try await self.api(app, owner, .POST, "me/push-subscriptions/replace", full, .conflict)
            var swap = TestSubscription(endpoint: "https://fcm.googleapis.com/fcm/send/swapped").body; swap["previousEndpoint"] = "https://fcm.googleapis.com/fcm/send/fill-0"
            _ = try await self.api(app, owner, .POST, "me/push-subscriptions/replace", swap, .ok)

            // 8. Authentication and CSRF as for the other write endpoints.
            _ = try await self.timeRequest(app, nil, .POST, "me/push-subscriptions/replace", fourth.body, status: .unauthorized)
            var head = self.headers(owner, csrf: false); head.contentType = .json
            let withoutCSRF = try await app.testable().sendRequest(.POST, "/api/v1/me/push-subscriptions/replace", headers: head,
                                                                    body: ByteBuffer(data: JSONSerialization.data(withJSONObject: fourth.body)))
            XCTAssertEqual(withoutCSRF.status, .forbidden)
        }
    }
    func testPushSubscriptionReplaceSQLite() async throws { try await pushReplace(database: [:]) }
    func testPushSubscriptionReplaceMariaDB() async throws { try await pushReplace(database: try mariaDBEnvironment()) }

    func testPushSubscriptionReplaceRequiresPush() async throws {
        try await notificationApp(env: ["NOTIFICATIONS_ENABLED": "false"]) { app, auth, _ in
            let (owner, _) = try await self.registered(auth, db: app.db)
            _ = try await self.api(app, owner, .POST, "me/push-subscriptions/replace", TestSubscription(endpoint: "https://fcm.googleapis.com/x").body, .notImplemented)
        }
    }

    // MARK: (c) PUSH_ALLOWED_HOSTS

    func testDocumentedPushHostsAcceptRealServicesOnly() throws {
        var policy = PushEndpointPolicy()
        policy.allowedHosts = PushEndpointPolicy.documentedAllowedHosts
        let accepted = [
            "https://fcm.googleapis.com/fcm/send/dQw4w9WgXcQ:APA91bH",
            "https://updates.push.services.mozilla.com/wpush/v2/gAAAAABk",
            "https://web.push.apple.com/QDB4aZ",
            "https://db5p.notify.windows.com/?token=AwYAAAB",
            "https://wns2-par02p.notify.windows.com/w/?token=BQYAAAB",
            "https://fcm.googleapis.com:443/fcm/send/x",
        ]
        for url in accepted { XCTAssertNotNil(policy.endpoint(url), url) }
        let rejected = [
            "http://fcm.googleapis.com/fcm/send/x", "https://fcm.googleapis.com:8443/x", "https://notify.windows.com/x",
            "https://fcm.googleapis.com.evil.example/x", "https://evil-fcm.googleapis.com/x", "https://evilnotify.windows.com/x",
            "https://x.notify.windows.com.evil.example/x", "https://android.googleapis.com/gcm/send/x", "https://push.apple.com/x",
            "https://autopush.prod.mozaws.net/x", "https://127.0.0.1/x", "https://user:pw@fcm.googleapis.com/x", "https://localhost/x",
        ]
        for url in rejected { XCTAssertNil(policy.endpoint(url), url) }
        // The documented value is a restriction of the ADR-0011 defaults, never a widening.
        let defaults = PushEndpointPolicy()
        for url in accepted { XCTAssertNotNil(defaults.endpoint(url), url) }
        XCTAssertEqual(defaults.allowedHosts, ["fcm.googleapis.com", "*.push.services.mozilla.com", "*.notify.windows.com", "web.push.apple.com", "*.push.apple.com"])
    }

    func testDocumentedPushHostsViaEnvironment() async throws {
        var environment = vapidEnvironment()
        environment["PUSH_ALLOWED_HOSTS"] = PushEndpointPolicy.documentedAllowedHosts.joined(separator: ",")
        try await notificationApp(env: environment) { app, auth, _ in
            let (owner, _) = try await self.registered(auth, db: app.db)
            for url in ["https://fcm.googleapis.com/fcm/send/a", "https://updates.push.services.mozilla.com/wpush/v2/a", "https://web.push.apple.com/a", "https://abc.notify.windows.com/a"] {
                _ = try await self.api(app, owner, .POST, "me/push-subscriptions", TestSubscription(endpoint: url).body, .created)
            }
            // Restricted below the defaults: another Apple host is no longer accepted.
            _ = try await self.api(app, owner, .POST, "me/push-subscriptions", TestSubscription(endpoint: "https://api.push.apple.com/a").body, .badRequest)
            _ = try await self.api(app, owner, .POST, "me/push-subscriptions", TestSubscription(endpoint: "https://other.example/a").body, .badRequest)
        }
    }

    func testEinrichtungDocumentsTheSuggestedPushHosts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("EINRICHTUNG.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("PUSH_ALLOWED_HOSTS=" + PushEndpointPolicy.documentedAllowedHosts.joined(separator: ",")),
                      "EINRICHTUNG.md must contain the documented PUSH_ALLOWED_HOSTS value")
    }
}

extension AuthTests {
    /// Regression for the MariaDB snapshot-isolation failure ("Record has changed since last read"): parallel requests of ONE
    /// session used to fail with HTTP 500 in nearly every round (see docs/handoffs/B2.md).
    func testParallelRequestsOfOneSessionNeverFailMariaDB() async throws {
        try await withApp(environment: try mariaDBEnvironment()) { app, auth in
            let (context, _) = try await self.registered(auth, db: app.db)
            struct Sender: @unchecked Sendable {
                let tester: any XCTApplicationTester; let head: HTTPHeaders
                func send() async throws -> HTTPStatus { try await tester.sendRequest(.GET, "/api/v1/reports/learning-fields", headers: head).status }
            }
            let sender = Sender(tester: try app.testable(), head: self.headers(context))
            for round in 0..<10 {
                let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                    for _ in 0..<24 { group.addTask { try await sender.send() } }
                    return try await group.reduce(into: [HTTPStatus]()) { $0.append($1) }
                }
                XCTAssertEqual(Set(statuses), [.ok], "round \(round): \(statuses)")
            }
        }
    }
}
