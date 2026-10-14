import Foundation
import Fluent
import Vapor

// MARK: Authentication seam (connected to the OAuth/token package by a single adapter)

/// The authenticated caller of `/mcp`: an account plus the scopes of the presented credential.
struct McpAuthPrincipal: Sendable {
    enum Kind: String, Sendable { case oauthAccess = "oauth_access", personal }
    var accountId: UUID
    var scopes: Set<String>
    var credentialKind: Kind
    var credentialId: UUID
}

protocol McpAuthenticator: Sendable {
    /// Returns nil for unknown, expired, revoked or wrong-audience tokens. Must not throw for plain invalid tokens.
    func authenticate(token: String, db: any Database) async throws -> McpAuthPrincipal?
}

/// Default until the OAuth/token package is connected: every token is invalid, so `/mcp` answers 401.
struct RejectingMcpAuthenticator: McpAuthenticator {
    func authenticate(token: String, db: any Database) async throws -> McpAuthPrincipal? { nil }
}

struct McpAuthenticatorKey: StorageKey { typealias Value = any McpAuthenticator }
extension Application {
    /// Replaceable at runtime so tests (and the production adapter) can install an authenticator after `configure`.
    var mcpAuthenticator: (any McpAuthenticator)? {
        get { storage[McpAuthenticatorKey.self] }
        set { storage[McpAuthenticatorKey.self] = newValue }
    }
}

// MARK: Audit

/// One row per authenticated tool call. Deliberately contains no arguments, results or account data.
final class McpAuditRecord: Model, @unchecked Sendable {
    static let schema = "mcp_audit"
    @ID(key: .id) var id: UUID?
    @Field(key: "occurred_at") var occurredAt: Date
    @Field(key: "credential_kind") var credentialKind: String
    @Field(key: "credential_id") var credentialId: UUID
    @Field(key: "tool") var tool: String
    @Field(key: "ok") var ok: Bool
    @Field(key: "duration_ms") var durationMs: Int
    init() {}
    init(credential: McpAuthPrincipal, tool: String, ok: Bool, durationMs: Int, at date: Date = Date()) {
        occurredAt = date; credentialKind = credential.credentialKind.rawValue; credentialId = credential.credentialId
        self.tool = tool; self.ok = ok; self.durationMs = durationMs
    }
}

enum McpSchemaMigrations {
    static let migrations: [any Migration] = [CreateMcpAudit()]
}

struct CreateMcpAudit: AsyncMigration {
    let name = "stage4b.create_mcp_audit"
    func prepare(on db: any Database) async throws {
        try await db.schema("mcp_audit").id()
            .field("occurred_at", .datetime, .required)
            .field("credential_kind", .string, .required)
            .field("credential_id", .uuid, .required)
            .field("tool", .string, .required)
            .field("ok", .bool, .required)
            .field("duration_ms", .int, .required)
            .create()
        try await requireSQL(db).create(index: "idx_mcp_audit_occurred_at").on("mcp_audit").column("occurred_at").run()
    }
    func revert(on db: any Database) async throws { try await db.schema("mcp_audit").delete() }
}

// MARK: Rate limit

enum McpRateLimit {
    static let limit = 120          // requests per credential
    static let window: TimeInterval = 300
    /// Records the request; returns false once the credential exceeded its budget. Counts per credential, never per account.
    static func allow(_ principal: McpAuthPrincipal, auth: AuthService, db: any Database, limit: Int = McpRateLimit.limit) async throws -> Bool {
        try await auth.transaction(on: db) { tx in
            let key = "mcp:" + principal.credentialKind.rawValue + ":" + principal.credentialId.uuidString
            let now = Date()
            if try await RateLimitEvent.query(on: tx).filter(\.$key == key).filter(\.$occurredAt > now.addingTimeInterval(-window)).count() >= limit { return false }
            try await RateLimitEvent(key: key, occurredAt: now).create(on: tx)
            try await RateLimitEvent.query(on: tx).filter(\.$key == key).filter(\.$occurredAt < now.addingTimeInterval(-2 * window)).delete()
            return true
        }
    }
}

/// Overrides the per-credential budget (tests).
struct McpRateLimitKey: StorageKey { typealias Value = Int }
