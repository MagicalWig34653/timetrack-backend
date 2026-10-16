import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

actor C19PushTransport: PushTransport {
    var requests: [PushHTTPRequest] = []
    let delay: UInt64
    init(delay: UInt64 = 0) { self.delay = delay }
    func send(_ request: PushHTTPRequest) async throws -> Int {
        requests.append(request)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return 201
    }
    func shutdown() async {}
    var count: Int { requests.count }
}

/// Transport whose first send blocks on an explicit gate, so tests synchronise on events instead of sleeps.
actor C19GatedTransport: PushTransport {
    var requests: [PushHTTPRequest] = []
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func send(_ request: PushHTTPRequest) async throws -> Int {
        requests.append(request)
        if requests.count == 1 && !open { await withCheckedContinuation { waiters.append($0) } }
        return 201
    }
    func shutdown() async {}
    var count: Int { requests.count }
    func openGate() { open = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    /// Waits (generous deadline, no fixed timing assumption) until the first request has arrived.
    func waitForFirstRequest() async -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while requests.isEmpty && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return !requests.isEmpty
    }
}

extension AuthTests {
    /// A Wednesday at noon: the scheduler's weekday reminders (for example `report_gap`, which fires from Friday on) add no
    /// outbox rows, so row counts do not depend on the day the suite runs.
    static let c19QuietWeekday = notificationDate("2026-10-14T10:00:00Z")

    func c19Outbox(_ app: Application, _ auth: AuthService, _ runtime: NotificationRuntime, count: Int, now: Date,
                   kind: String = "system") async throws -> (AuthContext, [UUID]) {
        let (owner, _) = try await registered(auth, db: app.db)
        _ = try await runtime.service.putSettings(owner.account.requireID(), .init(categories: [:], quietStart: nil, quietEnd: nil), on: app.db)
        let sub = TestSubscription(endpoint: "https://fcm.googleapis.com/c19")
        let input = try JSONDecoder().decode(PushSubscriptionInput.self, from: JSONSerialization.data(withJSONObject: sub.body))
        let subscription = try await runtime.service.subscribe(owner.account.requireID(), input, on: app.db)
        var ids: [UUID] = []
        for index in 0..<count {
            let notification = try await seedNotification(app.db, owner, key: "c19-\(index)", at: now, kind: kind)
            let row = PushOutboxRecord(); row.notificationId = notification; row.subscriptionId = subscription.id
            row.status = "pending"; row.attempts = 0; row.nextAttemptAt = now; row.createdAt = now.addingTimeInterval(Double(index))
            try await row.create(on: app.db); ids.append(try row.requireID())
        }
        return (owner, ids)
    }

    func c19PushClaimsAndLease(database: [String: String]) async throws {
        let transport = C19GatedTransport()
        try await notificationApp(env: vapidEnvironment(), database: database, transport: transport) { app, auth, runtime in
            let now = Self.c19QuietWeekday
            let (_, ids) = try await self.c19Outbox(app, auth, runtime, count: 2, now: now)
            // The first send blocks until the test opens the gate; only the heartbeat can keep the lease alive meanwhile.
            let lease: TimeInterval = 1.5
            runtime.leaseDuration = lease
            let other = NotificationRuntime(scheduler: runtime.scheduler, service: runtime.service, transport: transport, interval: 60)
            other.leaseDuration = lease
            let started = Date()
            let running = Task { await runtime.tick(now: now) }
            let arrived = await transport.waitForFirstRequest()
            XCTAssertTrue(arrived)
            // Wait (wall clock) until well past the initially granted lease: without renewals it would have expired.
            let pastInitialExpiry = started.addingTimeInterval(lease + 0.4)  // wall clock; the injected `now` advances with it
            while Date() < pastInitialExpiry { try await Task.sleep(nanoseconds: 20_000_000) }
            try await self.eq(await other.tick(now: now.addingTimeInterval(Date().timeIntervalSince(started))), false)
            await transport.openGate()
            _ = await running.value
            try await self.eq(await transport.count, 2)
            try await self.eq(try await PushOutboxRecord.query(on: app.db).filter(\.$id ~~ ids).filter(\.$status == "sent").count(), 2)
            // Two dispatchers bypassing the runner still cannot send the same claimed rows.
            try await PushOutboxRecord.query(on: app.db).filter(\.$id ~~ ids).set(\.$status, to: "pending").update()
            let sender = PushSender(vapid: try XCTUnwrap(runtime.service.vapid), transport: transport)
            async let a: Void = PushDispatcher(db: app.db, sender: sender).deliverDue(now: now)
            async let b: Void = PushDispatcher(db: app.db, sender: sender).deliverDue(now: now)
            _ = try await (a, b)
            try await self.eq(await transport.count, 4)
        }
    }

