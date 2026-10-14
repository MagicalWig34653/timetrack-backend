import Foundation
import Fluent

public final class RateLimitEvent: Model, @unchecked Sendable {
    public static let schema = "rate_limit_events"
    @ID(key: .id) public var id: UUID?
    @Field(key: "key") public var key: String
    @Field(key: "occurred_at") public var occurredAt: Date

    public init() {}

    public init(id: UUID? = nil, key: String, occurredAt: Date) {
        self.id = id
        self.key = key
        self.occurredAt = occurredAt
    }
}
