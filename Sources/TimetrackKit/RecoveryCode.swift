import Foundation
import Fluent

public final class RecoveryCode: Model, @unchecked Sendable {
    public static let schema = "recovery_codes"
    @ID(key: .id) public var id: UUID?
    @Field(key: "account_id") public var accountId: UUID
    @Field(key: "code_hash") public var codeHash: String
    @OptionalField(key: "used_at") public var usedAt: Date?

    public init() {}

    public init(id: UUID? = nil, accountId: UUID, codeHash: String, usedAt: Date? = nil) {
        self.id = id
        self.accountId = accountId
        self.codeHash = codeHash
        self.usedAt = usedAt
    }
}
