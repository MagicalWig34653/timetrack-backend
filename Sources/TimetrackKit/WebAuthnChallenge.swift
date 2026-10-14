import Foundation
import Fluent

public final class WebAuthnChallenge: Model, @unchecked Sendable {
    public static let schema = "webauthn_challenges"
    @ID(key: .id) public var id: UUID?
    @Field(key: "purpose") public var purpose: ChallengePurpose
    @Field(key: "challenge") public var challenge: Data
    @Field(key: "payload") public var payload: [String: JSONValue]
    @OptionalField(key: "account_id") public var accountId: UUID?
    @OptionalField(key: "invitation_id") public var invitationId: UUID?
    @Field(key: "expires_at") public var expiresAt: Date
    @OptionalField(key: "consumed_at") public var consumedAt: Date?

    public init() {}

    public init(id: UUID? = nil, purpose: ChallengePurpose, challenge: Data, payload: [String: JSONValue], accountId: UUID? = nil, invitationId: UUID? = nil, expiresAt: Date, consumedAt: Date? = nil) {
        self.id = id
        self.purpose = purpose
        self.challenge = challenge
        self.payload = payload
        self.accountId = accountId
        self.invitationId = invitationId
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
    }
}
