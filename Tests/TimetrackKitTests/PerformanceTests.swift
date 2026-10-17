import Foundation
import Fluent
import Logging
import XCTVapor
@testable import TimetrackKit

// Package X1: the prepared (set-based) day evaluation must be bit-identical to the original per-day algorithm,
// and the account balance must stay within a constant query budget independent of the number of days.

/// The pre-X1 implementation of `TimeEvaluationSnapshot.evaluate`, kept verbatim as the test oracle.
private func referenceEvaluate(_ snapshot: TimeEvaluationSnapshot, _ date: LocalDate, now: Date) throws -> DayEvaluationResult {
    func effective(_ explicit: DayPreferences) throws -> (DayPreferences, DayMarkSource) {
        if explicit.mark != .none { return (explicit, .explicit) }
        guard snapshot.planningEnabled else { return (explicit, .none) }
        let builtin = (try? HolidayCalendar.holidays(year: date.year, region: snapshot.region)) ?? []
        let days = builtin + snapshot.customDays
        let holiday = try AbsenceDayEffects.preferences(for: date, models: snapshot.models, absences: [], calendarDays: days, explicit: explicit)
        if holiday.mark == .holiday { return (holiday, .holiday) }
        let result = try AbsenceDayEffects.preferences(for: date, models: snapshot.models, absences: snapshot.absences, calendarDays: days, explicit: explicit)
        return (result, result.mark == .none ? .none : .absence)
    }
    let models = snapshot.models
    let selectedModel = try TimeEngine.selectModel(for: date, models: models)
    let zone = models.last(where: { $0.validFrom <= date })?.timezone ?? models.first?.timezone ?? "Europe/Berlin"
    let model = selectedModel ?? EngineWorkModel(validFrom: date, validTo: date, timezone: zone,
        weeklyTargetSeconds: 0, workdays: [], roundingEnabled: false, schoolFullDayThresholdSeconds: Int.max)
    let (preferences, markSource) = try effective(snapshot.preferences[date.description] ?? DayPreferences())
    let segments = try snapshot.segments.filter { segment in
        guard !segment.voided else { return false }
        if let owner = try TimeEngine.assignment(for: segment.startedAt, models: models) {
            return owner.model.id == selectedModel?.id && owner.date == date
        }
        return selectedModel == nil && LocalDate.local(segment.startedAt, calendar: model.calendar) == date
    }
    let result = try TimeEngine.evaluateAssignedDay(date: date, model: model, segments: segments, preferences: preferences, now: now)
    var evaluation = DayEvaluationResult(date: result.date, modelId: selectedModel?.id, mark: result.mark,
        skipFixedBreaks: result.skipFixedBreaks, targetSeconds: result.targetSeconds, rawWorkSeconds: result.rawWorkSeconds,
        breakDeductionSeconds: result.breakDeductionSeconds, startAdjustSeconds: result.startAdjustSeconds, endAdjustSeconds: result.endAdjustSeconds,
        evaluatedWorkSeconds: result.evaluatedWorkSeconds, creditSeconds: result.creditSeconds,
        evaluatedStart: result.evaluatedStart, evaluatedEnd: result.evaluatedEnd,
        provisional: date == LocalDate.local(now, calendar: model.calendar) || result.provisional,
        segmentIds: result.segmentIds, segments: result.segments, markCreditSeconds: result.markCreditSeconds, note: result.note, breakHints: result.breakHints)
    evaluation.markSource = markSource; evaluation.targetOverrideSeconds = preferences.targetOverrideSeconds
    return evaluation
}

private struct SyntheticAccount {
    var snapshot: TimeEvaluationSnapshot
    let first: LocalDate
    let last: LocalDate

