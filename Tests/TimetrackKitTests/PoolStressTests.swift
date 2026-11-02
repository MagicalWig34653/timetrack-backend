import Foundation
import Fluent
import XCTVapor
import NIOConcurrencyHelpers
@testable import TimetrackKit

// POOL-FIX: parallel mixed traffic against MariaDB with ONE pooled connection per event loop (the production default).
// A request that holds its connection (transaction) and asks the same pool for a second one deadlocks until the pool timeout;
// this test makes such nesting visible as 5xx / pool timeouts. Needs MARIADB_TEST_HOST (skipped otherwise).

private struct StressBox: @unchecked Sendable { let test: AuthTests; let app: Application }

extension AuthTests {
    func testPoolStressWithOneConnectionPerLoop() async throws {
        let maria = try mariaDBEnvironment()
        let env = maria.merging(["DB_POOL_CONNECTIONS_PER_LOOP": "1", "DB_POOL_TIMEOUT_SECONDS": "5", "DB_KEEPALIVE_SECONDS": "0"]) { _, new in new }
        try await withApp(environment: env) { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            let member = try await self.second(app, auth, admin)
            let credentials = OAuthCredentialService(auth: auth, oauth: OAuthService(auth: auth))
            let created = try await credentials.createToken(ApiTokenInput(name: "stress", scopes: ["time:read", "time:write"], expiresInDays: 30), member, on: app.db)
            let bearer = try XCTUnwrap(created.token)
            let client = try await self.oaRegister(app)
            let box = StressBox(test: self, app: app)
            let memberHeaders = self.headers(member)

            let operations: [(String, @Sendable (Int) async -> Int)] = [
                ("session", { _ in await status { try await box.app.testable().sendRequest(.GET, "/api/v1/auth/session", headers: memberHeaders) } }),
                ("timer-start", { _ in await status { try await box.app.testable().sendRequest(.POST, "/api/v1/time/timer/start", headers: memberHeaders) } }),
                ("timer-stop", { _ in await status { try await box.app.testable().sendRequest(.POST, "/api/v1/time/timer/stop", headers: memberHeaders) } }),
                ("token-create", { index in
                    var head = memberHeaders; head.contentType = .json
                    let body = try? JSONSerialization.data(withJSONObject: ["name": "t\(index)", "scopes": ["time:read"], "expiresInDays": 30])
                    return await status { try await box.app.testable().sendRequest(.POST, "/api/v1/me/api-tokens", headers: head, body: body.map(ByteBuffer.init(data:))) }
                }),
                ("mcp", { _ in
                    var head: HTTPHeaders = ["Content-Type": "application/json"]; head.bearerAuthorization = .init(token: bearer)
                    let body = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_time_adjustments", "arguments": [:]]] as [String: Any])
                    return await status { try await box.app.testable().sendRequest(.POST, "/mcp", headers: head, body: body.map(ByteBuffer.init(data:))) }
                }),
                ("oauth", { index in
                    // Authorization request (may be rate limited with 429, which is fine); never 5xx.
                    let pkce = box.test.oaPKCE()
                    return await status { try await box.test.oaAuthorize(box.app, client: client, challenge: pkce.challenge, state: "s\(index)") }
                }),
                ("grants", { _ in
                    await status { try await box.app.testable().sendRequest(.GET, "/api/v1/me/oauth-grants", headers: memberHeaders) }
                }),
                ("notifications", { _ in
                    await status { try await box.app.testable().sendRequest(.GET, "/api/v1/notifications", headers: memberHeaders) }
                }),
                ("recovery-start", { index in
                    var head: HTTPHeaders = ["Content-Type": "application/json"]; head.contentType = .json
                    let body = try? JSONSerialization.data(withJSONObject: ["method": "recoveryCode", "identifier": "ghost\(index % 7)"])
                    return await status { try await box.app.testable().sendRequest(.POST, "/api/v1/auth/recovery/start", headers: head, body: body.map(ByteBuffer.init(data:))) }
                }),
                ("ready", { _ in await status { try await box.app.testable().sendRequest(.GET, "/ready") } }),
            ]

            let started = Date()
            let results = await withTaskGroup(of: (String, Int).self) { group -> [(String, Int)] in
                var out: [(String, Int)] = []
                var next = 0
                let total = Int(ProcessInfo.processInfo.environment["POOL_STRESS_TOTAL"] ?? "") ?? 900, width = 120
                func add() {
                    guard next < total else { return }
                    let index = next; next += 1
                    let operation = operations[index % operations.count]
                    group.addTask { (operation.0, await operation.1(index)) }
                }
                for _ in 0..<width { add() }
                while let item = await group.next() { out.append(item); add() }
                return out
            }
            let elapsed = Date().timeIntervalSince(started)
            var failures: [String: [Int: Int]] = [:]
            for (name, code) in results where code >= 500 { failures[name, default: [:]][code, default: 0] += 1 }
            print("POOLSTRESS loops=\(System.coreCount) elapsed=\(Int(elapsed))s failures=\(failures)")
            XCTAssertTrue(failures.isEmpty, "5xx under load with one connection per loop: \(failures)")
            // The pool must be usable afterwards.
            let count = try await Account.query(on: app.db).count()
            XCTAssertGreaterThan(count, 0)
        }
    }

