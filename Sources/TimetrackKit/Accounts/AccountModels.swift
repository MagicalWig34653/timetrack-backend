import Foundation
import Fluent
import Vapor

/// Audit trail of account administration (ADR-0016). Holds only opaque ids and fixed action names, never personal
/// content, so it may outlive the account it refers to. There are deliberately no foreign keys.
final class AccountAuditRecord: Model, @unchecked Sendable {
    static let schema = "account_audit"
    @ID(key: .id) var id: UUID?
    @Field(key: "occurred_at") var occurredAt: Date
    @Field(key: "action") var action: String
    @Field(key: "actor_id") var actorId: UUID
    @Field(key: "target_id") var targetId: UUID
    @OptionalField(key: "detail") var detail: String?
    init() {}
    init(action: String, actor: UUID, target: UUID, detail: String? = nil, at date: Date = Date()) {
        id = UUID(); occurredAt = date; self.action = action; actorId = actor; targetId = target; self.detail = detail
    }
}

enum AccountSchema {
    static let migrations: [any Migration] = [CreateAccountAudit(), AddAccountOnboarding(), CreateEmailChangeRequests()]
}

struct CreateAccountAudit: AsyncMigration {
    let name = "b1.create_account_audit"
    func prepare(on db: any Database) async throws {
        try await db.schema(AccountAuditRecord.schema).id()
            .field("occurred_at", .datetime, .required)
            .field("action", .string, .required)
            .field("actor_id", .uuid, .required)
            .field("target_id", .uuid, .required)
            .field("detail", .string)
            .create()
        try await requireSQL(db).create(index: "idx_account_audit_target").on(AccountAuditRecord.schema).column("target_id").run()
    }
    func revert(on db: any Database) async throws { try await db.schema(AccountAuditRecord.schema).delete() }
}

// MARK: DTOs

/// Identity, state and activity only. Never any time, absence, report or share data.
struct AdminAccountDTO: Content, Equatable {
    var id: UUID
    var handle: String
    var displayName: String
    var email: String?
    var role: AccountRole
    /// `active` or `disabled`.
    var state: String
    var createdAt: Date
    var disabledAt: Date?
    var lastActivityAt: Date?
    var passkeyCount: Int
}

struct AdminAccountPage: Content, Equatable {
    var items: [AdminAccountDTO]
    var total: Int
    var limit: Int
    var offset: Int
}

struct AdminAccountPatch: Content {
    var role: AccountRole?
    /// `active` or `disabled`.
    var state: String?
}

/// The caller must type the handle of the account that is about to be deleted.
struct AccountDeletionConfirm: Content {
    var confirmHandle: String
}
