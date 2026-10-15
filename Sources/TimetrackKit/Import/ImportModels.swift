import Foundation
import Fluent
import FluentSQL
import Vapor

/// Limits fixed by ADR-0006.
enum ImportLimits {
    static let maxFileBytes = 5 * 1024 * 1024
    static let maxRows = 20_000
    static let maxColumns = 256
    static let maxZipEntries = 64
    static let maxUncompressedBytes = 50 * 1024 * 1024
    static let maxOpenJobs = 20
    static let maxTemplates = 50
    static let maxErrorsListed = 1_000
    static let maxNoteScalars = 500
}

// MARK: Records

final class ImportJobRecord: Model, @unchecked Sendable {
    static let schema = "import_jobs"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "filename") var filename: String
    @Field(key: "kind") var kind: String
    @Field(key: "sha256") var sha256: String
    @Field(key: "status") var status: String
    @Field(key: "sheets") var sheets: [String]
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "detected_profile") var detectedProfile: String?
    @OptionalField(key: "committed_at") var committedAt: Date?
    init() {}
}

/// Uploaded bytes live in the database for now. They are removed on discard and once the job is
/// committed (the batch keeps only the SHA-256 on the job); rolled-back and committed jobs hold no file.
final class ImportFileRecord: Model, @unchecked Sendable {
    static let schema = "import_files"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "job_id") var jobId: UUID
    @Field(key: "size") var size: Int
    @Field(key: "bytes") var bytes: Data
    init() {}
}

final class ImportMappingRecord: Model, @unchecked Sendable {
    static let schema = "import_mappings"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "job_id") var jobId: UUID
    @Field(key: "mapping") var mapping: ImportMapping
    init() {}
}

final class ImportBatchRecord: Model, @unchecked Sendable {
    static let schema = "import_batches"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "job_id") var jobId: UUID
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "created_count") var createdCount: Int
    @Field(key: "skipped_count") var skippedCount: Int
    @OptionalField(key: "rolled_back_at") var rolledBackAt: Date?
    init() {}
}

final class ImportBatchSegmentRecord: Model, @unchecked Sendable {
    static let schema = "import_batch_segments"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "batch_id") var batchId: UUID
    @Field(key: "segment_id") var segmentId: UUID
    @Field(key: "created_version") var createdVersion: Int
    init() {}
}

final class ImportTemplateRecord: Model, @unchecked Sendable {
    static let schema = "import_templates"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "name") var name: String
    @Field(key: "mapping") var mapping: ImportMapping
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

// MARK: Migration

enum ImportSchema {
    static let migrations: [any Migration] = [CreateImportTables()]
}

struct CreateImportTables: AsyncMigration {
    let name = "stage3b.create_import_tables"
    func prepare(on db: any Database) async throws {
        try await db.schema("import_jobs").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("filename", .string, .required)
            .field("kind", .string, .required)
            .field("sha256", .string, .required)
            .field("status", .string, .required)
            .field("sheets", .json, .required)
            .field("created_at", .datetime, .required)
            .field("committed_at", .datetime)
            .constraint(.sql(unsafeRaw: "CHECK (status IN ('uploaded', 'mapped', 'committed', 'rolled_back'))"))
            .constraint(.sql(unsafeRaw: "CHECK (kind IN ('csv', 'xlsx'))"))
            .create()
        try await db.schema("import_files").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("job_id", .uuid, .required, .references("import_jobs", "id", onDelete: .restrict))
            .field("size", .int, .required)
            .field("bytes", .sql(unsafeRaw: "LONGBLOB"), .required)
            .unique(on: "job_id")
            .create()
        try await db.schema("import_mappings").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("job_id", .uuid, .required, .references("import_jobs", "id", onDelete: .restrict))
            .field("mapping", .json, .required)
            .unique(on: "job_id")
            .create()
        try await db.schema("import_batches").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("job_id", .uuid, .required, .references("import_jobs", "id", onDelete: .restrict))
            .field("created_at", .datetime, .required)
            .field("created_count", .int, .required)
            .field("skipped_count", .int, .required)
            .field("rolled_back_at", .datetime)
            .unique(on: "job_id")
            .create()
        try await db.schema("import_batch_segments").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("batch_id", .uuid, .required, .references("import_batches", "id", onDelete: .restrict))
            .field("segment_id", .uuid, .required, .references("work_segments", "id", onDelete: .restrict))
            .field("created_version", .int, .required)
            .unique(on: "batch_id", "segment_id")
            .create()
        try await db.schema("import_templates").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("name", .string, .required)
            .field("mapping", .json, .required)
            .field("created_at", .datetime, .required)
            .create()
        let sql = try requireSQL(db)
        try await sql.create(index: "idx_import_jobs_account").on("import_jobs").column("account_id").run()
        try await sql.create(index: "idx_import_templates_account").on("import_templates").column("account_id").run()
        try await sql.create(index: "idx_import_batch_segments_account").on("import_batch_segments").column("account_id").run()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("import_templates").delete()
        try await db.schema("import_batch_segments").delete()
        try await db.schema("import_batches").delete()
        try await db.schema("import_mappings").delete()
        try await db.schema("import_files").delete()
        try await db.schema("import_jobs").delete()
    }
}

