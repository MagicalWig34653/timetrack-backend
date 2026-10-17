import Foundation
import Fluent
import FluentSQL
import Vapor

enum ReportErrors {
    static let nameExists = APIError(.conflict, "learning_field_exists")

    /// Maps a unique-key violation (SQLite and MariaDB report it as a constraint failure) to 409. The pre-check in
    /// `apply` cannot see a concurrent writer whose insert commits in between (e.g. without the global auth lock).
    static func mappingNameClash<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch let error as any DatabaseError where error.isConstraintFailure { throw nameExists }
    }
}

/// Berichtsheft logic. Every query is scoped to `accountId`; foreign ids behave like missing ones (404).
struct ReportService: Sendable {
    let accountId: UUID
    let db: any Database
    let time: TimeServices

    static func session<T: Sendable>(_ context: AuthContext, auth: AuthService, db: any Database,
                                     operation: @escaping @Sendable (ReportService) async throws -> T) async throws -> T {
        try await auth.transaction(on: db) { tx in
            let current = try await auth.authenticate(context.token, on: tx)
            try current.normal()
            let account = try current.account.requireID()
            return try await operation(ReportService(accountId: account, db: tx, time: .init(accountId: account, db: tx, disabledModules: auth.configuration.disabledModules)))
        }
    }

    // MARK: Validation

    private func name(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.fitsColumn(ReportLimits.maxNameScalars) else { throw APIError.invalid }
        return trimmed
    }
    private func date(_ raw: String) throws -> LocalDate {
        do { return try LocalDate(raw) } catch { throw APIError.invalid }
    }
    private func notes(_ raw: String?) throws -> String {
        let value = raw ?? ""
        guard value.fitsColumn(ReportLimits.maxNotesScalars) else { throw APIError.invalid }
        return value
    }

    // MARK: Learning fields

    func learningFields() async throws -> [LearningFieldDTO] {
        try await LearningFieldRecord.query(on: db).filter(\.$accountId == accountId)
            .sort(\.$sortOrder).sort(\.$name).sort(\.$id).all().map(LearningFieldDTO.init)
    }

