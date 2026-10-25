import Foundation
import Fluent
import FluentSQL
import FluentMySQLDriver

final class WorkModelRecord: Model, @unchecked Sendable {
    static let schema = "work_models"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "valid_from") var validFrom: String
    @OptionalField(key: "valid_to") var validTo: String?
    @Field(key: "payload") var payload: WorkModelDTO
    @OptionalField(key: "legal_profile_id") var legalProfileId: String?
    init() {}
    /// The payload as served: versions stored before M1 have no correction counter and count as 1.
    var versioned: WorkModelDTO {
        var value = payload; value.version = value.version ?? 1
        value.legalProfileId = legalProfileId ?? value.legalProfileId ?? LegalWorkProfile.adult.id
        return value
    }
}

final class PlaceRecord: Model, @unchecked Sendable {
    static let schema = "places"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "payload") var payload: PlaceDTO
    init() {}
}

final class SegmentRecord: Model, @unchecked Sendable {
    static let schema = "work_segments"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "raw_started_at") var rawStartedAt: Date
    @OptionalField(key: "raw_ended_at") var rawEndedAt: Date?
    @Field(key: "started_at") var startedAt: Date
    @OptionalField(key: "ended_at") var endedAt: Date?
    @Field(key: "kind") var kind: String
    @OptionalField(key: "place_id") var placeId: UUID?
    @Field(key: "source") var source: String
    @OptionalField(key: "note") var note: String?
    @Field(key: "version") var version: Int
    @OptionalField(key: "voided_at") var voidedAt: Date?
    @OptionalField(key: "void_reason") var voidReason: String?
    @Field(key: "needs_review") var needsReview: Bool
    @OptionalField(key: "client_event_id") var clientEventId: UUID?
    @OptionalField(key: "running") var running: Int?
    @Field(key: "revisions") var revisions: Int
    init() {}
}

final class RevisionRecord: Model, @unchecked Sendable {
    static let schema = "segment_revisions"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "segment_id") var segmentId: UUID
    @Field(key: "before_snapshot") var before: EngineSegment
    @Field(key: "after_snapshot") var after: EngineSegment
    @Field(key: "reason") var reason: String
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

final class DayPreferenceRecord: Model, @unchecked Sendable {
    static let schema = "day_preferences"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "date") var date: String
    @Field(key: "mark") var mark: String
    @OptionalField(key: "credit_seconds") var creditSeconds: Int?
    @Field(key: "skip_fixed_breaks") var skipFixedBreaks: Bool
    @OptionalField(key: "note") var note: String?
    @OptionalField(key: "school_lesson_count") var schoolLessonCount: Int?
    init() {}
}

final class AdjustmentRecord: Model, @unchecked Sendable {
    static let schema = "account_adjustments"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "date") var date: String
    @Field(key: "seconds") var seconds: Int
    @Field(key: "reason") var reason: String
    @OptionalField(key: "opening") var opening: Int?
    @OptionalField(key: "created_at") var createdAt: Date?
    init() {}
}

struct AddAdjustmentCreatedAt: AsyncMigration {
    let name = "x3.add_adjustment_created_at"
    func prepare(on db: any Database) async throws {
        try await db.schema(AdjustmentRecord.schema).field("created_at", .datetime).update()
        let legacy = try await AdjustmentRecord.query(on: db).all()
        let migratedAt = Date()
        for row in legacy { row.createdAt = migratedAt; try await row.update(on: db) }
    }
    func revert(on db: any Database) async throws {
        try await db.schema(AdjustmentRecord.schema).deleteField("created_at").update()
    }
}

final class SuggestionRecord: Model, @unchecked Sendable {
    static let schema = "suggestions"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "payload") var payload: SuggestionDTO
    @OptionalField(key: "resolved_at") var resolvedAt: Date?
    init() {}
}

final class DeviceTokenRecord: Model, @unchecked Sendable {
    static let schema = "device_tokens"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "scope") var scope: String
    @Field(key: "name") var name: String
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "expires_at") var expiresAt: Date?
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?
    init() {}
}

final class AutomationEventRecord: Model, @unchecked Sendable {
    static let schema = "automation_events"
    @Field(key: "sequence") var sequence: Int
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "event_id") var eventId: UUID
    @Field(key: "device_id") var deviceId: String
    @Field(key: "place_id") var placeId: UUID
    @Field(key: "type") var type: String
    @Field(key: "occurred_at") var occurredAt: Date
    @Field(key: "payload") var payload: AutomationInput
    @Field(key: "result") var result: AutomationResult
    init() {}
}

final class TimerEventRecord: Model, @unchecked Sendable {
    static let schema = "timer_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "client_event_id") var clientEventId: UUID
    @Field(key: "action") var action: String
    @Field(key: "result") var result: EngineSegment
    init() {}
}

enum StageTwoSchema {
    static let migrations: [any Migration] = [CreateTimePersistence()]
}

struct AddLegalWorkProfile: AsyncMigration {
    let name = "r2.add_legal_work_profile"
    func prepare(on db: any Database) async throws {
        try await db.schema("work_models").field("legal_profile_id", .string).update()
        try await db.schema("day_preferences").field("school_lesson_count", .int).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("day_preferences").deleteField("school_lesson_count").update()
        try await db.schema("work_models").deleteField("legal_profile_id").update()
    }
}