// MARK: DTOs

enum ImportDateFormat: String, Codable, Sendable { case ddMMyyyy = "dd.MM.yyyy", yyyyMMdd = "yyyy-MM-dd", excelSerial = "excel_serial" }
enum ImportTimeFormat: String, Codable, Sendable { case hhmm = "HH:mm", excelFraction = "excel_fraction", decimalHours = "decimal_hours" }

struct ImportMapping: Codable, Sendable, Equatable {
    struct Columns: Codable, Sendable, Equatable {
        var date: Int
        var start: Int?
        var end: Int?
        var duration: Int?
        var kind: Int?
        var place: Int?
        var note: Int?
    }
    var profile: String? = nil
    var worktime: WorktimeOptions? = nil
    var sheet: String
    var headerRow: Int
    var timezone: String?
    var dateFormat: ImportDateFormat
    var timeFormat: ImportTimeFormat
    var defaultKind: EngineSegmentKind?
    var columns: Columns
    var skipSummaryRows: Bool?
    /// Additive to the contract: an end earlier than the start is read as the next day only when this is true.
    var allowOvernight: Bool?

    var zone: TimeZone { TimeZone(identifier: timezone ?? "Europe/Berlin") ?? TimeZone(identifier: "Europe/Berlin")! }
    var skipsSummary: Bool { skipSummaryRows ?? true }

    func validate() throws {
        guard profile == nil || ["generic", "worktime_workbook"].contains(profile!) else { throw APIError.invalid }
        if profile == "worktime_workbook" {
            guard TimeZone(identifier: timezone ?? "Europe/Berlin") != nil else { throw APIError.invalid }
            try (worktime ?? WorktimeOptions()).validate(); return
        }
        guard !sheet.isEmpty, sheet.unicodeScalars.count <= 255, (0...ImportLimits.maxRows).contains(headerRow),
              TimeZone(identifier: timezone ?? "Europe/Berlin") != nil else { throw APIError.invalid }
        let indices = [columns.date] + [columns.start, columns.end, columns.duration, columns.kind, columns.place, columns.note].compactMap { $0 }
        guard indices.allSatisfy({ (0..<ImportLimits.maxColumns).contains($0) }) else { throw APIError.invalid }
        // Missing information is never invented: a start and an end or a duration are mandatory.
        guard columns.start != nil, columns.end != nil || columns.duration != nil else { throw APIError.invalid }
    }
}

struct ImportJobDTO: Codable, Sendable {
    var id: UUID
    var filename: String
    var kind: String
    var status: String
    var sheets: [String]
    var sha256: String
    var createdAt: Date
    var detectedProfile: String
    init(_ row: ImportJobRecord) throws {
        id = try row.requireID(); filename = row.filename; kind = row.kind; status = row.status
        sheets = row.sheets; sha256 = row.sha256; createdAt = row.createdAt; detectedProfile = row.detectedProfile ?? "generic"
    }
}

struct ImportRowError: Codable, Sendable, Equatable { var row: Int; var code: String }
struct ImportWarning: Codable, Sendable, Equatable { var code: String; var row: Int? = nil; var count: Int? = nil }
struct ImportSample: Codable, Sendable { var date: String; var startedAt: Date; var endedAt: Date; var kind: EngineSegmentKind }
struct ImportPreviewDTO: Codable, Sendable {
    var profile: String? = nil
    var worktime: WorktimePreview? = nil
    var warnings: [ImportWarning]? = nil
    var rows: Int
    var valid: Int
    var duplicates: Int
    var errors: [ImportRowError]
    var sample: [ImportSample]
    /// Additive: number of detected summary rows that were skipped (skipSummaryRows).
    var skippedSummaryRows: Int
    /// Additive: total number of rows with errors (errors is capped).
    var errorCount: Int
}
struct ImportResultDTO: Codable, Sendable {
    var warnings: [ImportWarning]? = nil
    var absencesCreated: Int = 0
    var customDaysCreated: Int = 0
    var batchId: UUID
    var created: Int
    var skipped: Int
    var conflicts: [UUID]?
    /// Additive: number of segments voided by a rollback.
    var rolledBack: Int?
}
struct ImportTemplateDTO: Codable, Sendable {
    var id: UUID
    var name: String
    var mapping: ImportMapping
}

/// 409 with the list of segments that block a rollback.
struct ImportTypedConflict: Codable, Sendable { var type: String; var id: UUID }
struct ImportConflictError: Error, Sendable { let code: String; let conflicts: [UUID]; var items: [ImportTypedConflict] = [] }
