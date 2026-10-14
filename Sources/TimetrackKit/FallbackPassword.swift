import Foundation
import Fluent

public final class FallbackPassword: Model, @unchecked Sendable {
    public static let schema = "fallback_passwords"
    @ID(key: .id) public var id: UUID?
    @Field(key: "account_id") public var accountId: UUID
    @Field(key: "hash") public var hash: String
    @Field(key: "algorithm") public var algorithm: String
    @Field(key: "updated_at") public var updatedAt: Date

    public init() {}

    public init(id: UUID? = nil, accountId: UUID, hash: String, algorithm: String, updatedAt: Date) {
        self.id = id
        self.accountId = accountId
        self.hash = hash
        self.algorithm = algorithm
        self.updatedAt = updatedAt
    }
}
