import Foundation
import Fluent
import FluentSQL
import Vapor

/// Limits fixed by ADR-0006 and package C13.
enum StorageLimits {
    static let defaultMaxUploadBytes = 10 * 1024 * 1024
    /// Hard cap, also for the DB adapter (LONGBLOB / max_allowed_packet).
    static let hardMaxUploadBytes = 64 * 1024 * 1024
    static let multipartOverhead = 64 * 1024
    static let maxRules = 8
    static let maxAttachmentsPerAbsence = 20
    static let maxFilenameScalars = 120
    static let cleanupBatch = 25
}

enum StorageBackendKind: String, Codable, Sendable, CaseIterable { case db, s3, local }

struct StorageRule: Codable, Sendable, Equatable {
    var maxBytes: Int?
    var backend: StorageBackendKind
}

enum FileState: String, Sendable { case pending, stored, failed, deleting }

// MARK: Records

/// Single row (fixed id). The S3 secret is only stored as AES-GCM ciphertext + nonce.
final class StorageSettingsRecord: Model, @unchecked Sendable {
    static let schema = "storage_settings"
    static let rowId = UUID(uuidString: "00000000-0000-0000-0000-000000000c13")!
    @ID(key: .id) var id: UUID?
    @Field(key: "rules") var rules: [StorageRule]
    @Field(key: "max_upload_bytes") var maxUploadBytes: Int
    @OptionalField(key: "local_path") var localPath: String?
    @OptionalField(key: "s3_endpoint") var s3Endpoint: String?
    @OptionalField(key: "s3_region") var s3Region: String?
    @OptionalField(key: "s3_bucket") var s3Bucket: String?
    @Field(key: "s3_path_style") var s3PathStyle: Bool
    @OptionalField(key: "s3_access_key_id") var s3AccessKeyId: String?
    @OptionalField(key: "s3_secret_ciphertext") var s3SecretCiphertext: Data?
    @OptionalField(key: "s3_secret_nonce") var s3SecretNonce: Data?
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}

final class StoredFileRecord: Model, @unchecked Sendable {
    static let schema = "stored_files"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "name") var name: String
    @Field(key: "content_type") var contentType: String
    @Field(key: "size") var size: Int
    @Field(key: "sha256") var sha256: String
    @Field(key: "backend") var backend: String
    @Field(key: "storage_key") var storageKey: String
    @Field(key: "state") var state: String
    @Field(key: "created_at") var createdAt: Date
    /// Retry marker: number of failed object removals and the time of the last attempt.
    @Field(key: "cleanup_attempts") var cleanupAttempts: Int
    @OptionalField(key: "cleanup_attempted_at") var cleanupAttemptedAt: Date?
    init() {}
}

final class FileBlobRecord: Model, @unchecked Sendable {
    static let schema = "file_blobs"
    /// Same value as `stored_files.id`.
    @ID(custom: .id, generatedBy: .user) var id: UUID?
    @Field(key: "bytes") var bytes: Data
    init() {}
}

final class AbsenceAttachmentRecord: Model, @unchecked Sendable {
    static let schema = "absence_attachments"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "absence_id") var absenceId: UUID
    @Field(key: "file_id") var fileId: UUID
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

// MARK: Migration

enum StorageSchema {
    static let migrations: [any Migration] = [CreateStorageTables()]
}