    static func make(planning: Bool = true) throws -> SyntheticAccount {
        var generator = SeededGenerator(seed: 7)
        let zone = TimeZone(identifier: "Europe/Berlin")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let first = try LocalDate("2024-08-01"), last = try LocalDate("2026-10-16")
        // Two model versions with a one-month gap, a third one that starts later with a day boundary.
        let m1 = EngineWorkModel(validFrom: first, validTo: try LocalDate("2025-06-30"), weeklyTargetSeconds: 138_600, workdays: [1, 2, 3, 4, 5],
                                 fixedBreaks: [try FixedBreak(start: LocalTime(hour: 12, minute: 0), end: LocalTime(hour: 12, minute: 30))])
        let m2 = EngineWorkModel(validFrom: try LocalDate("2025-08-01"), validTo: try LocalDate("2026-03-31"), weeklyTargetSeconds: 144_000,
                                 workdays: [1, 2, 3, 4], dailyTargetSeconds: [1: 40_000], roundingEnabled: false)
        let m3 = EngineWorkModel(validFrom: try LocalDate("2026-04-01"), weeklyTargetSeconds: 126_000, workdays: [1, 2, 3, 4, 5],
                                 roundingMinutes: 30, dayBoundaryMinutes: 240)
        var segments: [EngineSegment] = []
        var date = try LocalDate("2024-07-20")   // starts before the first model
        while date < last {
            let weekday = date.isoWeekday
            if weekday <= 5 || Int.random(in: 0..<30, using: &generator) == 0 {
                var minute = 7 * 60 + Int.random(in: 0..<90, using: &generator)
                for part in 0..<Int.random(in: 1...3, using: &generator) {
                    let length = Int.random(in: 60...300, using: &generator)
                    let noon = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: 0, minute: minute))!
                    var segment = EngineSegment(kind: part == 2 && weekday == 2 ? .school : (Int.random(in: 0..<25, using: &generator) == 0 ? .travel : .work),
                                                start: noon, end: noon.addingTimeInterval(Double(length * 60)))
                    segment.voided = Int.random(in: 0..<60, using: &generator) == 0
                    segments.append(segment)
                    minute += length + Int.random(in: 0...45, using: &generator)
                }
            }
            date = date.addingDays(1)
        }
        // A night shift crossing midnight and a still-running segment.
        let night = calendar.date(from: DateComponents(year: 2026, month: 5, day: 12, hour: 22))!
        segments.append(EngineSegment(kind: .work, start: night, end: night.addingTimeInterval(6 * 3600)))
        segments.append(EngineSegment(kind: .work, start: calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 8))!, end: nil))
        segments.sort { $0.startedAt < $1.startedAt }
        var preferences: [String: DayPreferences] = [:]
        for (day, mark) in [("2024-09-03", DayMarkKind.schoolCredit), ("2025-02-10", .sick), ("2025-11-11", .vacation), ("2026-06-01", .none)] {
            preferences[day] = DayPreferences(mark: mark, creditSeconds: mark == .schoolCredit ? 27_000 : nil, skipFixedBreaks: day == "2026-06-01", note: "n")
        }
        let absences = [
            EngineAbsence(kind: .vacation, startDate: try LocalDate("2024-12-23"), endDate: try LocalDate("2025-01-03"), status: .taken, halfDayEnd: true),
            EngineAbsence(kind: .sick, startDate: try LocalDate("2025-03-10"), endDate: try LocalDate("2025-03-12"), status: .taken),
            EngineAbsence(kind: .excused, startDate: try LocalDate("2025-05-01"), endDate: try LocalDate("2025-05-02"), status: .approved),
            EngineAbsence(kind: .vacation, startDate: try LocalDate("2026-07-06"), endDate: try LocalDate("2026-07-17"), status: .taken, halfDayStart: true),
            EngineAbsence(kind: .vacation, startDate: try LocalDate("2026-12-21"), endDate: try LocalDate("2026-12-31"), status: .planned)
        ]
        let custom = [CustomCalendarDay(startDate: try LocalDate("2025-05-02"), endDate: try LocalDate("2025-05-02"), name: "Brücke"),
                      CustomCalendarDay(startDate: try LocalDate("2026-05-15"), endDate: try LocalDate("2026-05-15"), name: "Brücke")]
        return SyntheticAccount(snapshot: .init(models: [m3, m1, m2], segments: segments, preferences: preferences,
                                                absences: absences, customDays: custom, planningEnabled: planning, region: "DE-ST"),
                                first: try LocalDate("2024-07-15"), last: try LocalDate("2026-11-30"))
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {   // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Counts SQL statements (Fluent logs each one at info level when `DB_SQL_LOG=1`).
private struct CountingLogHandler: LogHandler {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func add() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    let counter: Counter
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info
    subscript(metadataKey key: String) -> Logger.Metadata.Value? { get { metadata[key] } set { metadata[key] = newValue } }
    func log(event: LogEvent) { counter.add() }
    // swift-log 1.x compatibility
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) { counter.add() }
}