    private func learningField(_ id: UUID) async throws -> LearningFieldRecord {
        guard let row = try await LearningFieldRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$id == id).first() else { throw APIError.missing }
        return row
    }

    /// Fills `row` from the input; the name must stay unique per account, ignoring case.
    private func apply(_ input: LearningFieldInput, to row: LearningFieldRecord) async throws {
        let trimmed = try name(input.name)
        let key = trimmed.lowercased()
        let sort = input.sortOrder ?? 0
        guard input.number.map({ (0...ReportLimits.maxNumber).contains($0) }) ?? true,
              (-ReportLimits.maxSortOrder...ReportLimits.maxSortOrder).contains(sort) else { throw APIError.invalid }
        let clash = try await LearningFieldRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$nameKey == key).first()
        if let clash, clash.id != row.id { throw ReportErrors.nameExists }
        row.accountId = accountId; row.number = input.number; row.name = trimmed; row.nameKey = key; row.sortOrder = sort
    }

    func createLearningField(_ input: LearningFieldInput) async throws -> LearningFieldDTO {
        let row = LearningFieldRecord()
        try await apply(input, to: row)
        row.createdAt = Date()
        try await ReportErrors.mappingNameClash { try await row.create(on: db) }
        return try LearningFieldDTO(row)
    }

    /// Renaming never touches the name snapshots of existing entries.
    func updateLearningField(_ id: UUID, _ input: LearningFieldInput) async throws -> LearningFieldDTO {
        let row = try await learningField(id)
        try await apply(input, to: row)
        try await ReportErrors.mappingNameClash { try await row.update(on: db) }
        return try LearningFieldDTO(row)
    }

    /// Entries stay (name snapshot); only the dangling reference is cleared.
    func deleteLearningField(_ id: UUID) async throws {
        let row = try await learningField(id)
        try await ReportEntryRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$learningFieldId == id).set(\.$learningFieldId, to: nil).update()
        try await row.delete(on: db)
    }

    // MARK: Entries

    private func resolve(_ input: ReportEntryInput) async throws -> (date: LocalDate, fieldId: UUID?, fieldName: String, duration: Int, notes: String) {
        let day = try date(input.date)
        let duration = input.durationSeconds ?? 0
        guard (0...ReportLimits.maxDurationSeconds).contains(duration) else { throw APIError.invalid }
        let text = try notes(input.notes)
        if let id = input.learningFieldId {
            let field = try await learningField(id)
            return (day, id, field.name, duration, text)
        }
        guard let raw = input.learningField else { throw APIError.invalid }
        return (day, nil, try name(raw), duration, text)
    }

    private func entry(_ id: UUID) async throws -> ReportEntryRecord {
        guard let row = try await ReportEntryRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$id == id).first() else { throw APIError.missing }
        return row
    }

    func createEntry(_ input: ReportEntryInput) async throws -> ReportEntryDTO {
        let value = try await resolve(input)
        let row = ReportEntryRecord(); let now = Date()
        row.accountId = accountId; row.date = value.date.description; row.learningFieldId = value.fieldId; row.learningFieldName = value.fieldName
        row.durationSeconds = value.duration; row.notes = value.notes; row.version = 1; row.draft = false; row.createdAt = now; row.updatedAt = now
        try await row.create(on: db)
        return try ReportEntryDTO(row)
    }

    func updateEntry(_ id: UUID, _ input: ReportEntryInput, version: Int?) async throws -> ReportEntryDTO {
        let row = try await entry(id)
        guard version == row.version else { throw APIError(.preconditionFailed, "stale_version") }
        let value = try await resolve(input)
        row.date = value.date.description; row.learningFieldId = value.fieldId; row.learningFieldName = value.fieldName
        row.durationSeconds = value.duration; row.notes = value.notes; row.version += 1; row.updatedAt = Date()
        try await row.update(on: db)
        return try ReportEntryDTO(row)
    }

    func deleteEntry(_ id: UUID) async throws { try await entry(id).delete(on: db) }

    // MARK: Weeks

    private func entries(in week: ReportCalendar.Week) async throws -> [ReportEntryRecord] {
        try await ReportEntryRecord.query(on: db).filter(\.$accountId == accountId)
            .filter(\.$date >= week.start.description).filter(\.$date <= week.end.description)
            .sort(\.$date).sort(\.$createdAt).sort(\.$id).all()
    }
    private func status(_ week: ReportCalendar.Week) async throws -> String {
        try await ReportWeekStatusRecord.query(on: db).filter(\.$accountId == accountId)
            .filter(\.$isoYear == week.year).filter(\.$isoWeek == week.week).first()?.status ?? "draft"
    }
    private func sourceCount(_ week: ReportCalendar.Week) async throws -> Int {
        try await ReportSourceRecord.query(on: db).filter(\.$accountId == accountId)
            .filter(\.$isoYear == week.year).filter(\.$isoWeek == week.week).count()
    }

    /// Evaluated working time of the week's days (hint only); days outside any work model count 0.
    private func trackedWorkSeconds(_ week: ReportCalendar.Week) async throws -> Int {
        guard let first = week.days.first, let last = week.days.last else { return 0 }
        let prepared = try await time.days.snapshot(window: first...last).prepared(); let now = Date()
        return week.days.reduce(0) { $0 + ((try? prepared.evaluate($1, now: now).evaluatedWorkSeconds) ?? 0) }
    }

    func week(year: Int, week number: Int) async throws -> ReportWeekDTO {
        let week = try ReportCalendar.week(year: year, week: number)
        let rows = try await entries(in: week)
        var totals: [ReportWeekDTO.Total] = []
        for row in rows {
            if let index = totals.firstIndex(where: { $0.learningField == row.learningFieldName }) { totals[index].seconds += row.durationSeconds }
            else { totals.append(.init(learningField: row.learningFieldName, seconds: row.durationSeconds)) }
        }
        return ReportWeekDTO(year: week.year, week: week.week, startDate: week.start.description, endDate: week.end.description,
                             status: try await status(week), entries: try rows.map(ReportEntryDTO.init),
                             totalSeconds: rows.reduce(0) { $0 + $1.durationSeconds }, byLearningField: totals,
                             trackedWorkSeconds: try await trackedWorkSeconds(week), sourceCount: try await sourceCount(week))
    }

    func putStatus(year: Int, week number: Int, status value: String) async throws -> ReportWeekDTO {
        let week = try ReportCalendar.week(year: year, week: number)
        guard ["draft", "done"].contains(value) else { throw APIError.invalid }
        let existing = try await ReportWeekStatusRecord.query(on: db).filter(\.$accountId == accountId)
            .filter(\.$isoYear == week.year).filter(\.$isoWeek == week.week).first()
        let row = existing ?? ReportWeekStatusRecord()
        row.accountId = accountId; row.isoYear = week.year; row.isoWeek = week.week; row.status = value
        try await row.save(on: db)
        return try await self.week(year: year, week: number)
    }

    func text(year: Int, week number: Int) async throws -> String {
        let week = try ReportCalendar.week(year: year, week: number)
        return ReportText.render(week: week, entries: try await entries(in: week))
    }

    // MARK: Sources

    private func files(_ ids: [UUID]) async throws -> [UUID: FileMetaDTO] {
        guard !ids.isEmpty else { return [:] }
        let rows = try await StoredFileRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$id ~~ ids)
            .filter(\.$state == FileState.stored.rawValue).all()
        return Dictionary(uniqueKeysWithValues: try rows.map { (try $0.requireID(), try FileMetaDTO($0)) })
    }

    func sources(year: Int, week number: Int) async throws -> [ReportSourceDTO] {
        let week = try ReportCalendar.week(year: year, week: number)
        let rows = try await ReportSourceRecord.query(on: db).filter(\.$accountId == accountId)
            .filter(\.$isoYear == week.year).filter(\.$isoWeek == week.week).sort(\.$createdAt).sort(\.$id).all()
        let meta = try await files(rows.compactMap(\.fileId))
        return try rows.map { try ReportSourceDTO($0, file: $0.fileId.flatMap { meta[$0] }) }
    }

    func createSource(_ input: ReportSourceInput) async throws -> ReportSourceDTO {
        let week = try ReportCalendar.week(year: input.year, week: input.week)
        let note = try notes(input.note)
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || input.fileId != nil else { throw APIError.invalid }
        var day: String?
        if let raw = input.date {
            day = try date(raw).description
            guard day! >= week.start.description, day! <= week.end.description else { throw APIError.invalid }
        }
        var meta: FileMetaDTO?
        if let fileId = input.fileId {
            guard let found = try await files([fileId])[fileId] else { throw APIError.missing }
            meta = found
        }
        let row = ReportSourceRecord()
        row.accountId = accountId; row.isoYear = week.year; row.isoWeek = week.week; row.date = day
        row.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        row.fileId = input.fileId; row.createdAt = Date()
        try await row.create(on: db)
        return try ReportSourceDTO(row, file: meta)
    }

    func deleteSource(_ id: UUID) async throws {
        guard let row = try await ReportSourceRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$id == id).first() else { throw APIError.missing }
        try await row.delete(on: db)
    }
}
