import Foundation
import Fluent
import Vapor

// Package W4: change marks for the cached account balance checkpoints (see BalanceCheckpoints.swift).
//
// Every write to a row that feeds the day evaluation (segments, day preferences, absences, work models, vacation settings,
// custom calendar days) bumps a revision in `time_change_marks`, inside the transaction of the write itself. A mark is
// kept per account and calendar month of the earliest day the write can influence (`everything` for rows without a date).
// A checkpoint "balance up to day D" is valid as long as the sum of the revisions of all marks up to the month of D is
// unchanged: writes to later months leave it untouched. Because the marks live in the database, this holds across
// several backend replicas, unlike an in-process invalidation.

final class TimeChangeMark: Model, @unchecked Sendable {
    static let schema = "time_change_marks"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    /// "YYYY-MM" or `TimeChangeTracker.everything`.
    @Field(key: "month") var month: String
    @Field(key: "revision") var revision: Int
    init() {}
}

/// Created first so that every later (data) migration already finds the table the middleware writes to.
struct CreateTimeChangeMarks: AsyncMigration {
    let name = "w4.create_time_change_marks"
    func prepare(on db: any Database) async throws {
        try await db.schema(TimeChangeMark.schema)
            .id()
            .field("account_id", .uuid, .required)
            .field("month", .string, .required)
            .field("revision", .int64, .required)
            .unique(on: "account_id", "month")
            .create()
    }
    func revert(on db: any Database) async throws { try await db.schema(TimeChangeMark.schema).delete() }
}

enum TimeChangeTracker {
    /// Mark month for writes that can change every day of the account (work models, settings, custom calendar days).
    static let everything = "*"
    /// A write on day X can change evaluations from X - margin on: legal week rules look at the surrounding ISO week, and
    /// a segment is assigned to a day by its start instant (time zone and day boundary shift it by less than two days).
    static let marginDays = 7

    static func month(of date: LocalDate) -> String { String(date.addingDays(-marginDays).description.prefix(7)) }
    private static var utc: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt; return calendar }
    static func month(of instant: Date) -> String { month(of: LocalDate.local(instant, calendar: utc)) }
    static func month(ofDay text: String) -> String? { (try? LocalDate(text)).map(month(of:)) }

    static func touch(account: UUID, months: Set<String>, on db: any Database) async throws {
        for month in months.sorted() {
            let now = Int(Date().timeIntervalSince1970 * 1000)
            func bump() async throws -> Bool {
                guard let row = try await TimeChangeMark.query(on: db).filter(\.$accountId == account).filter(\.$month == month).first() else { return false }
                row.revision = max(row.revision + 1, now); try await row.update(on: db); return true
            }
            if try await bump() { continue }
            let row = TimeChangeMark(); row.accountId = account; row.month = month; row.revision = now
            // Batch creates run their model middleware concurrently: a racing insert of the same month loses on the
            // unique key and falls back to bumping the row the winner created.
            do { try await row.create(on: db) } catch { if try await !bump() { throw error } }
        }
    }

    /// Changes up to and including the month of `day`: the sum of the revisions of all marks that can influence days <= `day`.
    static func fingerprint(account: UUID, through day: LocalDate, on db: any Database) async throws -> Int {
        let last = String(day.description.prefix(7))
        let rows = try await TimeChangeMark.query(on: db).filter(\.$accountId == account).all()
        return rows.filter { $0.month == everything || $0.month <= last }.reduce(0) { $0 &+ $1.revision }
    }
}

/// Bumps the change marks of one model type. `scope` returns the account and the months a row version influences.
struct TimeChangeMiddleware<Row: Model & Sendable>: AsyncModelMiddleware {
    typealias Model = Row
    let scope: @Sendable (Row) -> (account: UUID, months: Set<String>)?

    func create(model: Row, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.create(model, on: db)
        if let current = scope(model) { try await TimeChangeTracker.touch(account: current.account, months: current.months, on: db) }
    }
    func update(model: Row, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        // The previous version may have influenced other months (a segment moved to another day).
        var previous: (account: UUID, months: Set<String>)?
        if let id = model.id, let old = try await Row.find(id, on: db) { previous = scope(old) }
        try await next.update(model, on: db)
        if let current = scope(model) {
            try await TimeChangeTracker.touch(account: current.account, months: current.months.union(previous?.months ?? []), on: db)
        } else if let previous {
            try await TimeChangeTracker.touch(account: previous.account, months: previous.months, on: db)
        }
    }
    func delete(model: Row, force: Bool, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.delete(model, force: force, on: db)
        if let current = scope(model) { try await TimeChangeTracker.touch(account: current.account, months: current.months, on: db) }
    }
}

extension Application {
    /// Registers the change-mark middleware on the configured database.
    func registerTimeChangeMarks(on id: DatabaseID) {
        let everything: Set<String> = [TimeChangeTracker.everything]
        databases.middleware.use(TimeChangeMiddleware<SegmentRecord> { row in (row.accountId, [TimeChangeTracker.month(of: row.startedAt)]) }, on: id)
        databases.middleware.use(TimeChangeMiddleware<DayPreferenceRecord> { row in
            TimeChangeTracker.month(ofDay: row.date).map { (row.accountId, [$0]) } ?? (row.accountId, [TimeChangeTracker.everything]) }, on: id)
        databases.middleware.use(TimeChangeMiddleware<AbsenceRecord> { row in
            (row.accountId, [TimeChangeTracker.month(ofDay: row.startDate) ?? TimeChangeTracker.everything]) }, on: id)
        databases.middleware.use(TimeChangeMiddleware<WorkModelRecord> { row in (row.accountId, everything) }, on: id)
        databases.middleware.use(TimeChangeMiddleware<VacationSettingsRecord> { row in (row.accountId, everything) }, on: id)
        databases.middleware.use(TimeChangeMiddleware<CustomCalendarDayRecord> { row in (row.accountId, everything) }, on: id)
    }
}
