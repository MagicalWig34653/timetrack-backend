import Foundation
import Fluent

enum OIDCPurpose: String, Codable, Sendable { case login, link, register }

/// Server-side state of one authorization request (10 minutes, single use). The state value itself is stored hashed.
final class OIDCState: Model, @unchecked Sendable {
    static let schema = "oidc_states"
    @ID(key: .id) var id: UUID?
    @Field(key: "state_hash") var stateHash: String
    @Field(key: "nonce") var nonce: String
    /// PKCE verifier; cleared once the state is consumed.
    @Field(key: "code_verifier") var codeVerifier: String
    @Field(key: "purpose") var purpose: String
    @OptionalField(key: "invite_id") var inviteId: UUID?
    /// Needed for the PWA redirect `/invite/<token>`; cleared once the state is consumed.
    @OptionalField(key: "invite_token") var inviteToken: String?
    @OptionalField(key: "account_id") var accountId: UUID?
    /// Hash of the browser binding cookie (login CSRF protection).
    @Field(key: "binding_hash") var bindingHash: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "consumed_at") var consumedAt: Date?
    init() {}
    init(stateHash: String, nonce: String, codeVerifier: String, purpose: OIDCPurpose, inviteId: UUID?, inviteToken: String?,
         accountId: UUID?, bindingHash: String, createdAt: Date, expiresAt: Date) {
        self.stateHash = stateHash; self.nonce = nonce; self.codeVerifier = codeVerifier; self.purpose = purpose.rawValue
        self.inviteId = inviteId; self.inviteToken = inviteToken; self.accountId = accountId; self.bindingHash = bindingHash
        self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}

final class ExternalIdentity: Model, @unchecked Sendable {
    static let schema = "external_identities"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "issuer") var issuer: String
    @Field(key: "subject") var subject: String
    /// Display hint only; never a linking criterion.
    @OptionalField(key: "email_hint") var emailHint: String?
    @Field(key: "linked_at") var linkedAt: Date
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?
    init() {}
    init(id: UUID? = nil, accountId: UUID, issuer: String, subject: String, emailHint: String?, linkedAt: Date, lastUsedAt: Date? = nil) {
        self.id = id; self.accountId = accountId; self.issuer = issuer; self.subject = subject
        self.emailHint = emailHint; self.linkedAt = linkedAt; self.lastUsedAt = lastUsedAt
    }
}

/// Verified provider identity waiting for the user to choose handle and display name (10 minutes, single use).
final class OIDCPendingRegistration: Model, @unchecked Sendable {
    static let schema = "oidc_pending_registrations"
    @ID(key: .id) var id: UUID?
    @Field(key: "issuer") var issuer: String
    @Field(key: "subject") var subject: String
    @OptionalField(key: "email_hint") var emailHint: String?
    @Field(key: "invitation_id") var invitationId: UUID
    @Field(key: "binding_hash") var bindingHash: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "consumed_at") var consumedAt: Date?
    init() {}
    init(issuer: String, subject: String, emailHint: String?, invitationId: UUID, bindingHash: String, createdAt: Date, expiresAt: Date) {
        self.issuer = issuer; self.subject = subject; self.emailHint = emailHint; self.invitationId = invitationId
        self.bindingHash = bindingHash; self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}
