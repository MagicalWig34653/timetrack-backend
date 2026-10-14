import Fluent
import FluentSQL
import FluentMySQLDriver

public enum OAuthSchema {
    public static let migrations: [any Migration] = [
        CreateOAuthClients(), CreateOAuthRequests(), CreateOAuthGrants(), CreateOAuthCodes(), CreateOAuthTokens(), CreateApiTokens(),
    ]
}

private func binaryCollation(_ database: any Database, _ table: String) async throws {
    if database is any MySQLDatabase {
        try await requireSQL(database).raw("ALTER TABLE \(ident: table) CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
    }
}
private func index(_ database: any Database, _ name: String, _ table: String, _ column: String) async throws {
    try await requireSQL(database).create(index: name).on(table).column(column).run()
}
private let uri = DatabaseSchema.DataType.sql(unsafeRaw: "VARCHAR(2048)")

struct CreateOAuthClients: AsyncMigration {
    let name = "oauth.create_oauth_clients"
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_clients").id()
            .field("name", .string, .required)
            .field("redirect_uris", .json, .required)
            .field("created_at", .datetime, .required)
            .field("last_used_at", .datetime)
            .create()
        try await binaryCollation(database, "oauth_clients")
    }
    func revert(on database: any Database) async throws { try await database.schema("oauth_clients").delete() }
}

struct CreateOAuthRequests: AsyncMigration {
    let name = "oauth.create_oauth_requests"
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_requests").id()
            .field("client_id", .uuid, .required, .references("oauth_clients", "id", onDelete: .restrict))
            .field("account_id", .uuid, .references("accounts", "id", onDelete: .restrict))
            .field("redirect_uri", uri, .required)
            .field("scopes", .json, .required)
            .field("state", .sql(unsafeRaw: "VARCHAR(512)"))
            .field("code_challenge", .string, .required)
            .field("resource", .string, .required)
            .field("binding_hash", .string)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .field("decided_at", .datetime)
            .create()
        try await binaryCollation(database, "oauth_requests")
        try await index(database, "idx_oauth_requests_expires_at", "oauth_requests", "expires_at")
        try await index(database, "idx_oauth_requests_client_id", "oauth_requests", "client_id")
    }
    func revert(on database: any Database) async throws { try await database.schema("oauth_requests").delete() }
}

struct CreateOAuthGrants: AsyncMigration {
    let name = "oauth.create_oauth_grants"
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_grants").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("client_id", .uuid, .required, .references("oauth_clients", "id", onDelete: .restrict))
            .field("scopes", .json, .required)
            .field("created_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("last_used_at", .datetime)
            .create()
        try await binaryCollation(database, "oauth_grants")
        try await index(database, "idx_oauth_grants_account_id", "oauth_grants", "account_id")
        try await index(database, "idx_oauth_grants_client_id", "oauth_grants", "client_id")
    }
    func revert(on database: any Database) async throws { try await database.schema("oauth_grants").delete() }
}

struct CreateOAuthCodes: AsyncMigration {
    let name = "oauth.create_oauth_codes"
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_codes").id()
            .field("code_hash", .string, .required)
            .field("client_id", .uuid, .required, .references("oauth_clients", "id", onDelete: .restrict))
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("grant_id", .uuid, .required, .references("oauth_grants", "id", onDelete: .restrict))
            .field("scopes", .json, .required)
            .field("redirect_uri", uri, .required)
            .field("code_challenge", .string, .required)
            .field("resource", .string, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .field("consumed_at", .datetime)
            .unique(on: "code_hash")
            .create()
        try await binaryCollation(database, "oauth_codes")
        try await index(database, "idx_oauth_codes_expires_at", "oauth_codes", "expires_at")
    }
    func revert(on database: any Database) async throws { try await database.schema("oauth_codes").delete() }
}

struct CreateOAuthTokens: AsyncMigration {
    let name = "oauth.create_oauth_tokens"
    func prepare(on database: any Database) async throws {
        try await database.schema("oauth_tokens").id()
            .field("token_hash", .string, .required)
            .field("kind", .string, .required)
            .field("grant_id", .uuid, .required, .references("oauth_grants", "id", onDelete: .restrict))
            .field("scopes", .json, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("used_at", .datetime)
            .field("parent_id", .uuid)
            .unique(on: "token_hash")
            .constraint(.sql(unsafeRaw: "CHECK (kind IN ('access', 'refresh'))"))
            .create()
        try await binaryCollation(database, "oauth_tokens")
        try await index(database, "idx_oauth_tokens_grant_id", "oauth_tokens", "grant_id")
    }
    func revert(on database: any Database) async throws { try await database.schema("oauth_tokens").delete() }
}

struct CreateApiTokens: AsyncMigration {
    let name = "oauth.create_api_tokens"
    func prepare(on database: any Database) async throws {
        try await database.schema("api_tokens").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("name", .string, .required)
            .field("scopes", .json, .required)
            .field("token_hash", .string, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .field("last_used_at", .datetime)
            .field("revoked_at", .datetime)
            .unique(on: "token_hash")
            .create()
        try await binaryCollation(database, "api_tokens")
        try await index(database, "idx_api_tokens_account_id", "api_tokens", "account_id")
    }
    func revert(on database: any Database) async throws { try await database.schema("api_tokens").delete() }
}
