import Foundation
import Fluent

public final class Account: Model, @unchecked Sendable {
    public static let schema = "accounts"
    @ID(key: .id) public var id: UUID?
    @Field(key: "handle") public var handle: String
    @Field(key: "display_name") public var displayName: String
    @OptionalField(key: "email") public var email: String?
    @OptionalField(key: "email_verified_at") public var emailVerifiedAt: Date?
    @Field(key: "role") public var role: AccountRole
    @Field(key: "created_at") public var createdAt: Date
    @OptionalField(key: "disabled_at") public var disabledAt: Date?

    public init() {}

    public init(id: UUID? = nil, handle: String, displayName: String, email: String? = nil, emailVerifiedAt: Date? = nil, role: AccountRole, createdAt: Date, disabledAt: Date? = nil) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.email = email
        self.emailVerifiedAt = emailVerifiedAt
        self.role = role
        self.createdAt = createdAt
        self.disabledAt = disabledAt
    }
}
