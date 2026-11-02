import Foundation
import Fluent

/// The seven MCP scopes of ADR-0009.
enum McpScopes {
    static let all: [String] = ["time:read", "time:write", "schedule:read", "schedule:write", "reports:read", "reports:write", "documents:read"]
    static let known = Set(all)
    /// Scopes pre-selected on the consent page when the client does not ask for any (read-only; write scopes must be allowed explicitly).
    static let readOnly: [String] = all.filter { $0.hasSuffix(":read") }
}

/// Dynamically registered public client (RFC 7591).
final class OAuthClient: Model, @unchecked Sendable {
    static let schema = "oauth_clients"
    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "redirect_uris") var redirectURIs: [String]
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?
    init() {}
}

/// One pending authorization request (10 minutes), bound to the first session that opens it.
final class OAuthRequestRecord: Model, @unchecked Sendable {
    static let schema = "oauth_requests"
    @ID(key: .id) var id: UUID?
    @Field(key: "client_id") var clientId: UUID
    @OptionalField(key: "account_id") var accountId: UUID?
    @Field(key: "redirect_uri") var redirectURI: String
    /// Pre-selected scopes: the requested ones, or the read-only scopes when the client sent none.
    @Field(key: "scopes") var scopes: [String]
    /// Scopes the client asked for (`scope` parameter); empty when it sent none. NULL for rows from before 0.44.0.
    @OptionalField(key: "requested_scopes") var requestedScopes: [String]?
    /// Scopes the person may grant on the consent page. NULL (rows from before 0.44.0) means exactly `scopes`.
    @OptionalField(key: "available_scopes") var availableScopes: [String]?
    @OptionalField(key: "state") var state: String?
    @Field(key: "code_challenge") var codeChallenge: String
    @Field(key: "resource") var resource: String
    /// Hash of the session token that first opened the request.
    @OptionalField(key: "binding_hash") var bindingHash: String?
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "decided_at") var decidedAt: Date?
    init() {}
}

/// Authorization code; only the hash is stored.
final class OAuthCode: Model, @unchecked Sendable {
    static let schema = "oauth_codes"
    @ID(key: .id) var id: UUID?
    @Field(key: "code_hash") var codeHash: String
    @Field(key: "client_id") var clientId: UUID
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "grant_id") var grantId: UUID
    @Field(key: "scopes") var scopes: [String]
    @Field(key: "redirect_uri") var redirectURI: String
    @Field(key: "code_challenge") var codeChallenge: String
    @Field(key: "resource") var resource: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "consumed_at") var consumedAt: Date?
    init() {}
}

final class OAuthGrant: Model, @unchecked Sendable {
    static let schema = "oauth_grants"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "client_id") var clientId: UUID
    @Field(key: "scopes") var scopes: [String]
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?
    init() {}
}

/// Access or refresh token of a grant; only the SHA-256 hash is stored.
final class OAuthToken: Model, @unchecked Sendable {
    static let schema = "oauth_tokens"
    @ID(key: .id) var id: UUID?
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "kind") var kind: String
    @Field(key: "grant_id") var grantId: UUID
    @Field(key: "scopes") var scopes: [String]
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    /// Set when a refresh token has been rotated; presenting it again is reuse.
    @OptionalField(key: "used_at") var usedAt: Date?
    /// Refresh token this one was rotated from.
    @OptionalField(key: "parent_id") var parentId: UUID?
    init() {}
}

final class ApiTokenRecord: Model, @unchecked Sendable {
    static let schema = "api_tokens"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "name") var name: String
    @Field(key: "scopes") var scopes: [String]
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    init() {}
}
