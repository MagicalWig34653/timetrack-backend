import Foundation
import Fluent

public final class Passkey: Model, @unchecked Sendable {
    public static let schema = "passkeys"
    @ID(key: .id) public var id: UUID?
    @Field(key: "account_id") public var accountId: UUID
    @Field(key: "credential_id") public var credentialId: Data
    @Field(key: "public_key") public var publicKey: Data
    @Field(key: "sign_count") public var signCount: Int64
    @Field(key: "name") public var name: String
    @Field(key: "transports") public var transports: [String]
    @Field(key: "backed_up") public var backedUp: Bool
    @Field(key: "created_at") public var createdAt: Date
    @OptionalField(key: "last_used_at") public var lastUsedAt: Date?
    @OptionalField(key: "revoked_at") public var revokedAt: Date?

    public init() {}

    public init(id: UUID? = nil, accountId: UUID, credentialId: Data, publicKey: Data, signCount: Int64, name: String, transports: [String], backedUp: Bool, createdAt: Date, lastUsedAt: Date? = nil, revokedAt: Date? = nil) {
        self.id = id
        self.accountId = accountId
        self.credentialId = credentialId
        self.publicKey = publicKey
        self.signCount = signCount
        self.name = name
        self.transports = transports
        self.backedUp = backedUp
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.revokedAt = revokedAt
    }
}
