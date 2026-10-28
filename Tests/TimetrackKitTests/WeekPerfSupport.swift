import Foundation
import Fluent
import Logging
import XCTVapor
@testable import TimetrackKit

// Package W4: shared seeding and measuring helpers for the week/account/statistics performance and equivalence tests.

struct PerfRNG: RandomNumberGenerator {
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
struct PerfCountingLogHandler: LogHandler {
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
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) { counter.add() }
}

struct HistorySpec {
    var seed: UInt64 = 1
    var first = "2023-11-06"
    var last = "2026-10-20"
    var openingBalance = true
    var legalProfile: String?
    var openSegmentOn: String?
    var modelChange = true
}

extension AuthTests {
    /// Seeds work models, segments (several per day), absences, adjustments, day preferences and custom calendar days
    /// directly into the database of `accountId`; returns the number of rows written per kind.
    @discardableResult
    func seedHistory(_ spec: HistorySpec, accountId: UUID, db: any Database) async throws -> [String: Int] {
        var rng = PerfRNG(seed: spec.seed)
        let zone = TimeZone(identifier: "Europe/Berlin")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let first = try LocalDate(spec.first), last = try LocalDate(spec.last)
        func model(_ from: LocalDate, _ to: LocalDate?, weekly: Int, days: [Int], rounding: Bool, boundary: Int? = nil) async throws {
            let id = UUID()
            var dto = WorkModelDTO(id: id, validFrom: from, validTo: to, timezone: "Europe/Berlin", weeklyTargetSeconds: weekly, workdays: days)
            dto.roundingEnabled = rounding; dto.roundingMinutes = rounding ? 15 : nil; dto.dayBoundaryMinutes = boundary
            dto.legalProfileId = spec.legalProfile
            let row = WorkModelRecord(); row.id = id; row.accountId = accountId; row.validFrom = from.description
            row.validTo = to?.description; row.payload = dto; row.legalProfileId = spec.legalProfile
            try await row.create(on: db)
        }
        if spec.modelChange {
            let split = first.addingDays(400)
            try await model(first, split.addingDays(-1), weekly: 138_600, days: [1, 2, 3, 4, 5], rounding: true)
            try await model(split.addingDays(30), nil, weekly: 126_000, days: [1, 2, 3, 4], rounding: false, boundary: 120)
        } else {
            try await model(first, nil, weekly: 138_600, days: [1, 2, 3, 4, 5], rounding: true)
        }
        var segments: [SegmentRecord] = []
        var date = first.addingDays(-3)
        while date <= last {
            let weekday = date.isoWeekday
            if weekday <= 5 || Int.random(in: 0..<25, using: &rng) == 0, Int.random(in: 0..<12, using: &rng) != 0 {
                var minute = 6 * 60 + Int.random(in: 0..<120, using: &rng)
                for part in 0..<Int.random(in: 1...3, using: &rng) {
                    let length = Int.random(in: 45...300, using: &rng)
                    let start = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: 0, minute: minute))!
                    let end = start.addingTimeInterval(Double(length * 60))
                    let kind = part == 2 && weekday == 3 ? "school" : (Int.random(in: 0..<20, using: &rng) == 0 ? "travel" : "work")
                    let row = SegmentRecord(); row.id = UUID(); row.accountId = accountId
                    row.rawStartedAt = start; row.rawEndedAt = end; row.startedAt = start; row.endedAt = end
                    row.kind = kind; row.source = "import"; row.version = 1; row.needsReview = false; row.revisions = 0
                    if Int.random(in: 0..<50, using: &rng) == 0 { row.voidedAt = end; row.voidReason = "test" }
                    segments.append(row)
                    minute += length + Int.random(in: 0...50, using: &rng)
                }
            }
            date = date.addingDays(1)
        }
        if let open = spec.openSegmentOn {
            let day = try LocalDate(open)
            let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 22))!
            let row = SegmentRecord(); row.id = UUID(); row.accountId = accountId
            row.rawStartedAt = start; row.startedAt = start; row.kind = "work"; row.source = "timer"; row.version = 1
            row.needsReview = false; row.revisions = 0; row.running = 1
            segments.append(row)
        }
        for row in segments { try await row.create(on: db) }

        var absences = 0
        var cursor = first.addingDays(20)
        while cursor < last.addingDays(60) {
            let length = Int.random(in: 0...9, using: &rng)
            let kinds: [(String, String)] = [("vacation", "taken"), ("sick", "taken"), ("vacation", "approved"), ("other", "approved"), ("vacation", "planned"), ("vacation", "cancelled")]
            let (kind, status) = kinds[Int.random(in: 0..<kinds.count, using: &rng)]
            let row = AbsenceRecord(); row.id = UUID(); row.accountId = accountId; row.kind = kind
            row.startDate = cursor.description; row.endDate = cursor.addingDays(length).description
            row.halfDayStart = Int.random(in: 0..<6, using: &rng) == 0; row.halfDayEnd = Int.random(in: 0..<6, using: &rng) == 0
            if length == 0 { row.halfDayEnd = false }
            row.status = status; row.documentStatus = "not_needed"; row.version = 1; row.createdAt = Date(); row.updatedAt = Date()
            try await row.create(on: db); absences += 1
            cursor = cursor.addingDays(length + 1 + Int.random(in: 8...50, using: &rng))
        }
        var adjustments = 0
        if spec.openingBalance {
            let row = AdjustmentRecord(); row.accountId = accountId; row.kind = "opening"; row.date = first.addingDays(-10).description
            row.seconds = 7_200; row.reason = "opening"; row.opening = 1; row.createdAt = Date(); try await row.create(on: db); adjustments += 1
        }
        for _ in 0..<25 {
            let day = first.addingDays(Int.random(in: 0..<(first.daysUntil(last)), using: &rng))
            let row = AdjustmentRecord(); row.accountId = accountId; row.kind = "correction"; row.date = day.description
            row.seconds = Int.random(in: -7_200...7_200, using: &rng); row.reason = "fix"; row.createdAt = Date(); try await row.create(on: db); adjustments += 1
        }
        var preferences = 0
        var used = Set<String>()
        for _ in 0..<60 {
            let day = first.addingDays(Int.random(in: 0..<(first.daysUntil(last)), using: &rng))
            guard used.insert(day.description).inserted else { continue }
            let row = DayPreferenceRecord(); row.id = UUID(); row.accountId = accountId; row.date = day.description
            let marks = ["none", "sick", "school_credit", "vacation", "holiday"]
            row.mark = marks[Int.random(in: 0..<marks.count, using: &rng)]
            row.creditSeconds = row.mark == "school_credit" ? 27_000 : nil
            row.skipFixedBreaks = Int.random(in: 0..<4, using: &rng) == 0
            row.schoolLessonCount = Int.random(in: 0..<3, using: &rng) == 0 ? Int.random(in: 4...9, using: &rng) : nil
            try await row.create(on: db); preferences += 1
        }
        for offset in [100, 333, 640] {
            let day = first.addingDays(offset)
            let row = CustomCalendarDayRecord(); row.id = UUID(); row.accountId = accountId; row.kind = "holiday"
            row.startDate = day.description; row.endDate = day.description; row.name = "Bridge"
            try await row.create(on: db)
        }
        return ["segments": segments.count, "absences": absences, "adjustments": adjustments, "preferences": preferences]
    }

    /// A database handle that counts every statement executed through it.
    func countingDatabase(_ app: Application) throws -> (any Database, PerfCountingLogHandler.Counter) {
        let counter = PerfCountingLogHandler.Counter()
        var logger = Logger(label: "w4-count") { _ in PerfCountingLogHandler(counter: counter) }
        logger.logLevel = .info
        return (try XCTUnwrap(app.databases.database(logger: logger, on: app.eventLoopGroup.next())), counter)
    }
}

extension LocalDate {
    func daysUntil(_ other: LocalDate) -> Int {
        var count = 0; var cursor = self
        while cursor < other { cursor = cursor.addingDays(1); count += 1 }
        return max(count, 1)
    }
}
