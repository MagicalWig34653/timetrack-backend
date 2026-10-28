import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// Package W4: the windowed / checkpointed read paths must return exactly what the evaluation over the complete history
// returns (the pre-W4 behaviour). Random histories, then random writes that must invalidate the checkpoints.

private func w4Canonical<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

extension AuthTests {
    /// Inputs of the old code path: the complete history, no checkpoint.
    private func fullInputs(_ scope: TimeServices, now: Date) async throws -> BalanceInputs {
        let snapshot = try await scope.days.snapshot()
        let adjustments = try await AdjustmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).all()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: snapshot.models.last?.timezone ?? "Europe/Berlin")!
        return BalanceInputs(snapshot: snapshot, adjustments: adjustments, carry: nil, today: LocalDate.local(now, calendar: calendar))
    }

    /// Compares weeks, account balances, statistics and day ranges of the optimized paths with the full-history oracle.
    private func assertEquivalent(_ scope: TimeServices, now: Date, seed: UInt64, weeks: Int = 8,
                                  file: StaticString = #filePath, line: UInt = #line) async throws -> Int {
        var rng = PerfRNG(seed: seed &+ 1000)
        let oracle = try await fullInputs(scope, now: now)
        var checks = 0
        // Month boundaries are the interesting weeks (checkpoint edge), plus random ones and the first/last weeks of the history.
        var mondays: [LocalDate] = [try LocalDate("2023-11-06"), try LocalDate("2026-10-19"), try LocalDate("2026-09-28"), try LocalDate("2025-03-31"),
                                    try LocalDate("2024-12-30"), try LocalDate("2024-07-29"), try LocalDate("2026-11-02"), try LocalDate("2023-10-02")]
        for _ in 0..<weeks {
            let day = try LocalDate("2023-10-01").addingDays(Int.random(in: 0..<1100, using: &rng))
            mondays.append(day.addingDays(1 - day.isoWeekday))
        }
        for monday in mondays {
            let thursday = monday.addingDays(3)
            let week = try ISOWeek(String(format: "%04d-W%02d", isoYear(thursday), isoNumber(thursday)))
            XCTAssertEqual(week.monday, monday)
            let expected = try await scope.weeks.compose(week, inputs: oracle, now: now)
            let actual = try await scope.weeks.week(week, now: now)
            XCTAssertEqual(try w4Canonical(actual), try w4Canonical(expected), "week \(week.label)", file: file, line: line); checks += 1
        }
        var asOfs: [LocalDate?] = [nil, try LocalDate("2023-11-05"), try LocalDate("2023-11-06"), try LocalDate("2024-02-29"), try LocalDate("2026-10-31"), try LocalDate("2030-01-01")]
        for _ in 0..<8 { asOfs.append(try LocalDate("2023-10-15").addingDays(Int.random(in: 0..<1100, using: &rng))) }
        for asOf in asOfs {
            let expected = try scope.account.balance(snapshot: oracle.snapshot, adjustments: oracle.adjustments, asOf: asOf, now: now)
            let actual = try await scope.account.balance(asOf: asOf, now: now)
            XCTAssertEqual(actual, expected, "account asOf \(asOf?.description ?? "today")", file: file, line: line); checks += 1
        }
        let ranges = [("2025-01-01", "2025-12-31"), ("2023-10-01", "2024-03-15"), ("2026-01-15", "2026-11-30"), ("2025-06-30", "2025-07-01")]
        for (from, to) in ranges {
            for granularity in [StatisticsGranularity.day, .week, .month] {
                let basis: StatisticsBasis = granularity == .week ? .raw : .evaluated
                let expected = try scope.statistics.series(from: LocalDate(from), to: LocalDate(to), granularity: granularity, basis: basis, inputs: oracle, now: now)
                let actual = try await scope.statistics.series(from: LocalDate(from), to: LocalDate(to), granularity: granularity, basis: basis, now: now)
                XCTAssertEqual(try w4Canonical(actual), try w4Canonical(expected), "statistics \(from)...\(to) \(granularity)", file: file, line: line); checks += 1
            }
        }
        for (from, to) in [("2025-03-27", "2025-04-03"), ("2026-10-12", "2026-10-18"), ("2024-12-28", "2025-01-05")] {
            let prepared = oracle.snapshot.prepared()
            var expected: [DayEvaluationResult] = []; var date = try LocalDate(from)
            while date <= (try LocalDate(to)) { expected.append(try prepared.evaluate(date, now: now)); date = date.addingDays(1) }
            let actual = try await scope.days.range(from: LocalDate(from), to: LocalDate(to))
            // `range` evaluates with the real clock: compare the clock independent part.
            XCTAssertEqual(actual.map { "\($0.date) \($0.mark) \($0.targetSeconds) \($0.evaluatedWorkSeconds) \($0.creditSeconds) \($0.legalWarnings.count)" },
                           expected.map { "\($0.date) \($0.mark) \($0.targetSeconds) \($0.evaluatedWorkSeconds) \($0.creditSeconds) \($0.legalWarnings.count)" },
                           "days \(from)...\(to)", file: file, line: line); checks += 1
        }
        return checks
    }

    private func isoYear(_ date: LocalDate) -> Int { date.addingDays(4 - date.isoWeekday).year }
    private func isoNumber(_ date: LocalDate) -> Int {
        let thursday = date.addingDays(4 - date.isoWeekday)
        let first = try! LocalDate(year: thursday.year, month: 1, day: 1)
        return (first.daysUntil(thursday) == 1 && thursday == first ? 0 : first.daysUntil(thursday)) / 7 + 1
    }

    func testWindowedReadsEqualFullHistoryForRandomHistories() async throws {
        let specs: [HistorySpec] = [
            .init(seed: 1),
            .init(seed: 2, openingBalance: false),
            .init(seed: 3, legalProfile: "arbzg-adult-de"),
            .init(seed: 4, legalProfile: "jarbschg-minor-de", openSegmentOn: "2026-10-20"),
            .init(seed: 5, openingBalance: false, openSegmentOn: "2025-03-05", modelChange: false),
        ]
        var total = 0
        for spec in specs {
            try await withApp { app, auth in
                await BalanceCheckpointCache.shared.reset()
                let (context, _) = try await registered(auth, db: app.db)
                let scope = TimeServices(accountId: try context.account.requireID(), db: app.db)
                try await seedHistory(spec, accountId: scope.accountId, db: app.db)
                let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z"))
                total += try await assertEquivalent(scope, now: now, seed: spec.seed)
                // Second pass answers from the cache and must stay identical.
                total += try await assertEquivalent(scope, now: now, seed: spec.seed &+ 50, weeks: 3)
                let statistics = await BalanceCheckpointCache.shared.statistics
                XCTAssertGreaterThan(statistics.hits, 0, "seed \(spec.seed): checkpoints were never reused")
                // A different "today" in the middle of the history (future days, balance clipped at today).
                let earlier = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-06-18T09:00:00Z"))
                total += try await assertEquivalent(scope, now: earlier, seed: spec.seed &+ 99, weeks: 3)
            }
        }
        print("BENCH equivalence comparisons:", total)
        XCTAssertGreaterThan(total, 250)
    }

    /// Every kind of write must invalidate the checkpoints it can influence (no stale balance).
    func testWritesInvalidateCheckpoints() async throws {
        try await withApp { app, auth in
            await BalanceCheckpointCache.shared.reset()
            let (context, _) = try await registered(auth, db: app.db)
            let accountId = try context.account.requireID()
            let scope = TimeServices(accountId: accountId, db: app.db)
            try await seedHistory(.init(seed: 21, legalProfile: "arbzg-adult-de"), accountId: accountId, db: app.db)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z"))
            var rng = PerfRNG(seed: 77)
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
            _ = try await assertEquivalent(scope, now: now, seed: 21, weeks: 3)   // warm the cache
            func compare(_ label: String) async throws {
                let oracle = try await fullInputs(scope, now: now)
                for monday in ["2026-10-19", "2025-03-31", "2024-09-30"] {
                    let week = try ISOWeek(monday == "2026-10-19" ? "2026-W43" : monday == "2025-03-31" ? "2025-W14" : "2024-W40")
                    let actual = try await scope.weeks.week(week, now: now), expected = try await scope.weeks.compose(week, inputs: oracle, now: now)
                    XCTAssertEqual(try w4Canonical(actual), try w4Canonical(expected), "\(label) \(monday)")
                }
                let actualBalance = try await scope.account.balance(now: now)
                XCTAssertEqual(actualBalance, try scope.account.balance(snapshot: oracle.snapshot, adjustments: oracle.adjustments, now: now), label)
            }
            // 1. new and moved segments in the past
            let day = try LocalDate("2024-03-12")
            let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 22))!
            let row = SegmentRecord(); row.id = UUID(); row.accountId = accountId; row.rawStartedAt = start; row.startedAt = start
            row.rawEndedAt = start.addingTimeInterval(3 * 3600); row.endedAt = start.addingTimeInterval(3 * 3600); row.kind = "work"; row.source = "import"
            row.version = 1; row.needsReview = false; row.revisions = 0
            try await row.create(on: app.db); try await compare("segment created")
            let later = calendar.date(from: DateComponents(year: 2025, month: 11, day: 5, hour: 22))!
            row.startedAt = later; row.rawStartedAt = later; row.endedAt = later.addingTimeInterval(7200); row.rawEndedAt = later.addingTimeInterval(7200)
            try await row.update(on: app.db); try await compare("segment moved")
            row.voidedAt = Date(); row.endedAt = row.endedAt; try await row.update(on: app.db); try await compare("segment voided")
            // 2. adjustment (live, not cached), day preference, absence, custom calendar day, vacation settings, work model
            let adjustment = AdjustmentRecord(); adjustment.accountId = accountId; adjustment.kind = "correction"; adjustment.date = "2024-01-10"
            adjustment.seconds = 5400; adjustment.reason = "x"; adjustment.createdAt = Date(); try await adjustment.create(on: app.db); try await compare("adjustment")
            let preference = DayPreferenceRecord(); preference.id = UUID(); preference.accountId = accountId; preference.date = "2024-05-14"
            preference.mark = "sick"; preference.skipFixedBreaks = false; try await preference.create(on: app.db); try await compare("preference created")
            preference.mark = "none"; try await preference.update(on: app.db); try await compare("preference updated")
            let absence = AbsenceRecord(); absence.id = UUID(); absence.accountId = accountId; absence.kind = "sick"; absence.startDate = "2024-06-03"; absence.endDate = "2024-06-05"
            absence.halfDayStart = false; absence.halfDayEnd = false; absence.status = "taken"; absence.documentStatus = "not_needed"; absence.version = 1
            absence.createdAt = Date(); absence.updatedAt = Date()
            let existing = try await AbsenceRecord.query(on: app.db).filter(\.$accountId == accountId).all()
            if !existing.contains(where: { $0.startDate <= "2024-06-05" && $0.endDate >= "2024-06-03" }) {
                try await absence.create(on: app.db); try await compare("absence created")
                absence.kind = "vacation"; absence.halfDayStart = true; try await absence.update(on: app.db); try await compare("absence changed")
            }
            let custom = CustomCalendarDayRecord(); custom.id = UUID(); custom.accountId = accountId; custom.kind = "holiday"
            custom.startDate = "2025-02-12"; custom.endDate = "2025-02-12"; custom.name = "Extra"; try await custom.create(on: app.db); try await compare("custom day")
            try await custom.delete(on: app.db); try await compare("custom day deleted")
            let models = try await WorkModelRecord.query(on: app.db).filter(\.$accountId == accountId).sort(\.$validFrom).all()
            var dto = try XCTUnwrap(models.first).payload; dto.weeklyTargetSeconds += 3600; dto.dailyTargetSeconds = nil
            let model = try XCTUnwrap(models.first); model.payload = dto; try await model.update(on: app.db); try await compare("work model changed")
            _ = Int.random(in: 0..<2, using: &rng)
        }
    }

    /// Statement budget: a week costs a constant number of statements, independent of history length.
    func testWeekQueryBudgetIsConstantAndCheckpointIsReused() async throws {
        setenv("DB_SQL_LOG", "1", 1); defer { unsetenv("DB_SQL_LOG") }
        try await withApp { app, auth in
            await BalanceCheckpointCache.shared.reset()
            let (context, _) = try await registered(auth, db: app.db)
            let accountId = try context.account.requireID()
            try await seedHistory(.init(seed: 31), accountId: accountId, db: app.db)
            let (counted, counter) = try countingDatabase(app)
            let scope = TimeServices(accountId: accountId, db: counted)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z"))
            _ = try await scope.weeks.week(try ISOWeek("2026-W43"), now: now)   // builds the checkpoint
            let before = counter.count
            _ = try await scope.weeks.week(try ISOWeek("2026-W42"), now: now)
            let used = counter.count - before
            print("BENCH warm week statements:", used)
            XCTAssertLessThanOrEqual(used, 14)
            let cold = await BalanceCheckpointCache.shared.statistics
            XCTAssertEqual(cold.builds, 1)
        }
    }
}
