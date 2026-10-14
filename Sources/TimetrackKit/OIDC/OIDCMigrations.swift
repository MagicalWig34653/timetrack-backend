import Fluent
import FluentSQL
import FluentMySQLDriver

public enum OIDCSchema {
    public static let migrations: [any Migration] = [CreateOIDCState(), CreateExternalIdentity(), CreateOIDCPendingRegistration()]
}

private func binaryCollation(_ database: any Database, _ table: String) async throws {
    if database is any MySQLDatabase {
        try await requireSQL(database).raw("ALTER TABLE \(ident: table) CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
    }
}

struct CreateOIDCState: AsyncMigration {
    let name = "oidc.create_oidc_states"
    func prepare(on database: any Database) async throws {
        try await database.schema("oidc_states").id()
            .field("state_hash", .string, .required)
            .field("nonce", .string, .required)
            .field("code_verifier", .string, .required)
            .field("purpose", .string, .required)
            .field("invite_id", .uuid, .references("invitations", "id", onDelete: .restrict))
            .field("invite_token", .string)
            .field("account_id", .uuid, .references("accounts", "id", onDelete: .restrict))
            .field("binding_hash", .string, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .field("consumed_at", .datetime)
            .unique(on: "state_hash")
            .constraint(.sql(unsafeRaw: "CHECK (purpose IN ('login', 'link', 'register'))"))
            .create()
        try await binaryCollation(database, "oidc_states")
        try await requireSQL(database).create(index: "idx_oidc_states_expires_at").on("oidc_states").column("expires_at").run()
    }
    func revert(on database: any Database) async throws { try await database.schema("oidc_states").delete() }
}

struct CreateExternalIdentity: AsyncMigration {
    let name = "oidc.create_external_identities"
    func prepare(on database: any Database) async throws {
        try await database.schema("external_identities").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("issuer", .string, .required)
            .field("subject", .string, .required)
            .field("email_hint", .string)
            .field("linked_at", .datetime, .required)
            .field("last_used_at", .datetime)
            .unique(on: "issuer", "subject")
            .create()
        try await binaryCollation(database, "external_identities")
        try await requireSQL(database).create(index: "idx_external_identities_account_id").on("external_identities").column("account_id").run()
    }
    func revert(on database: any Database) async throws { try await database.schema("external_identities").delete() }
}

struct CreateOIDCPendingRegistration: AsyncMigration {
    let name = "oidc.create_oidc_pending_registrations"
    func prepare(on database: any Database) async throws {
        try await database.schema("oidc_pending_registrations").id()
            .field("issuer", .string, .required)
            .field("subject", .string, .required)
            .field("email_hint", .string)
            .field("invitation_id", .uuid, .required, .references("invitations", "id", onDelete: .restrict))
            .field("binding_hash", .string, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .field("consumed_at", .datetime)
            .create()
        try await binaryCollation(database, "oidc_pending_registrations")
        try await requireSQL(database).create(index: "idx_oidc_pending_expires_at").on("oidc_pending_registrations").column("expires_at").run()
    }
    func revert(on database: any Database) async throws { try await database.schema("oidc_pending_registrations").delete() }
}
