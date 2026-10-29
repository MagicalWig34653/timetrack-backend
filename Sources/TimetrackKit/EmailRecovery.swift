import Foundation
import Fluent

public final class EmailRecovery: Model, @unchecked Sendable {
    public static let schema = "email_recovery"
    @ID(key: .id) public var id: UUID?
    @Field(key: "account_id") public var accountId: UUID
    @Field(key: "email") public var email: String
    @OptionalField(key: "verified_at") public var verifiedAt: Date?
    @Field(key: "active") public var active: Bool

    public init() {}

    public init(id: UUID? = nil, accountId: UUID, email: String, verifiedAt: Date? = nil, active: Bool) {
        self.id = id
        self.accountId = accountId
        self.email = email
        self.verifiedAt = verifiedAt
        self.active = active
    }
}

/// C3 (ADR-0032): the account e-mail is the single address for recovery codes. Existing separate recovery addresses are
/// folded in: a verified account e-mail wins (an active, verified recovery setting is kept and now targets that address, the
/// separate address is dropped); an unverified or missing account e-mail adopts a verified recovery address (unless another
/// account has already verified it); unverified or inactive leftovers are removed.
struct UnifyRecoveryEmail: AsyncMigration {
    let name = "c3.account_email_is_recovery_email"
    func prepare(on db: any Database) async throws {
        for row in try await EmailRecovery.query(on: db).all() {
            guard let account = try await Account.find(row.accountId, on: db) else { try await row.delete(on: db); continue }
            let recoveryVerified = row.verifiedAt != nil
            if let mail = account.email, let verifiedAt = account.emailVerifiedAt {
                if row.active, recoveryVerified { row.email = mail; row.verifiedAt = verifiedAt; try await row.update(on: db) }
                else { try await row.delete(on: db) }
            } else if recoveryVerified {
                let holder = try await Account.query(on: db).filter(\.$email == row.email).filter(\.$emailVerifiedAt != nil)
                    .filter(\.$id != row.accountId).first()
                if holder == nil {
                    account.email = row.email; account.emailVerifiedAt = row.verifiedAt; try await account.update(on: db)
                    try await AccountAuditRecord(action: "profile.email_adopted_from_recovery", actor: row.accountId, target: row.accountId).create(on: db)
                } else { try await row.delete(on: db) }
            } else { try await row.delete(on: db) }
        }
    }
    func revert(on db: any Database) async throws {}
}
