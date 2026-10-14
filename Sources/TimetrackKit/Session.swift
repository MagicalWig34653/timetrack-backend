import Foundation
import Fluent

public final class Session: Model, @unchecked Sendable {
    public static let schema = "sessions"
    @ID(key: .id) public var id: UUID?
    @Field(key: "account_id") public var accountId: UUID
    @Field(key: "token_hash") public var tokenHash: String
    @Field(key: "csrf_token_hash") public var csrfTokenHash: String
    @Field(key: "recovery") public var recovery: Bool
    @Field(key: "created_at") public var createdAt: Date
    @Field(key: "expires_at") public var expiresAt: Date
    @OptionalField(key: "last_seen_at") public var lastSeenAt: Date?
    @OptionalField(key: "revoked_at") public var revokedAt: Date?

    public init() {}

    public init(id: UUID? = nil, accountId: UUID, tokenHash: String, csrfTokenHash: String, recovery: Bool, createdAt: Date, expiresAt: Date, lastSeenAt: Date? = nil, revokedAt: Date? = nil) {
        self.id = id
        self.accountId = accountId
        self.tokenHash = tokenHash
        self.csrfTokenHash = csrfTokenHash
        self.recovery = recovery
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
    }
}
