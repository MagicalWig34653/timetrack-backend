import Foundation
import Fluent

// G1: groups module (ADR-0033). Public polls (appointment finding and general polls) and group orders, reachable through an
// unguessable link without login. Only SHA-256 hashes of link tokens and edit secrets are stored.

enum GroupLimits {
    static let titleMax = 120
    static let descriptionMax = 2000
    static let nameMax = 60
    static let textMax = 200
    static let catalogNameMax = 80
    static let maxOptions = 50
    static let maxVotes = 500
    static let maxEntries = 200
    static let maxQuantity = 99
    static let maxPriceCents = 1_000_000
    static let maxPollsPerAccount = 200
    static let maxOrdersPerAccount = 200
    static let maxCatalogsPerAccount = 30
    static let maxCatalogItems = 200
    static let tokenLength = 43
    /// Default retention of closed or expired polls and rounds in days (`GROUPS_RETENTION_DAYS`).
    static let defaultRetentionDays = 90
}

final class GroupPollRecord: Model, @unchecked Sendable {
    static let schema = "group_polls"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "title") var title: String
    @OptionalField(key: "description") var details: String?
    /// `text` (free-text options) or `date` (date or date-time slots with yes/maybe/no answers).
    @Field(key: "kind") var kind: String
    /// `single` or `multi`.
    @Field(key: "choice_mode") var choiceMode: String
    @OptionalField(key: "time_zone") var timeZone: String?
    @OptionalField(key: "deadline") var deadline: Date?
    @Field(key: "hide_results") var hideResults: Bool
    @OptionalField(key: "closed_at") var closedAt: Date?
    @OptionalField(key: "final_option_id") var finalOptionId: UUID?
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
    func isClosed(_ now: Date) -> Bool { closedAt != nil || (deadline.map { $0 <= now } ?? false) }
}

final class GroupPollOptionRecord: Model, @unchecked Sendable {
    static let schema = "group_poll_options"
    @ID(key: .id) var id: UUID?
    @Field(key: "poll_id") var pollId: UUID
    @Field(key: "position") var position: Int
    @OptionalField(key: "label") var label: String?
    @OptionalField(key: "slot_date") var slotDate: String?
    @OptionalField(key: "start_time") var startTime: String?
    @OptionalField(key: "end_time") var endTime: String?
    init() {}
}

final class GroupPollVoteRecord: Model, @unchecked Sendable {
    static let schema = "group_poll_votes"
    @ID(key: .id) var id: UUID?
    @Field(key: "poll_id") var pollId: UUID
    @Field(key: "name") var name: String
    @Field(key: "name_key") var nameKey: String
    @Field(key: "secret_hash") var secretHash: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}

final class GroupPollAnswerRecord: Model, @unchecked Sendable {
    static let schema = "group_poll_answers"
    @ID(key: .id) var id: UUID?
    @Field(key: "poll_id") var pollId: UUID
    @Field(key: "vote_id") var voteId: UUID
    @Field(key: "option_id") var optionId: UUID
    /// `yes` or `maybe`; "no" is stored as the absence of a row.
    @Field(key: "answer") var answer: String
    init() {}
}

final class GroupOrderRecord: Model, @unchecked Sendable {
    static let schema = "group_orders"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "title") var title: String
    @OptionalField(key: "note") var note: String?
    @OptionalField(key: "deadline") var deadline: Date?
    @OptionalField(key: "closed_at") var closedAt: Date?
    @OptionalField(key: "catalog_id") var catalogId: UUID?
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
    func isClosed(_ now: Date) -> Bool { closedAt != nil || (deadline.map { $0 <= now } ?? false) }
}

final class GroupOrderEntryRecord: Model, @unchecked Sendable {
    static let schema = "group_order_entries"
    @ID(key: .id) var id: UUID?
    @Field(key: "order_id") var orderId: UUID
    @Field(key: "name") var name: String
    @Field(key: "item") var item: String
    @OptionalField(key: "note") var note: String?
    @Field(key: "quantity") var quantity: Int
    @OptionalField(key: "price_cents") var priceCents: Int?
    @Field(key: "secret_hash") var secretHash: String
    @OptionalField(key: "source_entry_id") var sourceEntryId: UUID?
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}

final class GroupCatalogRecord: Model, @unchecked Sendable {
    static let schema = "group_catalogs"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "name") var name: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}

final class GroupCatalogItemRecord: Model, @unchecked Sendable {
    static let schema = "group_catalog_items"
    @ID(key: .id) var id: UUID?
    @Field(key: "catalog_id") var catalogId: UUID
    @Field(key: "position") var position: Int
    @Field(key: "name") var name: String
    @OptionalField(key: "price_cents") var priceCents: Int?
    init() {}
}

