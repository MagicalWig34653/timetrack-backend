import Foundation
import Fluent
import Vapor

/// A pending change of the profile e-mail address (ADR-0019). The code is mailed to the new address; only its hash is
/// stored. At most one request per account exists.
final class EmailChangeRequest: Model, @unchecked Sendable {
    static let schema = "email_change_requests"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "email") var email: String
    @Field(key: "code_hash") var codeHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @Field(key: "attempt_count") var attemptCount: Int
    @Field(key: "created_at") var createdAt: Date
    init() {}
    init(accountId: UUID, email: String, codeHash: String, expiresAt: Date, createdAt: Date = Date()) {
        id = UUID(); self.accountId = accountId; self.email = email; self.codeHash = codeHash
        self.expiresAt = expiresAt; attemptCount = 0; self.createdAt = createdAt
    }
}

/// Adds the onboarding flag. Accounts that exist before this migration are marked `skipped`: they must not be pushed
/// through a guided setup they never asked for, and the setup stays reachable from the settings.
struct AddAccountOnboarding: AsyncMigration {
    let name = "p1.add_account_onboarding"
    func prepare(on db: any Database) async throws {
        try await db.schema(Account.schema).field("onboarding_state", .string).update()
        try await db.schema(Account.schema).field("onboarding_updated_at", .datetime).update()
        try await requireSQL(db).raw("UPDATE accounts SET onboarding_state = 'skipped'").run()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(Account.schema).deleteField("onboarding_updated_at").update()
        try await db.schema(Account.schema).deleteField("onboarding_state").update()
    }
}

struct CreateEmailChangeRequests: AsyncMigration {
    let name = "p1.create_email_change_requests"
    func prepare(on db: any Database) async throws {
        try await db.schema(EmailChangeRequest.schema).id()
            .field("account_id", .uuid, .required, .references(Account.schema, "id", onDelete: .restrict))
            .field("email", .string, .required)
            .field("code_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("attempt_count", .int, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "account_id")
            .create()
    }
    func revert(on db: any Database) async throws { try await db.schema(EmailChangeRequest.schema).delete() }
}

// MARK: DTOs

struct OnboardingDTO: Content, Equatable {
    /// `pending`, `completed` or `skipped`.
    var state: String
    var updatedAt: Date?
}

struct ProfileDTO: Content, Equatable {
    var handle: String
    var displayName: String
    var email: String?
    var emailVerified: Bool
    /// Address waiting for its code (only visible to the account itself).
    var pendingEmail: String?
    /// Whether the server can send mail at all; without it the e-mail address cannot be verified.
    var mailAvailable: Bool
    var onboarding: OnboardingDTO
}

struct ProfilePatch: Content { var displayName: String? }
struct EmailChangeInput: Content { var email: String }
struct EmailChangeProof: Content { var code: String }
struct OnboardingInput: Content { var state: String }
