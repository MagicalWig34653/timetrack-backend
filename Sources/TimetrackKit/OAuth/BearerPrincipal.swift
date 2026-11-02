import Foundation
import Fluent

public enum CredentialKind: String, Sendable { case oauthAccess, personal }

/// Authenticated caller of `/mcp`. `credentialId` is the OAuth grant id for `.oauthAccess` and the API token id for `.personal`.
public struct McpPrincipal: Sendable {
    public let accountId: UUID
    public let scopes: Set<String>
    public let credentialKind: CredentialKind
    public let credentialId: UUID
    /// Hash of the presented bearer token; lets the tool transaction resolve exactly this credential again (F03).
    public let tokenHash: String?
    public init(accountId: UUID, scopes: Set<String>, credentialKind: CredentialKind, credentialId: UUID, tokenHash: String? = nil) {
        self.accountId = accountId; self.scopes = scopes; self.credentialKind = credentialKind; self.credentialId = credentialId; self.tokenHash = tokenHash
    }
}

/// Resolves a `tto_` (OAuth access) or `ttp_` (personal) bearer token. Returns nil for unknown, malformed, expired, revoked
/// or disabled-account credentials. These tokens are only valid for `/mcp` (audience is implicit); they are not session credentials.
/// `last_used_at` is updated at most once per minute.
public func authenticateMcpBearer(_ token: String, on db: any Database, now: Date = Date(), disabledModules: Set<ModuleKey> = []) async throws -> McpPrincipal? {
    guard token.count == OAuthTokenFormat.length, token.utf8.allSatisfy({ $0 < 128 }) else { return nil }
    let kind: CredentialKind
    if token.hasPrefix(OAuthTokenFormat.accessPrefix) { kind = .oauthAccess }
    else if token.hasPrefix(OAuthTokenFormat.personalPrefix) { kind = .personal }
    else { return nil }
    return try await resolveMcpCredential(hash: Secrets.hash(token), kind: kind, on: db, now: now, disabledModules: disabledModules, touch: true)
}

/// Resolves the credential of `principal` again (inside the serialized tool transaction): revocation, expiry, account state, module
/// state and the CURRENT scopes are read anew. Returns nil when the credential is no longer valid, and also when the principal
/// carries no token hash (fail closed).
public func revalidateMcpPrincipal(_ principal: McpPrincipal, on db: any Database, now: Date = Date(), disabledModules: Set<ModuleKey> = []) async throws -> McpPrincipal? {
    guard let hash = principal.tokenHash,
          let fresh = try await resolveMcpCredential(hash: hash, kind: principal.credentialKind, on: db, now: now, disabledModules: disabledModules, touch: false),
          fresh.accountId == principal.accountId, fresh.credentialId == principal.credentialId else { return nil }
    return fresh
}

private func resolveMcpCredential(hash: String, kind: CredentialKind, on db: any Database, now: Date, disabledModules: Set<ModuleKey>, touch: Bool) async throws -> McpPrincipal? {
    let stale = now.addingTimeInterval(-OAuthTokenFormat.lastUsedThrottle)
    if kind == .oauthAccess {
        guard let record = try await OAuthToken.query(on: db).filter(\.$tokenHash == hash).first(), record.kind == "access",
              record.revokedAt == nil, record.expiresAt > now,
              let grant = try await OAuthGrant.find(record.grantId, on: db), grant.revokedAt == nil,
              let account = try await Account.find(grant.accountId, on: db), account.disabledAt == nil else { return nil }
        guard try await ModuleRegistry(locked: disabledModules).enabled(.mcp, account: grant.accountId, on: db) else { return nil }
        let id = try grant.requireID()
        if touch, grant.lastUsedAt.map({ $0 < stale }) ?? true {
            try await OAuthGrant.query(on: db).filter(\.$id == id).set(\.$lastUsedAt, to: now).update()
        }
        // A grant that was narrowed later takes effect immediately for existing tokens.
        return McpPrincipal(accountId: grant.accountId, scopes: Set(record.scopes).intersection(grant.scopes).intersection(McpScopes.known),
                            credentialKind: .oauthAccess, credentialId: id, tokenHash: hash)
    }
    if kind == .personal {
        guard let record = try await ApiTokenRecord.query(on: db).filter(\.$tokenHash == hash).first(),
              record.revokedAt == nil, record.expiresAt > now,
              let account = try await Account.find(record.accountId, on: db), account.disabledAt == nil else { return nil }
        guard try await ModuleRegistry(locked: disabledModules).enabled(.mcp, account: record.accountId, on: db) else { return nil }
        let id = try record.requireID()
        if touch, record.lastUsedAt.map({ $0 < stale }) ?? true {
            try await ApiTokenRecord.query(on: db).filter(\.$id == id).set(\.$lastUsedAt, to: now).update()
        }
        return McpPrincipal(accountId: record.accountId, scopes: Set(record.scopes).intersection(McpScopes.known),
                            credentialKind: .personal, credentialId: id, tokenHash: hash)
    }
    return nil
}

enum OAuthTokenFormat {
    static let accessPrefix = "tto_", refreshPrefix = "ttr_", personalPrefix = "ttp_"
    /// Prefix (4) + base64url of 32 random bytes (43).
    static let length = 47
    static let lastUsedThrottle: TimeInterval = 60
    static func make(_ prefix: String) -> String { prefix + Secrets.token(bytes: 32) }
}
