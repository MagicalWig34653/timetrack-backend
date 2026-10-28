import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// Package W4: measurement of the week/account/statistics/days read paths over a three year history
// (statements and wall time per call, SQLite in memory). Prints `BENCH ...` lines; asserts nothing about time.

extension AuthTests {
    func testWeekEndpointBenchmark() async throws {
        setenv("DB_SQL_LOG", "1", 1); defer { unsetenv("DB_SQL_LOG") }
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let accountId = try context.account.requireID()
            let rows = try await seedHistory(.init(seed: 11), accountId: accountId, db: app.db)
            print("BENCH seeded", rows)
            let (counted, counter) = try countingDatabase(app)
            let scope = TimeServices(accountId: accountId, db: counted)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z"))
            func measure(_ label: String, repeats: Int = 5, _ body: () async throws -> Void) async throws {
                var times: [Double] = []; var statements = 0
                for _ in 0..<repeats {
                    let before = counter.count; let clock = ContinuousClock(); let begin = clock.now
                    try await body()
                    let elapsed = begin.duration(to: clock.now)
                    times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                    statements = counter.count - before
                }
                times.sort()
                print("BENCH \(label): statements=\(statements) median_ms=\(String(format: "%.1f", times[times.count / 2])) min_ms=\(String(format: "%.1f", times[0]))")
            }
            try await measure("week current") { _ = try await scope.weeks.week(try ISOWeek("2026-W43"), now: now) }
            try await measure("week old (2024-W20)") { _ = try await scope.weeks.week(try ISOWeek("2024-W20"), now: now) }
            try await measure("account balance") { _ = try await scope.account.balance(now: now) }
            try await measure("statistics 12 months monthly") {
                _ = try await scope.statistics.series(from: LocalDate("2025-10-20"), to: LocalDate("2026-10-20"), granularity: .month, basis: .evaluated, now: now)
            }
            try await measure("days range 7") { _ = try await scope.days.range(from: LocalDate("2026-10-12"), to: LocalDate("2026-10-18")) }
        }
    }
}
