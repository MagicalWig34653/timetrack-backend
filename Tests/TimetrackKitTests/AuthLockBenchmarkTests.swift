import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// B2 / ADR-0017: measurement of the global `auth_lock` serialization. Not part of the default run:
//   AUTH_LOCK_BENCH=1 swift test --build-system native --filter AuthTests.testAuthLockBenchmark
// MariaDB variant additionally needs MARIADB_TEST_HOST (see EINRICHTUNG.md). Results are printed with the prefix BENCH.

extension AuthTests {
    private struct BenchRunner: @unchecked Sendable {
        let auth: AuthService
        let db: any Database
        let tokens: [String]

        /// One authenticated request: session lookup + touch, one more read, optional simulated handler time inside the transaction.
        func operation(_ index: Int, locked: Bool, holdNanos: UInt64) async throws {
            let token = tokens[index % tokens.count]
            let body: @Sendable (any Database) async throws -> Void = { tx in
                _ = try await auth.authenticate(token, on: tx)
                _ = try await Account.query(on: tx).count()
                if holdNanos > 0 { try await Task.sleep(nanoseconds: holdNanos) }
            }
            if locked { try await auth.transaction(on: db, body) } else { try await db.transaction(body) }
        }

        func measure(concurrency: Int, operations: Int, locked: Bool, holdNanos: UInt64) async throws -> (opsPerSecond: Double, p50: Double, p95: Double, errors: Int) {
            let started = DispatchTime.now().uptimeNanoseconds
            let results = try await withThrowingTaskGroup(of: [Double].self) { group in
                for worker in 0..<concurrency {
                    group.addTask {
                        var latencies: [Double] = []
                        var index = worker
                        while index < operations {
                            let begin = DispatchTime.now().uptimeNanoseconds
                            do { try await operation(index, locked: locked, holdNanos: holdNanos); latencies.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6) }
                            catch { latencies.append(-1) }
                            index += concurrency
                        }
                        return latencies
                    }
                }
                return try await group.reduce(into: [Double]()) { $0 += $1 }
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            let good = results.filter { $0 >= 0 }.sorted()
            let percentile = { (p: Double) in good.isEmpty ? 0 : good[min(good.count - 1, Int(Double(good.count) * p))] }
            return (Double(good.count) / elapsed, percentile(0.5), percentile(0.95), results.count - good.count)
        }
    }

    func authLockBenchmark(label: String, database: [String: String]) async throws {
        try await withApp(environment: database) { app, auth in
            let (owner, _) = try await self.registered(auth, db: app.db)
            var tokens: [String] = []
            for _ in 0..<64 { tokens.append(try await auth.issueSession(for: owner.account, on: app.db).token) }
            let runner = BenchRunner(auth: auth, db: app.db, tokens: tokens)
            print("BENCH \(label) (64 sessions, 600 operations per cell; ops/s, p50 ms, p95 ms, errors)")
            for hold in [UInt64(0), 5_000_000] {
                for concurrency in [1, 4, 16, 64] {
                    for locked in [true, false] {
                        _ = try await runner.measure(concurrency: concurrency, operations: 60, locked: locked, holdNanos: hold)   // warm-up
                        let r = try await runner.measure(concurrency: concurrency, operations: 600, locked: locked, holdNanos: hold)
                        print(String(format: "BENCH %@ hold=%dms c=%2d %@ %8.0f ops/s p50=%7.2f p95=%7.2f errors=%d", label, Int(hold / 1_000_000), concurrency,
                                     locked ? "auth_lock" : "no lock  ", r.opsPerSecond, r.p50, r.p95, r.errors))
                    }
                }
            }
        }
    }

    func testAuthLockBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["AUTH_LOCK_BENCH"] == "1" else { throw XCTSkip("set AUTH_LOCK_BENCH=1 to run the auth_lock measurement") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tt-bench-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file + suffix) } }
        try await authLockBenchmark(label: "sqlite-file", database: ["SQLITE_PATH": file])
        if let maria = try? mariaDBEnvironment() { try await authLockBenchmark(label: "mariadb", database: maria) }
    }
}
