import Foundation
import Fluent

public final class RecoveryAttempt: Model, @unchecked Sendable {
    public static let schema = "recovery_attempts"
    @ID(key: .id) public var id: UUID?
    @Field(key: "kind") public var kind: RecoveryKind
    @OptionalField(key: "account_id") public var accountId: UUID?
    @OptionalField(key: "code_hash") public var codeHash: String?
    @OptionalField(key: "proof_hash") public var proofHash: String?
    @Field(key: "expires_at") public var expiresAt: Date
    @OptionalField(key: "consumed_at") public var consumedAt: Date?
    @Field(key: "attempt_count") public var attemptCount: Int
    @Field(key: "created_at") public var createdAt: Date

    public init() {}

    public init(id: UUID? = nil, kind: RecoveryKind, accountId: UUID? = nil, codeHash: String? = nil, proofHash: String? = nil, expiresAt: Date, consumedAt: Date? = nil, attemptCount: Int, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.accountId = accountId
        self.codeHash = codeHash
        self.proofHash = proofHash
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
        self.attemptCount = attemptCount
        self.createdAt = createdAt
    }
}
