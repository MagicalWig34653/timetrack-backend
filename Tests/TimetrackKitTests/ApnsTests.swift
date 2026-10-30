import Foundation
import Fluent
import XCTVapor
import Crypto
@testable import TimetrackKit

// P14: server-side APNs push (device registration, provider token, payloads, delivery, cleanup). No real APNs connection is made.

final class FakeApnsTransport: ApnsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ApnsRequest] = []
    private var _responses: [ApnsResponse] = []
    private var _fallback = ApnsResponse(status: 200, reason: nil)
    var requests: [ApnsRequest] { lock.withLock { _requests } }
    func script(_ responses: [ApnsResponse], then fallback: ApnsResponse = ApnsResponse(status: 200, reason: nil)) {
        lock.withLock { _responses = responses; _fallback = fallback }
    }
    func send(_ request: ApnsRequest) async throws -> ApnsResponse {
        lock.withLock { _requests.append(request); return _responses.isEmpty ? _fallback : _responses.removeFirst() }
    }
    func shutdown() async {}
}

private let testBundle = "com.example.timetrack"
private let testToken = String(repeating: "ab12", count: 16)   // 64 hex characters

private func apnsEnvironment(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) -> [String: String] {
    ["APNS_PRIVATE_KEY": key.pemRepresentation, "APNS_KEY_ID": "ABC123DEFG", "APNS_TEAM_ID": "ABCDE12345", "APNS_BUNDLE_IDS": testBundle + ", com.example.timetrack.watch",
     "NOTIFICATIONS_ENABLED": "false"]
}
private func deviceBody(_ token: String = testToken, platform: String = "ios", environment: String = "sandbox", bundle: String = testBundle, label: String? = "iPhone") -> [String: Any] {
    var body: [String: Any] = ["token": token, "platform": platform, "environment": environment, "appBundleId": bundle]
    if let label { body["label"] = label }
    return body
}

final class ApnsUnitTests: XCTestCase {
    func testConfigurationValidation() {
        let good = apnsEnvironment()
        XCTAssertNotNil(ApnsConfiguration(environment: good))
        XCTAssertEqual(ApnsConfiguration(environment: good)?.bundleIds, [testBundle, "com.example.timetrack.watch"])
        // Single-line secret with literal \n sequences.
        var escaped = good; escaped["APNS_PRIVATE_KEY"] = good["APNS_PRIVATE_KEY"]!.replacingOccurrences(of: "\n", with: "\\n")
        XCTAssertNotNil(ApnsConfiguration(environment: escaped))
        for name in ["APNS_PRIVATE_KEY", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_BUNDLE_IDS"] {
            var broken = good; broken[name] = nil
            XCTAssertNil(ApnsConfiguration(environment: broken), name)
            broken[name] = ""
            XCTAssertNil(ApnsConfiguration(environment: broken), name)
        }
        for (name, value) in [("APNS_KEY_ID", "short"), ("APNS_TEAM_ID", "abcde12345"), ("APNS_PRIVATE_KEY", "not a key"), ("APNS_BUNDLE_IDS", "bad bundle")] {
            var broken = good; broken[name] = value
            XCTAssertNil(ApnsConfiguration(environment: broken), name)
        }
        XCTAssertFalse(ApnsConfiguration.anyConfigured([:]))
        XCTAssertFalse(ApnsConfiguration.anyConfigured(["APNS_KEY_ID": ""]))
        XCTAssertTrue(ApnsConfiguration.anyConfigured(["APNS_KEY_ID": "ABC123DEFG"]))
    }