final class PerformanceTests: XCTestCase {
    func testPreparedEvaluationEqualsReferenceForEveryDay() throws {
        for planning in [true, false] {
            let account = try SyntheticAccount.make(planning: planning)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-16T14:00:00Z"))
            let prepared = account.snapshot.prepared()
            var date = account.first; var days = 0
            while date <= account.last {
                let expected = try referenceEvaluate(account.snapshot, date, now: now)
                let actual = try prepared.evaluate(date, now: now)
                XCTAssertEqual(try JSONEncoder().encode(actual), try JSONEncoder().encode(expected), "\(date) planning=\(planning)")
                date = date.addingDays(1); days += 1
            }
            XCTAssertGreaterThan(days, 800)
        }
    }

    func testPreparedEvaluationReproducesReferenceErrors() throws {
        let overlapping = [EngineWorkModel(validFrom: try LocalDate("2026-01-01"), weeklyTargetSeconds: 1, workdays: [1]),
                           EngineWorkModel(validFrom: try LocalDate("2026-02-01"), weeklyTargetSeconds: 1, workdays: [1])]
        let snapshot = TimeEvaluationSnapshot(models: overlapping, segments: [], preferences: [:])
        let date = try LocalDate("2026-03-01"), now = Date()
        var reference: TimeEngineError?, prepared: TimeEngineError?
        do { _ = try referenceEvaluate(snapshot, date, now: now) } catch { reference = error as? TimeEngineError }
        do { _ = try snapshot.prepared().evaluate(date, now: now) } catch { prepared = error as? TimeEngineError }
        XCTAssertEqual(reference, .overlappingModels); XCTAssertEqual(prepared, reference)
    }

