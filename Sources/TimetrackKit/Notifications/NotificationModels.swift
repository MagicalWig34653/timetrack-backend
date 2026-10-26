import Foundation
import Fluent
import FluentSQL
import FluentMySQLDriver

/// In-app notification (ADR-0010). `deletedAt` is a soft delete so the dedup key keeps preventing re-creation.
final class NotificationRecord: Model, @unchecked Sendable {
    static let schema = "notifications"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "title") var title: String
    @Field(key: "body") var body: String
    @OptionalField(key: "url") var url: String?
    @Field(key: "dedup_key") var dedupKey: String
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "read_at") var readAt: Date?
    @OptionalField(key: "deleted_at") var deletedAt: Date?
    init() {}
}

final class NotificationSettingsRecord: Model, @unchecked Sendable {
    static let schema = "notification_settings"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "settings") var settings: NotificationSettingsDTO
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}

final class PushSubscriptionRecord: Model, @unchecked Sendable {
    static let schema = "push_subscriptions"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "endpoint_hash") var endpointHash: String
    @Field(key: "endpoint") var endpoint: String
    @Field(key: "p256dh") var p256dh: String
    @Field(key: "auth") var auth: String
    @OptionalField(key: "user_agent") var userAgent: String?
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "last_success_at") var lastSuccessAt: Date?
    @Field(key: "failure_count") var failureCount: Int
    init() {}
}

final class PushOutboxRecord: Model, @unchecked Sendable {
    static let schema = "push_outbox"
    @ID(key: .id) var id: UUID?
    @Field(key: "notification_id") var notificationId: UUID
    @Field(key: "subscription_id") var subscriptionId: UUID
    @OptionalField(key: "claim_token") var claimToken: String?
    @OptionalField(key: "claimed_at") var claimedAt: Date?
    @OptionalField(key: "completed_at") var completedAt: Date?
    /// pending | sent | failed | deferred
    @Field(key: "status") var status: String
    @Field(key: "attempts") var attempts: Int
    @Field(key: "next_attempt_at") var nextAttemptAt: Date
    @OptionalField(key: "error_code") var errorCode: String?
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

final class JobLeaseRecord: Model, @unchecked Sendable {
    static let schema = "job_leases"
    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "holder") var holder: String
    @Field(key: "expires_at") var expiresAt: Date
    init() {}
}

public enum NotificationSchema {
    public static let migrations: [any Migration] = [
        CreateNotifications(), CreateNotificationSettings(), CreatePushSubscriptions(), CreatePushOutbox(), CreateJobLeases(), HardenPushOutbox(), CreateApnsDevices(),
    ]
}

private func binaryCollation(_ database: any Database, _ table: String) async throws {
    if database is any MySQLDatabase {
        try await requireSQL(database).raw("ALTER TABLE \(ident: table) CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
    }
}
private func varchar(_ size: Int) -> DatabaseSchema.DataType { .sql(unsafeRaw: "VARCHAR(\(size))") }

struct CreateNotifications: AsyncMigration {
    let name = "notifications.create_notifications"
    func prepare(on database: any Database) async throws {
        try await database.schema("notifications").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("kind", .string, .required)
            .field("title", varchar(200), .required)
            .field("body", varchar(1000), .required)
            .field("url", varchar(255))
            .field("dedup_key", varchar(190), .required)
            .field("created_at", .datetime, .required)
            .field("read_at", .datetime)
            .field("deleted_at", .datetime)
            .unique(on: "account_id", "dedup_key")
            .create()
        try await binaryCollation(database, "notifications")
        try await requireSQL(database).create(index: "idx_notifications_account_created").on("notifications").column("account_id").column("created_at").run()
    }
    func revert(on database: any Database) async throws { try await database.schema("notifications").delete() }
}

struct CreateNotificationSettings: AsyncMigration {
    let name = "notifications.create_notification_settings"
    func prepare(on database: any Database) async throws {
        try await database.schema("notification_settings").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("settings", .json, .required)
            .field("updated_at", .datetime, .required)
            .unique(on: "account_id")
            .create()
    }
    func revert(on database: any Database) async throws { try await database.schema("notification_settings").delete() }
}

struct CreatePushSubscriptions: AsyncMigration {
    let name = "notifications.create_push_subscriptions"
    func prepare(on database: any Database) async throws {
        try await database.schema("push_subscriptions").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("endpoint_hash", varchar(64), .required)
            .field("endpoint", varchar(2048), .required)
            .field("p256dh", varchar(128), .required)
            .field("auth", varchar(64), .required)
            .field("user_agent", varchar(200))
            .field("created_at", .datetime, .required)
            .field("last_success_at", .datetime)
            .field("failure_count", .int, .required)
            .unique(on: "account_id", "endpoint_hash")
            .create()
        try await binaryCollation(database, "push_subscriptions")
    }
    func revert(on database: any Database) async throws { try await database.schema("push_subscriptions").delete() }
}

struct CreatePushOutbox: AsyncMigration {
    let name = "notifications.create_push_outbox"
    func prepare(on database: any Database) async throws {
        try await database.schema("push_outbox").id()
            .field("notification_id", .uuid, .required, .references("notifications", "id", onDelete: .restrict))
            .field("subscription_id", .uuid, .required, .references("push_subscriptions", "id", onDelete: .restrict))
            .field("status", .string, .required)
            .field("attempts", .int, .required)
            .field("next_attempt_at", .datetime, .required)
            .field("error_code", .string)
            .field("created_at", .datetime, .required)
            .unique(on: "notification_id", "subscription_id")
            .create()
        try await requireSQL(database).create(index: "idx_push_outbox_due").on("push_outbox").column("status").column("next_attempt_at").run()
    }
    func revert(on database: any Database) async throws { try await database.schema("push_outbox").delete() }
}

struct CreateJobLeases: AsyncMigration {
    let name = "notifications.create_job_leases"
    func prepare(on database: any Database) async throws {
        try await database.schema("job_leases").id()
            .field("name", varchar(100), .required)
            .field("holder", varchar(100), .required)
            .field("expires_at", .datetime, .required)
            .unique(on: "name")
            .create()
        try await binaryCollation(database, "job_leases")
    }
    func revert(on database: any Database) async throws { try await database.schema("job_leases").delete() }
}

struct HardenPushOutbox: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("push_outbox").field("claim_token", .string).update()
        try await db.schema("push_outbox").field("claimed_at", .datetime).update()
        try await db.schema("push_outbox").field("completed_at", .datetime).update()
        try await requireSQL(db).raw("UPDATE push_outbox SET completed_at = created_at WHERE status IN ('sent', 'failed')").run()
    }
    func revert(on db: any Database) async throws {
        for field in ["claim_token", "claimed_at", "completed_at"] {
            try await db.schema("push_outbox").deleteField(FieldKey(stringLiteral: field)).update()
        }
    }
}