    func testProviderTokenFormatSignatureAndRefresh() throws {
        let key = P256.Signing.PrivateKey()
        let configuration = try XCTUnwrap(ApnsConfiguration(environment: apnsEnvironment(key: key)))
        let provider = ApnsTokenProvider(configuration: configuration)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let token = provider.token(now: start)
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(Data(base64URL: parts[0]))) as? [String: Any])
        XCTAssertEqual(header["alg"] as? String, "ES256"); XCTAssertEqual(header["kid"] as? String, "ABC123DEFG"); XCTAssertEqual(header.count, 2)
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(Data(base64URL: parts[1]))) as? [String: Any])
        XCTAssertEqual(claims["iss"] as? String, "ABCDE12345"); XCTAssertEqual(claims["iat"] as? Int, 1_800_000_000); XCTAssertEqual(claims.count, 2)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try XCTUnwrap(Data(base64URL: parts[2])))
        XCTAssertEqual(try XCTUnwrap(Data(base64URL: parts[2])).count, 64)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
        // Cached for 50 minutes, refreshed before the one-hour limit, and after an invalidation.
        XCTAssertEqual(provider.token(now: start.addingTimeInterval(49 * 60)), token)
        let refreshed = provider.token(now: start.addingTimeInterval(51 * 60))
        XCTAssertNotEqual(refreshed, token)
        XCTAssertLessThan(ApnsTokenProvider.reuse, 3600)
        provider.invalidate()
        XCTAssertNotEqual(provider.token(now: start.addingTimeInterval(52 * 60)), refreshed)
    }

    func testPayloads() throws {
        let id = UUID()
        let alert = ApnsMessage.alert(PushMessage(kind: "running_timer", url: "/", tag: "running_timer:" + UUID().uuidString), notificationId: id)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: alert.payload) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "running_timer"); XCTAssertEqual(object["url"] as? String, "/"); XCTAssertEqual(object["notificationId"] as? String, id.uuidString)
        let aps = try XCTUnwrap(object["aps"] as? [String: Any])
        XCTAssertEqual((aps["alert"] as? [String: String])?["title"], "Timer läuft noch")
        XCTAssertEqual((aps["alert"] as? [String: String])?["body"], "Öffne Timetrack für Details.")
        XCTAssertEqual(aps["thread-id"] as? String, "running_timer"); XCTAssertNil(aps["content-available"])
        XCTAssertEqual(alert.pushType, "alert"); XCTAssertEqual(alert.priority, 10)
        XCTAssertLessThanOrEqual(alert.collapseId.utf8.count, 64); XCTAssertFalse(alert.collapseId.isEmpty)
        XCTAssertLessThan(alert.payload.count, 4096)
        let silent = ApnsMessage.silentSync
        XCTAssertEqual(String(decoding: silent.payload, as: UTF8.self), #"{"aps":{"content-available":1},"kind":"sync"}"#)
        XCTAssertEqual(silent.pushType, "background"); XCTAssertEqual(silent.priority, 5); XCTAssertEqual(silent.collapseId, "sync")
        // Unknown kinds fall back to the product name.
        let system = try XCTUnwrap(JSONSerialization.jsonObject(with: ApnsMessage.alert(PushMessage(kind: "other", url: "/", tag: "t"), notificationId: nil).payload) as? [String: Any])
        XCTAssertEqual((((system["aps"] as? [String: Any])?["alert"]) as? [String: String])?["title"], "Timetrack")
        XCTAssertNil(system["notificationId"])
    }

    func testHostsAndTokenRules() {
        XCTAssertEqual(HTTP2ApnsTransport.host("sandbox"), "api.sandbox.push.apple.com")
        XCTAssertEqual(HTTP2ApnsTransport.host("production"), "api.push.apple.com")
        XCTAssertEqual(ApnsDeviceRules.normalizedToken(testToken.uppercased()), testToken)
        for bad in ["", "xyz", String(repeating: "g", count: 64), String(repeating: "a", count: 63), String(repeating: "a", count: 202), testToken + "\n"] {
            XCTAssertNil(ApnsDeviceRules.normalizedToken(bad), bad)
        }
    }

    func testLogScrubbingCoversTokensKeysAndJWTs() throws {
        let configuration = try XCTUnwrap(ApnsConfiguration(environment: apnsEnvironment()))
        let jwt = ApnsTokenProvider.make(configuration, now: Date())
        let pem = configuration.privateKey.pemRepresentation
        let line = "push failed token=\(testToken) bearer \(jwt) key=\(pem) end GET /api/v1/time/timer"
        let scrubbed = TriggerTokenScrubber.scrub(line)
        XCTAssertFalse(scrubbed.contains(testToken)); XCTAssertFalse(scrubbed.contains(jwt)); XCTAssertFalse(scrubbed.contains("PRIVATE KEY"))
        XCTAssertFalse(scrubbed.contains(String(pem.split(separator: "\n")[1])))
        XCTAssertTrue(scrubbed.contains("GET /api/v1/time/timer"))
        XCTAssertEqual(TriggerTokenScrubber.scrub("short abcdef0123 text"), "short abcdef0123 text")
    }
}