    /// Dead connections: a firewall/IPVS entry silently drops the flow of connections that are already open (no RST, no FIN).
    /// A query on such a connection never returns, the one pooled connection of its event loop stays leased forever and every
    /// later request of that loop (and the keep-alive ping, and a probe that happens to run on that loop) times out. `/ready`
    /// must not keep answering 200 in that state, otherwise Swarm never replaces the task.
    /// Needs `socat` listening on 127.0.0.1:3307 -> MariaDB and /work/freeze.sh (see handoff POOL-FIX); skipped otherwise.
    func testReadinessReportsBlackholedPoolConnections() async throws {
        guard ProcessInfo.processInfo.environment["POOL_PROXY"] == "1" else { throw XCTSkip("POOL_PROXY=1 and a socat proxy are required") }
        let maria = try mariaDBEnvironment()
        let env = maria.merging(["DB_HOST": "127.0.0.1", "DB_PORT": "3307", "DB_POOL_CONNECTIONS_PER_LOOP": "1",
                                 "DB_POOL_TIMEOUT_SECONDS": "3", "DB_KEEPALIVE_SECONDS": "0"]) { _, new in new }
        try await withApp(environment: env) { app, auth in
            let (member, _) = try await self.registered(auth, db: app.db)
            let box = StressBox(test: self, app: app)
            let head = self.headers(member)
            // Every event loop opens its connection.
            _ = await withTaskGroup(of: Int.self) { group in
                for _ in 0..<(System.coreCount * 6) { group.addTask { await status { try await box.app.testable().sendRequest(.GET, "/api/v1/auth/session", headers: head) } } }
                var codes: [Int] = []; while let code = await group.next() { codes.append(code) }; return codes
            }
            // Two connections go silent. Requests that draw one hang for good; the watchdog gives up on them after 8 s.
            let freeze = Process(); freeze.executableURL = URL(fileURLWithPath: "/work/freeze.sh"); freeze.arguments = ["2"]
            try freeze.run(); freeze.waitUntilExit()
            let outcomes = await withTaskGroup(of: Int.self) { group -> [Int] in
                for _ in 0..<(System.coreCount * 4) {
                    group.addTask { await withWatchdog(seconds: 8) { await status { try await box.app.testable().sendRequest(.GET, "/api/v1/auth/session", headers: head) } } }
                }
                var codes: [Int] = []; while let code = await group.next() { codes.append(code) }; return codes
            }
            let broken = outcomes.filter { $0 != 200 }.count
            // Probe readiness as the Swarm health check does: one request every few seconds.
            var ready = 0, unavailable = 0, hung = 0
            for _ in 0..<24 {
                let code = await withWatchdog(seconds: 6) { await status { try await box.app.testable().sendRequest(.GET, "/ready") } }
                switch code { case 200: ready += 1; case 503: unavailable += 1; default: hung += 1 }
            }
            print("POOLSTRESS blackhole loops=\(System.coreCount) brokenRequests=\(broken) ready200=\(ready) ready503=\(unavailable) other=\(hung)")
            XCTAssertGreaterThan(broken, 0, "the frozen connections must break some requests (test setup)")
            XCTAssertEqual(ready, 0, "/ready answered 200 although the pool of at least one event loop is stuck")
            XCTAssertEqual(hung, 0, "/ready must answer 503 within the health check timeout instead of hanging")
            XCTAssertEqual(unavailable, 24)
            // The frozen sockets never answer again, so shut down without waiting for graceful close.
        }
    }
    /// The keep-alive ping notices a silent connection, closes it, and the pool opens a new one: after a few ping intervals every
    /// request works again without a restart. Needs the same socat proxy as above.
    func testKeepAliveReplacesBlackholedIdleConnections() async throws {
        guard ProcessInfo.processInfo.environment["POOL_PROXY"] == "1" else { throw XCTSkip("POOL_PROXY=1 and a socat proxy are required") }
        let maria = try mariaDBEnvironment()
        let env = maria.merging(["DB_HOST": "127.0.0.1", "DB_PORT": "3307", "DB_POOL_CONNECTIONS_PER_LOOP": "1",
                                 "DB_POOL_TIMEOUT_SECONDS": "2", "DB_KEEPALIVE_SECONDS": "0"]) { _, new in new }
        try await withApp(environment: env) { app, auth in
            let keepAlive = DatabaseKeepAlive(intervalSeconds: 1, connectionsPerLoop: 1, pingDeadlineSeconds: 2)
            try keepAlive.didBoot(app)
            defer { keepAlive.shutdown(app) }
            let (member, _) = try await self.registered(auth, db: app.db)
            let box = StressBox(test: self, app: app)
            let head = self.headers(member)
            func burst(_ count: Int, watchdog: Double) async -> [Int] {
                await withTaskGroup(of: Int.self) { group -> [Int] in
                    for _ in 0..<count { group.addTask { await withWatchdog(seconds: watchdog) { await status { try await box.app.testable().sendRequest(.GET, "/api/v1/auth/session", headers: head) } } } }
                    var codes: [Int] = []; while let code = await group.next() { codes.append(code) }; return codes
                }
            }
            _ = await burst(System.coreCount * 6, watchdog: 8)
            let freeze = Process(); freeze.executableURL = URL(fileURLWithPath: "/work/freeze.sh"); freeze.arguments = ["2"]
            try freeze.run(); freeze.waitUntilExit()
            // Idle: the next ping draws a silent connection, gives up after the deadline, closes it; the pool then opens a new one.
            try await Task.sleep(nanoseconds: 9_000_000_000)
            let after = await burst(System.coreCount * 6, watchdog: 8)
            print("POOLSTRESS keepalive heal: \(after.filter { $0 == 200 }.count)/\(after.count) ok")
            XCTAssertEqual(after.filter { $0 != 200 }.count, 0, "requests still hit a dead connection after the keep-alive should have replaced it")
        }
    }

}

/// Runs `work` and returns 599 when it has not finished after `seconds`; the work itself is not cancelled (it cannot be).
private func withWatchdog(seconds: Double, _ work: @escaping @Sendable () async -> Int) async -> Int {
    await withCheckedContinuation { continuation in
        let once = NIOLockedValueBox(false)
        @Sendable func finish(_ code: Int) { if once.withLockedValue({ let was = $0; $0 = true; return !was }) { continuation.resume(returning: code) } }
        Task { finish(await work()) }
        Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); finish(599) }
    }
}

private func status(_ run: () async throws -> XCTHTTPResponse) async -> Int {
    do { return Int(try await run().status.code) } catch { return 599 }
}