struct CreateTimePersistence: AsyncMigration {
    let name = "stage2.create_time_persistence"
    func prepare(on db: any Database) async throws {
        try await db.schema("work_models").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("valid_from", .string, .required)
            .field("valid_to", .string)
            .field("payload", .json, .required)
            .unique(on: "account_id", "valid_from")
            .create()
        try await db.schema("places").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("payload", .json, .required)
            .create()
        try await db.schema("work_segments").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("raw_started_at", .datetime, .required)
            .field("raw_ended_at", .datetime)
            .field("started_at", .datetime, .required)
            .field("ended_at", .datetime)
            .field("kind", .string, .required)
            .field("place_id", .uuid, .references("places", "id", onDelete: .restrict))
            .field("source", .string, .required)
            .field("note", .sql(unsafeRaw: "TEXT"))
            .field("version", .int, .required)
            .field("voided_at", .datetime)
            .field("void_reason", .string)
            .field("needs_review", .bool, .required)
            .field("client_event_id", .uuid)
            .field("running", .int)
            .field("revisions", .int, .required)
            .unique(on: "account_id", "running")
            .constraint(.sql(unsafeRaw: "CHECK ((ended_at IS NULL AND voided_at IS NULL AND running IS NOT NULL AND running = 1) OR ((ended_at IS NOT NULL OR voided_at IS NOT NULL) AND running IS NULL))"))
            .create()
        try await db.schema("segment_revisions").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("segment_id", .uuid, .required, .references("work_segments", "id", onDelete: .restrict))
            .field("before_snapshot", .json, .required)
            .field("after_snapshot", .json, .required)
            .field("reason", .string, .required)
            .field("created_at", .datetime, .required)
            .create()
        try await db.schema("day_preferences").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("date", .string, .required)
            .field("mark", .string, .required)
            .field("credit_seconds", .int64)
            .field("skip_fixed_breaks", .bool, .required)
            .field("note", .sql(unsafeRaw: "TEXT"))
            .unique(on: "account_id", "date")
            .create()
        try await db.schema("account_adjustments").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("kind", .string, .required)
            .field("date", .string, .required)
            .field("seconds", .int64, .required)
            .field("reason", .string, .required)
            .field("opening", .int)
            .unique(on: "account_id", "opening")
            .constraint(.sql(unsafeRaw: "CHECK ((kind = 'opening' AND opening IS NOT NULL AND opening = 1) OR (kind = 'correction' AND opening IS NULL))"))
            .create()
        try await db.schema("suggestions").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("payload", .json, .required)
            .field("resolved_at", .datetime)
            .create()
        try await db.schema("device_tokens").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("token_hash", .string, .required)
            .field("scope", .string, .required)
            .field("name", .string, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime)
            .field("revoked_at", .datetime)
            .field("last_used_at", .datetime)
            .unique(on: "token_hash")
            .create()
        try await db.schema("automation_events").id()
            .field("sequence", .int64, .required)
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("event_id", .uuid, .required)
            .field("device_id", .string, .required)
            .field("place_id", .uuid, .required, .references("places", "id", onDelete: .restrict))
            .field("type", .string, .required)
            .field("occurred_at", .datetime, .required)
            .field("payload", .json, .required)
            .field("result", .json, .required)
            .unique(on: "account_id", "event_id")
            .create()
        try await db.schema("timer_events").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("client_event_id", .uuid, .required)
            .field("action", .string, .required)
            .field("result", .json, .required)
            .unique(on: "account_id", "client_event_id", "action")
            .create()
        let sql = try requireSQL(db)
        try await sql.create(index: "idx_work_models_account").on("work_models").column("account_id").run()
        try await sql.create(index: "idx_places_account").on("places").column("account_id").run()
        try await sql.create(index: "idx_work_segments_account").on("work_segments").column("account_id").run()
        try await sql.create(index: "idx_segment_revisions_account").on("segment_revisions").column("account_id").run()
        try await sql.create(index: "idx_day_preferences_account").on("day_preferences").column("account_id").run()
        try await sql.create(index: "idx_account_adjustments_account").on("account_adjustments").column("account_id").run()
        try await sql.create(index: "idx_suggestions_account").on("suggestions").column("account_id").run()
        try await sql.create(index: "idx_device_tokens_account").on("device_tokens").column("account_id").run()
        try await sql.create(index: "idx_automation_events_account").on("automation_events").column("account_id").run()
        try await sql.create(index: "idx_timer_events_account").on("timer_events").column("account_id").run()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("timer_events").delete()
        try await db.schema("automation_events").delete()
        try await db.schema("device_tokens").delete()
        try await db.schema("suggestions").delete()
        try await db.schema("account_adjustments").delete()
        try await db.schema("day_preferences").delete()
        try await db.schema("segment_revisions").delete()
        try await db.schema("work_segments").delete()
        try await db.schema("places").delete()
        try await db.schema("work_models").delete()
    }
}

/// X1: range reads and the overlap check filter `work_segments` by account and start instant. The single-column
/// account index forced a scan of the whole account history; this composite index serves both.
struct AddSegmentTimeIndex: AsyncMigration {
    let name = "x1.add_segment_time_index"
    func prepare(on db: any Database) async throws {
        try await requireSQL(db).create(index: "idx_work_segments_account_started").on("work_segments").column("account_id").column("started_at").run()
    }
    func revert(on db: any Database) async throws {
        let sql = try requireSQL(db)
        if db is any MySQLDatabase { try await sql.raw("DROP INDEX idx_work_segments_account_started ON work_segments").run() }
        else { try await sql.raw("DROP INDEX idx_work_segments_account_started").run() }
    }
}