/// Single migration for the whole module. Child rows reference their parent with `ON DELETE CASCADE`; the code deletes children
/// explicitly as well (`GroupPurge`), so the result does not depend on the driver enforcing foreign keys.
struct CreateGroups: AsyncMigration {
    let name = "g1.create_groups"
    func prepare(on db: any Database) async throws {
        try await db.schema("group_polls").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("token_hash", .string, .required)
            .field("title", .string, .required)
            .field("description", .sql(unsafeRaw: "TEXT"))
            .field("kind", .string, .required)
            .field("choice_mode", .string, .required)
            .field("time_zone", .string)
            .field("deadline", .datetime)
            .field("hide_results", .bool, .required)
            .field("closed_at", .datetime)
            .field("final_option_id", .uuid)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .unique(on: "token_hash")
            .create()
        try await db.schema("group_poll_options").id()
            .field("poll_id", .uuid, .required, .references("group_polls", "id", onDelete: .cascade))
            .field("position", .int, .required)
            .field("label", .string)
            .field("slot_date", .string)
            .field("start_time", .string)
            .field("end_time", .string)
            .create()
        try await db.schema("group_poll_votes").id()
            .field("poll_id", .uuid, .required, .references("group_polls", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("name_key", .string, .required)
            .field("secret_hash", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()
        try await db.schema("group_poll_answers").id()
            .field("poll_id", .uuid, .required, .references("group_polls", "id", onDelete: .cascade))
            .field("vote_id", .uuid, .required, .references("group_poll_votes", "id", onDelete: .cascade))
            .field("option_id", .uuid, .required, .references("group_poll_options", "id", onDelete: .cascade))
            .field("answer", .string, .required)
            .unique(on: "vote_id", "option_id")
            .create()
        try await db.schema("group_orders").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("token_hash", .string, .required)
            .field("title", .string, .required)
            .field("note", .sql(unsafeRaw: "TEXT"))
            .field("deadline", .datetime)
            .field("closed_at", .datetime)
            .field("catalog_id", .uuid)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .unique(on: "token_hash")
            .create()
        try await db.schema("group_order_entries").id()
            .field("order_id", .uuid, .required, .references("group_orders", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("item", .string, .required)
            .field("note", .string)
            .field("quantity", .int, .required)
            .field("price_cents", .int)
            .field("secret_hash", .string, .required)
            .field("source_entry_id", .uuid)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()
        try await db.schema("group_catalogs").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("name", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()
        try await db.schema("group_catalog_items").id()
            .field("catalog_id", .uuid, .required, .references("group_catalogs", "id", onDelete: .cascade))
            .field("position", .int, .required)
            .field("name", .string, .required)
            .field("price_cents", .int)
            .create()
        let sql = try requireSQL(db)
        try await sql.create(index: "idx_group_polls_account").on("group_polls").column("account_id").run()
        try await sql.create(index: "idx_group_poll_options_poll").on("group_poll_options").column("poll_id").run()
        try await sql.create(index: "idx_group_poll_votes_poll").on("group_poll_votes").column("poll_id").run()
        try await sql.create(index: "idx_group_poll_answers_poll").on("group_poll_answers").column("poll_id").run()
        try await sql.create(index: "idx_group_orders_account").on("group_orders").column("account_id").run()
        try await sql.create(index: "idx_group_order_entries_order").on("group_order_entries").column("order_id").run()
        try await sql.create(index: "idx_group_catalogs_account").on("group_catalogs").column("account_id").run()
        try await sql.create(index: "idx_group_catalog_items_catalog").on("group_catalog_items").column("catalog_id").run()
    }
    func revert(on db: any Database) async throws {
        for table in ["group_catalog_items", "group_catalogs", "group_order_entries", "group_orders", "group_poll_answers",
                      "group_poll_votes", "group_poll_options", "group_polls"] {
            try await db.schema(table).delete()
        }
    }
}

/// Explicit, ordered deletion of poll and order trees (account erasure, owner delete, retention job).
enum GroupPurge {
    static func polls(_ ids: [UUID], on db: any Database) async throws {
        for chunk in ids.chunked(400) {
            try await GroupPollAnswerRecord.query(on: db).filter(\.$pollId ~~ chunk).delete()
            try await GroupPollVoteRecord.query(on: db).filter(\.$pollId ~~ chunk).delete()
            try await GroupPollOptionRecord.query(on: db).filter(\.$pollId ~~ chunk).delete()
            try await GroupPollRecord.query(on: db).filter(\._$id ~~ chunk).delete()
        }
    }
    static func orders(_ ids: [UUID], on db: any Database) async throws {
        for chunk in ids.chunked(400) {
            try await GroupOrderEntryRecord.query(on: db).filter(\.$orderId ~~ chunk).delete()
            try await GroupOrderRecord.query(on: db).filter(\._$id ~~ chunk).delete()
        }
    }
    static func catalogs(_ ids: [UUID], on db: any Database) async throws {
        for chunk in ids.chunked(400) {
            try await GroupOrderRecord.query(on: db).filter(\.$catalogId ~~ chunk).set(\.$catalogId, to: nil).update()
            try await GroupCatalogItemRecord.query(on: db).filter(\.$catalogId ~~ chunk).delete()
            try await GroupCatalogRecord.query(on: db).filter(\._$id ~~ chunk).delete()
        }
    }
}
