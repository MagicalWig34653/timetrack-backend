import Foundation
import Fluent

public final class Invitation: Model, @unchecked Sendable {
    public static let schema = "invitations"
    @ID(key: .id) public var id: UUID?
    @Field(key: "token_hash") public var tokenHash: String
    @OptionalField(key: "created_by") public var createdBy: UUID?
    @OptionalField(key: "note") public var note: String?
    @Field(key: "role") public var role: AccountRole
    @Field(key: "created_at") public var createdAt: Date
    @Field(key: "expires_at") public var expiresAt: Date
    @OptionalField(key: "used_at") public var usedAt: Date?
    @OptionalField(key: "used_by") public var usedBy: UUID?
    @OptionalField(key: "revoked_at") public var revokedAt: Date?

    public init() {}

    public init(id: UUID? = nil, tokenHash: String, createdBy: UUID? = nil, note: String? = nil, role: AccountRole, createdAt: Date, expiresAt: Date, usedAt: Date? = nil, usedBy: UUID? = nil, revokedAt: Date? = nil) {
        self.id = id
        self.tokenHash = tokenHash
        self.createdBy = createdBy
        self.note = note
        self.role = role
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.usedAt = usedAt
        self.usedBy = usedBy
        self.revokedAt = revokedAt
    }
}