struct CreateStorageTables: AsyncMigration {
    let name = "stage3b.create_storage_tables"
    func prepare(on db: any Database) async throws {
        try await db.schema("storage_settings").id()
            .field("rules", .json, .required)
            .field("max_upload_bytes", .int, .required)
            .field("local_path", .string)
            .field("s3_endpoint", .string)
            .field("s3_region", .string)
            .field("s3_bucket", .string)
            .field("s3_path_style", .bool, .required)
            .field("s3_access_key_id", .string)
            .field("s3_secret_ciphertext", .sql(unsafeRaw: "BLOB"))
            .field("s3_secret_nonce", .sql(unsafeRaw: "BLOB"))
            .field("updated_at", .datetime, .required)
            .create()
        try await db.schema("stored_files").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("name", .string, .required)
            .field("content_type", .string, .required)
            .field("size", .int, .required)
            .field("sha256", .string, .required)
            .field("backend", .string, .required)
            .field("storage_key", .string, .required)
            .field("state", .string, .required)
            .field("created_at", .datetime, .required)
            .field("cleanup_attempts", .int, .required)
            .field("cleanup_attempted_at", .datetime)
            .constraint(.sql(unsafeRaw: "CHECK (state IN ('pending', 'stored', 'failed', 'deleting'))"))
            .constraint(.sql(unsafeRaw: "CHECK (backend IN ('db', 's3', 'local'))"))
            .create()
        // No foreign key to stored_files: the row may be deleted while the blob removal is retried, and vice versa.
        try await db.schema("file_blobs").id()
            .field("bytes", .sql(unsafeRaw: "LONGBLOB"), .required)
            .create()
        // No foreign key to absences: deleting an absence must not fail because of attachments; links are cleaned up lazily.
        try await db.schema("absence_attachments").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("absence_id", .uuid, .required)
            .field("file_id", .uuid, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "absence_id", "file_id")
            .create()
        let sql = try requireSQL(db)
        try await sql.create(index: "idx_stored_files_account").on("stored_files").column("account_id").run()
        try await sql.create(index: "idx_stored_files_state").on("stored_files").column("state").run()
        try await sql.create(index: "idx_absence_attachments_file").on("absence_attachments").column("file_id").run()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("absence_attachments").delete()
        try await db.schema("file_blobs").delete()
        try await db.schema("stored_files").delete()
        try await db.schema("storage_settings").delete()
    }
}

// MARK: DTOs

struct FileMetaDTO: Content, Equatable {
    var id: UUID
    var name: String
    var size: Int
    var sha256: String
    var contentType: String
    var backend: StorageBackendKind
    var createdAt: Date
    init(_ row: StoredFileRecord) throws {
        id = try row.requireID(); name = row.name; size = row.size; sha256 = row.sha256; contentType = row.contentType
        guard let kind = StorageBackendKind(rawValue: row.backend) else { throw APIError(.internalServerError, "storage_corrupt") }
        backend = kind; createdAt = row.createdAt
    }
}

struct S3SettingsInput: Codable, Sendable {
    var endpoint: String?
    var region: String?
    var bucket: String?
    var pathStyle: Bool?
    var accessKeyId: String?
    var secretAccessKey: String?
}

struct StorageSettingsInput: Decodable, Sendable {
    var rules: [StorageRule]
    var maxUploadBytes: Int?
    var localPath: String?
    var s3: S3SettingsInput?
}

struct S3SettingsOutput: Codable, Sendable, Equatable {
    var endpoint: String; var region: String; var bucket: String; var pathStyle: Bool; var accessKeyId: String
}

struct StorageSettingsDTO: Content, Equatable {
    var rules: [StorageRule]
    var maxUploadBytes: Int
    var localPath: String?
    var s3: S3SettingsOutput?
    var hasSecret: Bool

    static let defaults = StorageSettingsDTO(rules: [.init(maxBytes: nil, backend: .db)],
                                             maxUploadBytes: StorageLimits.defaultMaxUploadBytes, localPath: nil, s3: nil, hasSecret: false)
    init(rules: [StorageRule], maxUploadBytes: Int, localPath: String?, s3: S3SettingsOutput?, hasSecret: Bool) {
        self.rules = rules; self.maxUploadBytes = maxUploadBytes; self.localPath = localPath; self.s3 = s3; self.hasSecret = hasSecret
    }
    init(_ row: StorageSettingsRecord) {
        let s3: S3SettingsOutput? = row.s3Endpoint.map {
            .init(endpoint: $0, region: row.s3Region ?? "", bucket: row.s3Bucket ?? "", pathStyle: row.s3PathStyle, accessKeyId: row.s3AccessKeyId ?? "")
        }
        self.init(rules: row.rules, maxUploadBytes: row.maxUploadBytes, localPath: row.localPath, s3: s3, hasSecret: row.s3SecretCiphertext != nil)
    }
}