extension AuthTests {
    func present<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws {
        let resolved = try await value(); XCTAssertNotNil(resolved, file: file, line: line)
    }
    func absent<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws {
        let resolved = try await value(); XCTAssertNil(resolved, file: file, line: line)
    }
    func apnsApp(env: [String: String], transport: FakeApnsTransport = FakeApnsTransport(), database: [String: String] = [:],
                 syncTiming: ApnsSyncCoordinator.Timing = .init(),
                 _ run: (Application, AuthService, NotificationRuntime, FakeApnsTransport) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        let config = try Configuration(environment: ["SQLITE_PATH": ":memory:"].merging(database) { _, new in new })
        do {
            var options = NotificationOptions(environment: env)
            options.apnsTransport = transport
            options.syncTiming = syncTiming
            try await configure(app, configuration: config, notifications: options)
            try await app.autoMigrate()
            try await run(app, AuthService(configuration: config, mailSender: nil), try XCTUnwrap(app.notificationRuntime), transport)
            try await app.autoRevert()
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }

    func testApnsDisabledWhenUnconfigured() async throws {
        try await apnsApp(env: ["NOTIFICATIONS_ENABLED": "false"]) { app, auth, runtime, transport in
            let (a, _) = try await registered(auth, db: app.db)
            XCTAssertNil(runtime.service.apns); XCTAssertNil(runtime.scheduler.apns)
            let config = try object(await api(app, a, .GET, "push/config"))
            XCTAssertEqual(config["apnsAvailable"] as? Bool, false)
            let response = try await api(app, a, .POST, "me/push-devices", deviceBody(), .notImplemented)
            XCTAssertEqual(try errorCode(response), "push_unavailable")
            _ = try await api(app, a, .GET, "me/push-devices")
            // The scheduler runs without any APNs path and sends nothing.
            _ = try await seedSegment(app.db, a, start: Date().addingTimeInterval(-12 * 3600))
            await runtime.scheduler.runOnce(now: Date())
            XCTAssertTrue(transport.requests.isEmpty)
            try await eq(try await ApnsOutboxRecord.query(on: app.db).count(), 0)
        }
        // Incomplete configuration: unavailable, no crash.
        var partial = apnsEnvironment(); partial["APNS_TEAM_ID"] = nil
        try await apnsApp(env: partial) { app, _, runtime, _ in XCTAssertNil(runtime.service.apns) }
    }

    func testApnsDeviceRegistrationValidationAndIsolation() async throws {
        try await apnsApp(env: apnsEnvironment()) { app, auth, runtime, _ in
            XCTAssertNotNil(runtime.service.apns)
            let (a, _) = try await registered(auth, db: app.db)
            let b = try await second(app, auth, a)
            let config = try object(await api(app, a, .GET, "push/config"))
            XCTAssertEqual(config["apnsAvailable"] as? Bool, true)
            let created = try object(await api(app, a, .POST, "me/push-devices", deviceBody(testToken.uppercased()), .created))
            let id = try XCTUnwrap(created["id"] as? String)
            XCTAssertEqual(created["platform"] as? String, "ios"); XCTAssertEqual(created["environment"] as? String, "sandbox")
            XCTAssertEqual(created["appBundleId"] as? String, testBundle); XCTAssertEqual(created["label"] as? String, "iPhone")
            XCTAssertNil(created["token"])
            // Stored lower-case with a hash; the token never appears in responses.
            let row = try await need(try await ApnsDeviceRecord.query(on: app.db).first())
            XCTAssertEqual(row.token, testToken); XCTAssertEqual(row.tokenHash, Secrets.hash(testToken)); XCTAssertNotEqual(row.tokenHash, row.token)
            let list = try await api(app, a, .GET, "me/push-devices")
            XCTAssertFalse(list.body.string.contains(testToken)); XCTAssertFalse(list.body.string.contains(row.tokenHash))
            XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(list.body.readableBytesView)) as? [Any])?.count, 1)
            // Idempotent re-registration updates the metadata and keeps the id.
            let again = try object(await api(app, a, .POST, "me/push-devices", deviceBody(testToken, environment: "production", label: nil), .created))
            XCTAssertEqual(again["id"] as? String, id); XCTAssertEqual(again["environment"] as? String, "production"); XCTAssertTrue(again["label"] is NSNull)
            try await eq(try await ApnsDeviceRecord.query(on: app.db).count(), 1)
            // Validation.
            let bad: [[String: Any]] = [
                deviceBody("zz"), deviceBody(String(repeating: "g", count: 64)), deviceBody(platform: "android"), deviceBody(environment: "staging"),
                deviceBody(bundle: "com.example.other"), deviceBody(label: String(repeating: "x", count: 101)),
                ["token": testToken, "platform": "ios", "environment": "sandbox"], [:],
            ]
            for body in bad { _ = try await api(app, a, .POST, "me/push-devices", body, .badRequest) }
            _ = try await api(app, a, .POST, "me/push-devices", deviceBody(String(repeating: "cd", count: 32), platform: "watchos", bundle: "com.example.timetrack.watch"), .created)
            // Isolation: the other account sees nothing and cannot remove or test the device.
            try await eq((try JSONSerialization.jsonObject(with: Data(try await api(app, b, .GET, "me/push-devices").body.readableBytesView)) as? [Any])?.count, 0)
            _ = try await api(app, b, .DELETE, "me/push-devices/" + id, nil, .notFound)
            _ = try await api(app, b, .POST, "me/push-devices/" + id + "/test", nil, .notFound)
            try await eq(try await ApnsDeviceRecord.query(on: app.db).count(), 2)
            // Authentication, CSRF, recovery sessions and bearer credentials.
            try await timeRequest(app, nil, .GET, "me/push-devices", status: .unauthorized)
            try await timeRequest(app, a, .POST, "me/push-devices", deviceBody(), status: .forbidden, extra: ["X-CSRF-Token": "wrong"])
            let recovery = try await auth.issueSession(for: a.account, recovery: true, on: app.db)
            try await timeRequest(app, recovery, .GET, "me/push-devices", status: .forbidden)
            try await timeRequest(app, recovery, .POST, "me/push-devices", deviceBody(), status: .forbidden)
            let bearer = try await app.testable().sendRequest(.GET, "/api/v1/me/push-devices", headers: ["Authorization": "Bearer abc"])
            try await eq(bearer.status, .unauthorized)
            // A token that moves to another account (shared device, new login) leaves the first account.
            let moved = try object(await api(app, b, .POST, "me/push-devices", deviceBody(), .created))
            XCTAssertEqual(moved["id"] as? String, id)
            let movedOwner = try b.account.requireID()
            try await eq(try await ApnsDeviceRecord.find(UUID(uuidString: id), on: app.db)?.accountId, movedOwner)
            try await eq((try JSONSerialization.jsonObject(with: Data(try await api(app, a, .GET, "me/push-devices").body.readableBytesView)) as? [Any])?.count, 1)
            // Removal.
            _ = try await api(app, b, .DELETE, "me/push-devices/" + id, nil, .noContent)
            _ = try await api(app, b, .DELETE, "me/push-devices/" + id, nil, .notFound)
        }
    }

    func testApnsDeviceLimitsAndRateLimit() async throws {
        try await apnsApp(env: apnsEnvironment()) { app, auth, _, _ in
            let (a, _) = try await registered(auth, db: app.db)
            for index in 0..<ApnsDeviceRules.maxDevices {
                _ = try await api(app, a, .POST, "me/push-devices", deviceBody(String(format: "%064x", index + 1)), .created)
            }
            let over = try await api(app, a, .POST, "me/push-devices", deviceBody(String(format: "%064x", 999)), .conflict)
            XCTAssertEqual(try errorCode(over), "too_many_push_devices")
            // Registration rate limit per account and hour (re-registration of known tokens counts).
            var limited = false
            for _ in 0..<(ApnsDeviceRules.registrationLimit + 2) {
                let response = try await timeRequest(app, a, .POST, "me/push-devices", deviceBody(String(format: "%064x", 1)), status: .created, extra: [:])
                _ = response
                if try await RateLimitEvent.query(on: app.db).filter(\.$key == "apns_register:" + a.account.requireID().uuidString).count() >= ApnsDeviceRules.registrationLimit { limited = true; break }
            }
            XCTAssertTrue(limited)
            let blocked = try await timeRequest(app, a, .POST, "me/push-devices", deviceBody(String(format: "%064x", 1)), status: .tooManyRequests)
            XCTAssertEqual(try errorCode(blocked), "too_many_requests")
        }
    }

    func testApnsDeliveryHeadersTestEndpointAndCleanup() async throws {
        let transport = FakeApnsTransport()
        try await apnsApp(env: apnsEnvironment(), transport: transport) { app, auth, runtime, _ in
            let (a, _) = try await registered(auth, db: app.db)
            let owner = try a.account.requireID()
            let created = try object(await api(app, a, .POST, "me/push-devices", deviceBody(), .created))
            let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created["id"] as? String)))
            // Test endpoint: one request with the documented headers and body.
            _ = try await api(app, a, .POST, "me/push-devices/\(id)/test", nil, .accepted)
            let sent = try XCTUnwrap(transport.requests.first)
            XCTAssertEqual(sent.deviceToken, testToken); XCTAssertEqual(sent.environment, "sandbox"); XCTAssertEqual(sent.topic, testBundle)
            XCTAssertEqual(sent.pushType, "alert"); XCTAssertEqual(sent.priority, 10); XCTAssertEqual(sent.authorization.split(separator: ".").count, 3)
            XCTAssertGreaterThan(sent.expiration, Int(Date().timeIntervalSince1970))
            try await present(try await ApnsDeviceRecord.find(id, on: app.db)?.lastSuccessAt)
            // Rate limit of the test endpoint: 5 per hour.
            for _ in 0..<(ApnsDeviceRules.testLimit - 1) { _ = try await api(app, a, .POST, "me/push-devices/\(id)/test", nil, .accepted) }
            _ = try await api(app, a, .POST, "me/push-devices/\(id)/test", nil, .tooManyRequests)

            // Scheduler path: a running-timer reminder reaches the device once (dedup), outside quiet hours.
            transport.script([])
            let now = notificationDate("2026-10-15T12:00:00Z")
            _ = try await seedSegment(app.db, a, start: now.addingTimeInterval(-11 * 3600))
            let before = transport.requests.count
            await runtime.scheduler.runOnce(now: now)
            await runtime.scheduler.runOnce(now: now.addingTimeInterval(60))
            XCTAssertEqual(transport.requests.count, before + 1)
            let reminder = try XCTUnwrap(transport.requests.last)
            XCTAssertEqual(reminder.collapseId.utf8.count, 32)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: reminder.body) as? [String: Any])
            XCTAssertEqual(payload["kind"] as? String, "running_timer")
            XCTAssertFalse(String(decoding: reminder.body, as: UTF8.self).contains("08:"))   // no times or other notification details in the payload
            try await eq(try await ApnsOutboxRecord.query(on: app.db).filter(\.$status == "sent").count(), 1)

            // Settings are respected: with push off for a kind nothing is queued; quiet hours defer instead of sending.
            var settings = NotificationSettingsDTO.defaults
            settings.categories["pending_suggestions"]?.push = false
            _ = try await runtime.service.putSettings(owner, settings, on: app.db)
            let quietId = try await seedNotification(app.db, a, key: "quiet", at: now, kind: "report_gap")
            let outbox = ApnsOutboxRecord()
            outbox.notificationId = quietId; outbox.deviceId = id; outbox.status = "pending"; outbox.attempts = 0; outbox.nextAttemptAt = now; outbox.createdAt = now
            try await outbox.create(on: app.db)
            let night = notificationDate("2026-10-15T21:30:00Z")   // 23:30 Berlin
            let sender = try XCTUnwrap(runtime.service.apns)
            let dispatcher = ApnsDispatcher(db: app.db, sender: sender, modules: auth.modules)
            let count = transport.requests.count
            try await dispatcher.deliverDue(now: night)
            XCTAssertEqual(transport.requests.count, count)
            try await eq(try await ApnsOutboxRecord.find(outbox.requireID(), on: app.db)?.status, "deferred")
            // Category switched off after queueing: not sent.
            settings.categories["report_gap"]?.push = false
            _ = try await runtime.service.putSettings(owner, settings, on: app.db)
            try await dispatcher.deliverDue(now: night.addingTimeInterval(8 * 3600))
            XCTAssertEqual(transport.requests.count, count)
            try await eq(try await ApnsOutboxRecord.find(outbox.requireID(), on: app.db)?.errorCode, "push_disabled")

            // Silent sync push.
            try await dispatcher.sendSyncHint(account: owner, now: now)
            let silent = try XCTUnwrap(transport.requests.last)
            XCTAssertEqual(silent.pushType, "background"); XCTAssertEqual(silent.priority, 5); XCTAssertEqual(silent.collapseId, "sync")
            XCTAssertEqual(String(decoding: silent.body, as: UTF8.self), #"{"aps":{"content-available":1},"kind":"sync"}"#)
        }
    }

    func testApnsGoneResponsesRemoveTokenAndRetriesBackOff() async throws {
        let transport = FakeApnsTransport()
        try await apnsApp(env: apnsEnvironment(), transport: transport) { app, auth, runtime, _ in
            let (a, _) = try await registered(auth, db: app.db)
            let b = try await second(app, auth, a)
            let now = notificationDate("2026-10-15T12:00:00Z")
            let sender = try XCTUnwrap(runtime.service.apns)
            let dispatcher = ApnsDispatcher(db: app.db, sender: sender, modules: auth.modules)
            func device(_ context: AuthContext, _ index: Int) async throws -> UUID {
                let created = try object(await api(app, context, .POST, "me/push-devices", deviceBody(String(format: "%064x", index)), .created))
                return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created["id"] as? String)))
            }
            func queue(_ context: AuthContext, _ deviceId: UUID, key: String) async throws -> UUID {
                let notification = try await seedNotification(app.db, context, key: key, at: now)
                let item = ApnsOutboxRecord()
                item.notificationId = notification; item.deviceId = deviceId; item.status = "pending"; item.attempts = 0; item.nextAttemptAt = now; item.createdAt = now
                try await item.create(on: app.db)
                return try item.requireID()
            }
            // 410, BadDeviceToken and Unregistered remove exactly that token; other accounts' tokens stay.
            let keep = try await device(b, 99)
            for (index, response) in [ApnsResponse(status: 410, reason: "Unregistered"), ApnsResponse(status: 400, reason: "BadDeviceToken"),
                                      ApnsResponse(status: 400, reason: "Unregistered")].enumerated() {
                let id = try await device(a, index + 1)
                _ = try await queue(a, id, key: "gone\(index)")
                transport.script([response])
                try await dispatcher.deliverDue(now: now)
                try await absent(try await ApnsDeviceRecord.find(id, on: app.db))
                try await eq(try await ApnsOutboxRecord.query(on: app.db).filter(\.$deviceId == id).count(), 0)
            }
            try await present(try await ApnsDeviceRecord.find(keep, on: app.db))
            // 429/5xx: retry with backoff, then fail after three attempts, device stays.
            let flaky = try await device(a, 50)
            let item = try await queue(a, flaky, key: "retry")
            transport.script([], then: ApnsResponse(status: 503, reason: "ServiceUnavailable"))
            try await dispatcher.deliverDue(now: now)
            var row = try await need(try await ApnsOutboxRecord.find(item, on: app.db))
            XCTAssertEqual(row.status, "pending"); XCTAssertEqual(row.attempts, 1); XCTAssertEqual(row.nextAttemptAt, now.addingTimeInterval(60))
            try await dispatcher.deliverDue(now: now.addingTimeInterval(61))
            try await dispatcher.deliverDue(now: now.addingTimeInterval(61 + 300))
            row = try await need(try await ApnsOutboxRecord.find(item, on: app.db))
            XCTAssertEqual(row.status, "failed"); XCTAssertEqual(row.attempts, 3); XCTAssertEqual(row.errorCode, "http_503")
            try await present(try await ApnsDeviceRecord.find(flaky, on: app.db))
            try await eq(try await ApnsDeviceRecord.find(flaky, on: app.db)?.failureCount, 3)
            // Other client errors fail without retry or removal; the reason is recorded sanitized.
            let other = try await device(a, 51)
            let failed = try await queue(a, other, key: "topic")
            transport.script([ApnsResponse(status: 400, reason: "DeviceTokenNotForTopic")])
            try await dispatcher.deliverDue(now: now)
            try await eq(try await ApnsOutboxRecord.find(failed, on: app.db)?.errorCode, "apns_DeviceTokenNotForTopic")
            try await present(try await ApnsDeviceRecord.find(other, on: app.db))
            // An expired provider token is refreshed and the message retried.
            let expired = try await device(a, 52)
            let retry = try await queue(a, expired, key: "expired")
            transport.script([ApnsResponse(status: 403, reason: "ExpiredProviderToken")])
            try await dispatcher.deliverDue(now: now)
            try await eq(try await ApnsOutboxRecord.find(retry, on: app.db)?.status, "pending")
            try await dispatcher.deliverDue(now: now.addingTimeInterval(61))
            try await eq(try await ApnsOutboxRecord.find(retry, on: app.db)?.status, "sent")
        }
    }

    func testApnsTransportErrorsRetryAndDoNotLeakTokens() async throws {
        struct Boom: ApnsTransport, Error, CustomStringConvertible {
            var description: String { "connect failed for \(testToken)" }
            func send(_ request: ApnsRequest) async throws -> ApnsResponse { throw self }
            func shutdown() async {}
        }
        let configuration = try XCTUnwrap(ApnsConfiguration(environment: apnsEnvironment()))
        let sender = ApnsSender(configuration: configuration, transport: Boom())
        let outcome = await sender.deliver(.silentSync, token: testToken, environment: "production", topic: testBundle, now: Date())
        XCTAssertEqual(outcome, .retry("network"))   // only a fixed code, never the error text
    }

    func testApnsAdminDiagnosisStatusAndGuards() async throws {
        // Unconfigured and incomplete: status names the problem, the check answers 501.
        var partial = apnsEnvironment(); partial["APNS_TEAM_ID"] = "short"
        for (env, code, problems) in [(["NOTIFICATIONS_ENABLED": "false"], "not_configured", [String]()), (partial, "incomplete", ["APNS_TEAM_ID"])] {
            try await apnsApp(env: env) { app, auth, _, _ in
                let (admin, _) = try await registered(auth, db: app.db)
                let member = try await self.second(app, auth, admin)
                let status = try object(await api(app, admin, .GET, "admin/apns"))
                XCTAssertEqual(status["configured"] as? Bool, false); XCTAssertEqual(status["problems"] as? [String], problems)
                XCTAssertEqual(((status["hints"] as? [[String: Any]])?.first)?["code"] as? String, code)
                XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: status), as: UTF8.self).contains("PRIVATE KEY"))
                _ = try await api(app, admin, .POST, "admin/apns/check", nil, .notImplemented)
                for (method, path) in [(HTTPMethod.GET, "admin/apns"), (.POST, "admin/apns/check")] {
                    _ = try await api(app, member, method, path, nil, .forbidden)
                    let recovery = try await auth.issueSession(for: admin.account, recovery: true, on: app.db)
                    _ = try await api(app, recovery, method, path, nil, .forbidden)
                    let anonymous = try await app.testable().sendRequest(method, "/api/v1/" + path)
                    XCTAssertEqual(anonymous.status, .unauthorized)
                }
            }
        }
    }

    func testApnsAdminCheckProbesWithoutDeliveringAndExplainsFailures() async throws {
        let transport = FakeApnsTransport()
        try await apnsApp(env: apnsEnvironment(), transport: transport) { app, auth, _, _ in
            let (admin, _) = try await registered(auth, db: app.db)
            transport.script([], then: ApnsResponse(status: 400, reason: "BadDeviceToken"))
            var status = try object(await api(app, admin, .GET, "admin/apns"))
            XCTAssertEqual(status["configured"] as? Bool, true); XCTAssertEqual(status["keyId"] as? String, "ABC123DEFG")
            XCTAssertEqual(status["bundleIds"] as? [String], [testBundle, "com.example.timetrack.watch"]); XCTAssertEqual(status["deviceCount"] as? Int, 0)
            XCTAssertEqual(((status["hints"] as? [[String: Any]])?.first)?["code"] as? String, "no_devices")
            _ = try await api(app, admin, .POST, "me/push-devices", deviceBody(), .created)
            status = try object(await api(app, admin, .GET, "admin/apns"))
            XCTAssertEqual(status["deviceCount"] as? Int, 1); XCTAssertEqual((status["hints"] as? [Any])?.count, 0)
            // All probes use the made-up token, so nothing can reach a device.
            let ok = try object(await api(app, admin, .POST, "admin/apns/check"))
            XCTAssertEqual(ok["ok"] as? Bool, true)
            XCTAssertEqual((ok["probes"] as? [[String: Any]])?.count, 4)
            XCTAssertEqual(Set(transport.requests.map(\.deviceToken)), [ApnsDiagnosis.probeToken])
            XCTAssertEqual(Set(transport.requests.map(\.environment)), ["production", "sandbox"])
            XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: ok), as: UTF8.self).contains(ApnsDiagnosis.probeToken))
            // Apple rejects the key, one topic is not allowed, and a network error: each is a normal 200 result with advice.
            transport.script([ApnsResponse(status: 403, reason: "InvalidProviderToken"), ApnsResponse(status: 403, reason: "TopicDisallowed")], then: ApnsResponse(status: 410, reason: "Unregistered"))
            let bad = try object(await api(app, admin, .POST, "admin/apns/check"))
            XCTAssertEqual(bad["ok"] as? Bool, false)
            let probes = try XCTUnwrap(bad["probes"] as? [[String: Any]])
            XCTAssertEqual(probes.map { $0["status"] as? String }, ["failed", "failed", "ok", "ok"])
            XCTAssertEqual(probes[0]["reason"] as? String, "InvalidProviderToken"); XCTAssertNotNil(probes[0]["advice"] as? String)
            // Rate limit: 6 checks per 10 minutes.
            for _ in 0..<(ApnsDiagnosis.checkLimit - 2) { _ = try await api(app, admin, .POST, "admin/apns/check") }
            _ = try await api(app, admin, .POST, "admin/apns/check", nil, .tooManyRequests)
        }
    }

    func testMcpDoesNotExposePushDevices() async throws {
        try await apnsApp(env: apnsEnvironment()) { app, auth, _, _ in
            let (a, _) = try await registered(auth, db: app.db)
            installMcp(app, ["A": try principal(a)])
            let list = try await unwrapA(try await mcpRPC(app, "A", "tools/list")["result"] as? [String: Any])
            let tools = try XCTUnwrap(list["tools"] as? [[String: Any]])
            for tool in tools {
                let text = String(decoding: try JSONSerialization.data(withJSONObject: tool), as: UTF8.self).lowercased()
                XCTAssertFalse(text.contains("apns")); XCTAssertFalse(text.contains("push_device")); XCTAssertFalse(text.contains("devicetoken"))
            }
            for name in ["register_push_device", "list_push_devices", "delete_push_device", "send_push"] {
                try await eq(rpcError(try await mcpRPC(app, "A", "tools/call", ["name": name, "arguments": [:]])), -32602)
            }
            // Personal bearer tokens do not reach the REST registration either.
            let bearer = try await app.testable().sendRequest(.POST, "/api/v1/me/push-devices", headers: ["Authorization": "Bearer A", "Content-Type": "application/json"],
                                                              body: ByteBuffer(string: String(decoding: try JSONSerialization.data(withJSONObject: deviceBody()), as: UTF8.self)))
            try await eq(bearer.status, .unauthorized)
        }
    }
}