    func c19PushSettingsAndRetention(database: [String: String]) async throws {
        let transport = C19PushTransport()
        try await notificationApp(env: vapidEnvironment(), database: database, transport: transport) { app, auth, runtime in
            let now = notificationDate("2026-10-15T12:00:00Z")
            let (owner, ids) = try await self.c19Outbox(app, auth, runtime, count: 205, now: now, kind: "running_timer")
            try await PushDispatcher.cap(account: owner.account.requireID(), on: app.db)
            try await self.eq(try await PushOutboxRecord.query(on: app.db).count(), 200)
            try await self.eq(try await NotificationRecord.query(on: app.db).count(), 205)
            for id in ids.prefix(5) { try await self.isNil(try await PushOutboxRecord.find(id, on: app.db)) }
            var settings = NotificationSettingsDTO.defaults
            settings.categories["running_timer"]?.push = false
            _ = try await runtime.service.putSettings(owner.account.requireID(), settings, on: app.db)
            let sender = PushSender(vapid: try XCTUnwrap(runtime.service.vapid), transport: transport)
            let dispatcher = PushDispatcher(db: app.db, sender: sender)
            try await dispatcher.deliverDue(now: now)
            try await self.eq(await transport.count, 0)
            try await self.eq(try await PushOutboxRecord.query(on: app.db).filter(\.$errorCode == "push_disabled").count(), 100)
            // Remaining due messages observe newly enabled quiet hours, including the DST transition.
            settings.categories["running_timer"]?.push = true
            _ = try await runtime.service.putSettings(owner.account.requireID(), settings, on: app.db)
            try await dispatcher.deliverDue(now: notificationDate("2026-10-24T21:30:00Z"))
            let deferred = try await PushOutboxRecord.query(on: app.db).filter(\.$status == "deferred").all()
            XCTAssertEqual(deferred.count, 100)
            XCTAssertTrue(deferred.allSatisfy { $0.nextAttemptAt == notificationDate("2026-10-25T06:00:00Z") })
            try await self.eq(await transport.count, 0)
            try await Account.query(on: app.db).filter(\.$id == owner.account.requireID()).set(\.$disabledAt, to: now).update()
            try await dispatcher.deliverDue(now: notificationDate("2026-10-25T08:00:00Z"))
            try await self.eq(await transport.count, 0)
            try await PushDispatcher.retain(now: notificationDate("2026-11-10T08:00:00Z"), on: app.db)
            try await self.eq(try await PushOutboxRecord.query(on: app.db).count(), 0)
            try await self.eq(try await NotificationRecord.query(on: app.db).count(), 205)
        }
    }

    func testC19PushClaimsAndHeartbeatSQLite() async throws { try await c19PushClaimsAndLease(database: [:]) }
    func testC19PushSettingsAndRetentionSQLite() async throws { try await c19PushSettingsAndRetention(database: [:]) }
    func testC19PushMariaDB() async throws {
        try await c19PushClaimsAndLease(database: mariaDBEnvironment())
        try await c19PushSettingsAndRetention(database: mariaDBEnvironment())
    }
    func testC19PushChecksQuietHoursBetweenDeliveries() async throws {
        let transport = C19PushTransport(delay: 700_000_000)
        try await notificationApp(env: vapidEnvironment(), transport: transport) { app, auth, runtime in
            let now = notificationDate("2026-10-15T19:59:59Z").addingTimeInterval(0.5)
            let (owner, _) = try await self.c19Outbox(app, auth, runtime, count: 2, now: now)
            _ = try await runtime.service.putSettings(owner.account.requireID(), .defaults, on: app.db)
            let sender = PushSender(vapid: try XCTUnwrap(runtime.service.vapid), transport: transport)
            try await PushDispatcher(db: app.db, sender: sender).deliverDue(now: now)
            try await self.eq(await transport.count, 1)
            try await self.eq(try await PushOutboxRecord.query(on: app.db).filter(\.$status == "deferred").count(), 1)
        }
    }
    func testC19PushStopsAfterLeaseOwnershipLoss() async throws {
        let transport = C19GatedTransport()
        try await notificationApp(env: vapidEnvironment(), transport: transport) { app, auth, runtime in
            let now = Self.c19QuietWeekday
            _ = try await self.c19Outbox(app, auth, runtime, count: 2, now: now)
            let running = Task { await runtime.tick(now: now) }
            let arrived = await transport.waitForFirstRequest()
            XCTAssertTrue(arrived)
            // The first send is still blocked on the gate, so ownership is lost deterministically before it finishes.
            try await JobLeaseRecord.query(on: app.db).set(\.$holder, to: "successor").update()
            await transport.openGate()
            _ = await running.value
            try await self.eq(await transport.count, 1)
            try await self.eq(try await PushOutboxRecord.query(on: app.db).filter(\.$status == "pending").count(), 1)
        }
    }
}
