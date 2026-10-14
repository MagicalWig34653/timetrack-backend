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
