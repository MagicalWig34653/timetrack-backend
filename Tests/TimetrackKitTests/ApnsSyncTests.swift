import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// P14b: automatic silent sync push after data changes (debounce, exclusion, settings, isolation).

private let tokenA = String(repeating: "ab12", count: 16)
private let tokenB = String(repeating: "cd34", count: 16)
private let tokenC = String(repeating: "ef56", count: 16)
private let fast = ApnsSyncCoordinator.Timing(debounce: 0.05, minInterval: 0.4)
private let bundle = "com.example.timetrack"

extension AuthTests {
    private func device(_ app: Application, _ context: AuthContext, _ token: String) async throws -> String {
        let body: [String: Any] = ["token": token, "platform": "ios", "environment": "sandbox", "appBundleId": bundle]
        let response = try await api(app, context, .POST, "me/push-devices", body, .created)
        return try XCTUnwrap(object(response)["id"] as? String)
    }
    private func syncEnvironment() -> [String: String] {
        ["APNS_PRIVATE_KEY": P256.Signing.PrivateKey().pemRepresentation, "APNS_KEY_ID": "ABC123DEFG", "APNS_TEAM_ID": "ABCDE12345",
         "APNS_BUNDLE_IDS": bundle, "NOTIFICATIONS_ENABLED": "false"]
    }
    private func syncCount(_ transport: FakeApnsTransport) -> Int {
        transport.requests.filter { $0.pushType == "background" }.count
    }
    private func change(_ app: Application, _ context: AuthContext, origin: String? = nil) async throws {
        let extra: HTTPHeaders = origin.map { ["X-Timetrack-Device": $0] } ?? [:]
        _ = try await timeRequest(app, context, .POST, "places", placeBody(), status: .created, extra: extra)
    }

    func testChangeSendsCoalescedSyncHintAndExcludesOriginDevice() async throws {
        try await apnsApp(env: syncEnvironment(), syncTiming: fast) { app, auth, runtime, transport in
            let (a, _) = try await registered(auth, db: app.db)
            let phone = try await device(app, a, tokenA)
            _ = try await device(app, a, tokenB)
            let coordinator = try XCTUnwrap(runtime.syncCoordinator)
            // Burst of changes from the phone: one hint, only to the other device.
            for _ in 0..<5 { try await change(app, a, origin: phone) }
            XCTAssertEqual(syncCount(transport), 0, "sent off the request path, after the debounce")
            await coordinator.idle()
            XCTAssertEqual(syncCount(transport), 1)
            XCTAssertEqual(transport.requests.last?.deviceToken, tokenB)
            // Second burst inside the minimum interval is delayed, not dropped and not sent twice.
            for _ in 0..<3 { try await change(app, a, origin: phone) }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(syncCount(transport), 1, "minimum interval holds the next hint back")
            await coordinator.idle()
            XCTAssertEqual(syncCount(transport), 2)
            // A change without a device header (web client) reaches every device; mixed origins exclude nobody.
            try await change(app, a)
            await coordinator.idle()
            XCTAssertEqual(Set(transport.requests.suffix(2).map(\.deviceToken)), [tokenA, tokenB])
            // Read requests and failed writes do not trigger anything.
            let before = syncCount(transport)
            _ = try await timeRequest(app, a, .GET, "places")
            _ = try await timeRequest(app, a, .POST, "places", ["name": ""], status: .badRequest)
            await coordinator.idle()
            XCTAssertEqual(syncCount(transport), before)
        }
    }

    func testSyncHintDisabledWhenUnconfiguredOrPushSwitchedOff() async throws {
        try await apnsApp(env: ["NOTIFICATIONS_ENABLED": "false"], syncTiming: fast) { app, auth, runtime, transport in
            let (a, _) = try await registered(auth, db: app.db)
            XCTAssertNil(runtime.syncCoordinator)
            try await change(app, a)
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(transport.requests.isEmpty)
        }
        try await apnsApp(env: syncEnvironment(), syncTiming: fast) { app, auth, runtime, transport in
            let (a, _) = try await registered(auth, db: app.db)
            _ = try await device(app, a, tokenA)
            var settings = NotificationSettingsDTO.defaults
            for key in settings.categories.keys { settings.categories[key]?.push = false }
            _ = try await runtime.service.putSettings(try a.account.requireID(), settings, on: app.db)
            try await change(app, a)
            await runtime.syncCoordinator?.idle()
            XCTAssertEqual(syncCount(transport), 0)
            settings.categories["running_timer"]?.push = true
            _ = try await runtime.service.putSettings(try a.account.requireID(), settings, on: app.db)
            try await change(app, a)
            await runtime.syncCoordinator?.idle()
            XCTAssertEqual(syncCount(transport), 1)
        }
    }

    func testSyncHintAccountIsolationAndForeignOriginHeader() async throws {
        try await apnsApp(env: syncEnvironment(), syncTiming: fast) { app, auth, runtime, transport in
            let (a, _) = try await registered(auth, db: app.db)
            let (b, _) = try await registered(auth, db: app.db, handle: "second", admin: a)
            _ = try await device(app, a, tokenA)
            let foreign = try await device(app, b, tokenB)
            let coordinator = try XCTUnwrap(runtime.syncCoordinator)
            try await change(app, a)
            await coordinator.idle()
            XCTAssertEqual(transport.requests.map(\.deviceToken), [tokenA], "only the changing account's devices are notified")
            // A device id of another account as origin excludes nothing of ours.
            try await Task.sleep(nanoseconds: 450_000_000)
            try await change(app, a, origin: foreign)
            await coordinator.idle()
            XCTAssertEqual(transport.requests.map(\.deviceToken), [tokenA, tokenA])
            // Garbage in the header is ignored.
            try await Task.sleep(nanoseconds: 450_000_000)
            try await change(app, a, origin: "not-a-uuid")
            await coordinator.idle()
            XCTAssertEqual(syncCount(transport), 3)
            _ = tokenC
        }
    }

    func testSyncCoordinatorDebounceAndErrorLogging() async throws {
        let sent = Locked<[(UUID, UUID?)]>([])
        let coordinator = ApnsSyncCoordinator(timing: .init(debounce: 0.1, minInterval: 0.3), logger: Logger(label: "test")) { account, excluded in
            sent.withLock { $0.append((account, excluded)) }
        }
        let one = UUID(), two = UUID(), phone = UUID()
        // Continuous changes keep postponing the hint (debounce restarts).
        for _ in 0..<4 { await coordinator.notify(account: one, origin: phone); try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(sent.withLock { $0.count }, 0)
        await coordinator.notify(account: two, origin: nil)
        await coordinator.idle()
        let result = sent.withLock { $0 }
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.0 == one }?.1, phone)
        XCTAssertNil(result.first { $0.0 == two }?.1)
        // A failing send neither crashes nor blocks later hints.
        struct Boom: Error {}
        let failing = ApnsSyncCoordinator(timing: .init(debounce: 0.01, minInterval: 0.01), logger: Logger(label: "test")) { _, _ in throw Boom() }
        await failing.notify(account: one, origin: nil); await failing.idle()
        await failing.notify(account: one, origin: nil); await failing.idle()
        await failing.stop()
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
