import Foundation
import Fluent

public enum CredentialKind: String, Sendable { case oauthAccess, personal }

/// Authenticated caller of `/mcp`. `credentialId` is the OAuth grant id for `.oauthAccess` and the API token id for `.personal`.
public struct McpPrincipal: Sendable {
    public let accountId: UUID
    public let scopes: Set<String>
    public let credentialKind: CredentialKind
    public let credentialId: UUID
    public init(accountId: UUID, scopes: Set<String>, credentialKind: CredentialKind, credentialId: UUID) {
        self.accountId = accountId; self.scopes = scopes; self.credentialKind = credentialKind; self.credentialId = credentialId
    }
}

/// Resolves a `tto_` (OAuth access) or `ttp_` (personal) bearer token. Returns nil for unknown, malformed, expired, revoked
/// or disabled-account credentials. These tokens are only valid for `/mcp` (audience is implicit); they are not session credentials.
/// `last_used_at` is updated at most once per minute.
public func authenticateMcpBearer(_ token: String, on db: any Database, now: Date = Date(), disabledModules: Set<ModuleKey> = []) async throws -> McpPrincipal? {
    guard token.count == OAuthTokenFormat.length, token.utf8.allSatisfy({ $0 < 128 }) else { return nil }
    let hash = Secrets.hash(token)
    let stale = now.addingTimeInterval(-OAuthTokenFormat.lastUsedThrottle)
    if token.hasPrefix(OAuthTokenFormat.accessPrefix) {
        guard let record = try await OAuthToken.query(on: db).filter(\.$tokenHash == hash).first(), record.kind == "access",
              record.revokedAt == nil, record.expiresAt > now,
              let grant = try await OAuthGrant.find(record.grantId, on: db), grant.revokedAt == nil,
              let account = try await Account.find(grant.accountId, on: db), account.disabledAt == nil else { return nil }
        guard try await ModuleRegistry(locked: disabledModules).enabled(.mcp, account: grant.accountId, on: db) else { return nil }
        let id = try grant.requireID()
        if grant.lastUsedAt.map({ $0 < stale }) ?? true {
            try await OAuthGrant.query(on: db).filter(\.$id == id).set(\.$lastUsedAt, to: now).update()
        }
        // A grant that was narrowed later takes effect immediately for existing tokens.
        return McpPrincipal(accountId: grant.accountId, scopes: Set(record.scopes).intersection(grant.scopes).intersection(McpScopes.known),
                            credentialKind: .oauthAccess, credentialId: id)
    }
    if token.hasPrefix(OAuthTokenFormat.personalPrefix) {
        guard let record = try await ApiTokenRecord.query(on: db).filter(\.$tokenHash == hash).first(),
              record.revokedAt == nil, record.expiresAt > now,
              let account = try await Account.find(record.accountId, on: db), account.disabledAt == nil else { return nil }
        guard try await ModuleRegistry(locked: disabledModules).enabled(.mcp, account: record.accountId, on: db) else { return nil }
        let id = try record.requireID()
        if record.lastUsedAt.map({ $0 < stale }) ?? true {
            try await ApiTokenRecord.query(on: db).filter(\.$id == id).set(\.$lastUsedAt, to: now).update()
        }
        return McpPrincipal(accountId: record.accountId, scopes: Set(record.scopes).intersection(McpScopes.known),
                            credentialKind: .personal, credentialId: id)
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
