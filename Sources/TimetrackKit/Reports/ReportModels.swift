import Foundation
import Fluent
import FluentSQL
import Vapor

/// Limits fixed by ADR-0008 and package C15.
enum ReportLimits {
    static let maxNameScalars = 120
    static let maxNotesScalars = 4000
    static let maxDurationSeconds = 86_400
    static let maxNumber = 1_000_000
    static let maxSortOrder = 1_000_000
    static let minYear = 1900
    static let maxYear = 2200
}

// MARK: Records

final class LearningFieldRecord: Model, @unchecked Sendable {
    static let schema = "learning_fields"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @OptionalField(key: "number") var number: Int?
    @Field(key: "name") var name: String
    /// Lower-cased name; the unique key per account makes the name unique case-insensitively on every database.
    @Field(key: "name_key") var nameKey: String
    @Field(key: "sort_order") var sortOrder: Int
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

final class ReportEntryRecord: Model, @unchecked Sendable {
    static let schema = "report_entries"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    /// ISO date `yyyy-MM-dd`; compares correctly as text.
    @Field(key: "date") var date: String
    /// No foreign key: deleting a learning field keeps the entries (the id is cleared, the name snapshot stays).
    @OptionalField(key: "learning_field_id") var learningFieldId: UUID?
    @Field(key: "learning_field_name") var learningFieldName: String
    @Field(key: "duration_seconds") var durationSeconds: Int
    @Field(key: "notes") var notes: String
    @Field(key: "version") var version: Int
    @Field(key: "draft") var draft: Bool
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}

final class ReportWeekStatusRecord: Model, @unchecked Sendable {
    static let schema = "report_week_status"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "iso_year") var isoYear: Int
    @Field(key: "iso_week") var isoWeek: Int
    @Field(key: "status") var status: String
    init() {}
}

final class ReportSourceRecord: Model, @unchecked Sendable {
    static let schema = "report_sources"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "iso_year") var isoYear: Int
    @Field(key: "iso_week") var isoWeek: Int
    @OptionalField(key: "date") var date: String?
    @OptionalField(key: "note") var note: String?
    /// Reference to `stored_files.id` (no foreign key, like the absence attachments); a deleted file simply has no metadata.
    @OptionalField(key: "file_id") var fileId: UUID?
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

// MARK: Migration

enum ReportSchema {
    static let migrations: [any Migration] = [CreateReportTables()]
}

struct CreateReportTables: AsyncMigration {
    let name = "stage4a.create_report_tables"
    func prepare(on db: any Database) async throws {
        try await db.schema("learning_fields").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("number", .int)
            .field("name", .string, .required)
            .field("name_key", .string, .required)
            .field("sort_order", .int, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "account_id", "name_key")
            .create()
        try await db.schema("report_entries").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("date", .string, .required)
            .field("learning_field_id", .uuid)
            .field("learning_field_name", .string, .required)
            .field("duration_seconds", .int, .required)
            .field("notes", .sql(unsafeRaw: "TEXT"), .required)
            .field("version", .int, .required)
            .field("draft", .bool, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()
        try await db.schema("report_week_status").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("iso_year", .int, .required)
            .field("iso_week", .int, .required)
            .field("status", .string, .required)
            .unique(on: "account_id", "iso_year", "iso_week")
            .constraint(.sql(unsafeRaw: "CHECK (status IN ('draft', 'done'))"))
            .create()
        try await db.schema("report_sources").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("iso_year", .int, .required)
            .field("iso_week", .int, .required)
            .field("date", .string)
            .field("note", .sql(unsafeRaw: "TEXT"))
            .field("file_id", .uuid)
            .field("created_at", .datetime, .required)
            .create()
        let sql = try requireSQL(db)
        try await sql.create(index: "idx_report_entries_account_date").on("report_entries").column("account_id").column("date").run()
        try await sql.create(index: "idx_report_sources_week").on("report_sources").column("account_id").column("iso_year").column("iso_week").run()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("report_sources").delete()
        try await db.schema("report_week_status").delete()
        try await db.schema("report_entries").delete()
        try await db.schema("learning_fields").delete()
    }
}

// MARK: DTOs

struct LearningFieldInput: Decodable, Sendable {
    var number: Int?
    var name: String
    var sortOrder: Int?
}
struct LearningFieldDTO: Encodable, Sendable {
    var id: UUID
    var number: Int?
    var name: String
    var sortOrder: Int
    init(_ row: LearningFieldRecord) throws { id = try row.requireID(); number = row.number; name = row.name; sortOrder = row.sortOrder }
}

struct ReportEntryInput: Decodable, Sendable {
    var date: String
    var learningFieldId: UUID?
    /// Required unless `learningFieldId` is given (then the current field name is used).
    var learningField: String?
    var durationSeconds: Int?
    var notes: String?
}
struct ReportEntryDTO: Encodable, Sendable {
    var id: UUID
    var date: String
    var learningFieldId: UUID?
    var learningField: String
    var durationSeconds: Int
    var notes: String
    var version: Int
    var createdAt: Date
    var draft: Bool
    init(_ row: ReportEntryRecord) throws {
        id = try row.requireID(); date = row.date; learningFieldId = row.learningFieldId; learningField = row.learningFieldName
        durationSeconds = row.durationSeconds; notes = row.notes; version = row.version; createdAt = row.createdAt; draft = row.draft
    }
}

struct ReportWeekDTO: Encodable, Sendable {
    struct Total: Encodable, Sendable { var learningField: String; var seconds: Int }
    var year: Int
    var week: Int
    var startDate: String
    var endDate: String
    var status: String
    var entries: [ReportEntryDTO]
    var totalSeconds: Int
    var byLearningField: [Total]
    var trackedWorkSeconds: Int
    var sourceCount: Int
}

struct ReportSourceInput: Decodable, Sendable {
    var year: Int
    var week: Int
    var date: String?
    var note: String?
    var fileId: UUID?
}
struct ReportSourceDTO: Encodable, Sendable {
    var id: UUID
    var year: Int
    var week: Int
    var date: String?
    var note: String?
    var fileId: UUID?
    var createdAt: Date
    var file: FileMetaDTO?
    init(_ row: ReportSourceRecord, file: FileMetaDTO?) throws {
        id = try row.requireID(); year = row.isoYear; week = row.isoWeek; date = row.date; note = row.note; fileId = row.fileId
        createdAt = row.createdAt; self.file = file
    }
}