    func testDateArithmeticMatchesCalendar() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        var date = try LocalDate("1600-01-01")
        let end = try LocalDate("2105-01-01")
        var next = calendar.date(from: DateComponents(year: 1600, month: 1, day: 1))!
        while date <= end {
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: next)
            XCTAssertEqual([date.year, date.month, date.day], [parts.year!, parts.month!, parts.day!])
            XCTAssertEqual(date.isoWeekday, (parts.weekday! + 5) % 7 + 1)
            XCTAssertEqual(date.addingDays(1), try LocalDate(year: parts.year!, month: parts.month!, day: parts.day!).addingDays(1))
            date = date.addingDays(1); next = calendar.date(byAdding: .day, value: 1, to: next)!
        }
        XCTAssertEqual(try LocalDate("2024-02-28").distance(to: LocalDate("2024-03-01")), 2)
        XCTAssertEqual(try LocalDate("2024-08-01").distance(to: LocalDate("2026-10-16")), 806)
        XCTAssertEqual(try LocalDate("2026-10-16").addingDays(-1000).description, "2024-01-20")
    }

    func testRoundingBisectionEqualsExhaustiveSearch() throws {
        var generator = SeededGenerator(seed: 3)
        for (zone, minutes) in [("Europe/Berlin", 15), ("Europe/Berlin", 7), ("America/New_York", 15), ("Australia/Lord_Howe", 30), ("Pacific/Apia", 60)] {
            var model = EngineWorkModel(validFrom: try LocalDate("2000-01-01"), timezone: zone, weeklyTargetSeconds: 1, workdays: [1], roundingMinutes: minutes)
            model.roundingEnabled = true
            // Includes the DST transition days of 2025 and 2026 for the zones above.
            var instants: [Date] = (0..<300).map { _ in Date(timeIntervalSince1970: Double(Int.random(in: 1_735_689_600...1_798_761_600, using: &generator))) }
            for day in ["2025-03-30", "2025-10-26", "2026-03-29", "2026-10-25", "2025-03-09", "2025-11-02"] {
                let base = ISO8601DateFormatter().date(from: day + "T00:00:00Z")!
                instants += stride(from: -4 * 3600, through: 30 * 3600, by: 1_259).map { base.addingTimeInterval(Double($0)) }
            }
            for value in instants {
                for down in [true, false] {
                    XCTAssertEqual(TimeEngine.roundedFast(value, down: down, model: model), TimeEngine.roundedExhaustive(value, down: down, model: model),
                                   "\(zone) \(minutes) \(value) down=\(down)")
                }
            }
        }
    }

    /// 900+ working days must cost a constant number of statements, not one set per day.
    func testBalanceQueryBudgetIsIndependentOfHistoryLength() async throws {
        setenv("DB_SQL_LOG", "1", 1); defer { unsetenv("DB_SQL_LOG") }
        let helper = AuthTests()
        try await helper.withApp { app, auth in
            let (context, _) = try await helper.registered(auth, db: app.db)
            let accountId = try context.account.requireID()
            let account = try SyntheticAccount.make()
            for model in account.snapshot.models {
                let row = WorkModelRecord(); row.id = model.id; row.accountId = accountId
                row.validFrom = model.validFrom.description; row.validTo = model.validTo?.description
                var dto = WorkModelDTO(id: model.id, validFrom: model.validFrom, validTo: model.validTo, timezone: model.timezone,
                                       weeklyTargetSeconds: model.weeklyTargetSeconds, workdays: model.workdays.sorted())
                dto.roundingEnabled = model.roundingEnabled; dto.roundingMinutes = model.roundingMinutes; dto.dayBoundaryMinutes = model.dayBoundaryMinutes
                row.payload = dto; try await row.create(on: app.db)
            }
            var rows: [SegmentRecord] = []
            for segment in account.snapshot.segments where !segment.voided {
                let row = SegmentRecord(); row.id = segment.id; row.accountId = accountId; row.rawStartedAt = segment.startedAt; row.rawEndedAt = segment.endedAt
                row.startedAt = segment.startedAt; row.endedAt = segment.endedAt; row.kind = segment.kind.rawValue; row.source = "import"
                row.version = 1; row.needsReview = false; row.revisions = 0; row.running = segment.endedAt == nil ? 1 : nil
                rows.append(row)
            }
            for chunk in stride(from: 0, to: rows.count, by: 200) { for row in rows[chunk..<min(chunk + 200, rows.count)] { try await row.create(on: app.db) } }

            let counter = CountingLogHandler.Counter()
            var logger = Logger(label: "x1-count") { _ in CountingLogHandler(counter: counter) }
            logger.logLevel = .info
            let counted = try XCTUnwrap(app.databases.database(logger: logger, on: app.eventLoopGroup.next()))
            let scope = TimeServices(accountId: accountId, db: counted)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-16T14:00:00Z"))
            let balance = try await scope.account.balance(now: now)
            XCTAssertEqual(balance.accountStart, try LocalDate("2024-08-01"))
            XCTAssertGreaterThan(rows.count, 1100)
            print("BENCH balance statements:", counter.count)
            XCTAssertLessThanOrEqual(counter.count, 12, "balance over \(rows.count) segments issued \(counter.count) statements")
            let before = counter.count
            let week = try await scope.days.range(from: LocalDate("2026-10-05"), to: LocalDate("2026-10-11"))
            XCTAssertEqual(week.count, 7)
            XCTAssertLessThanOrEqual(counter.count - before, 12)
        }
    }
}
