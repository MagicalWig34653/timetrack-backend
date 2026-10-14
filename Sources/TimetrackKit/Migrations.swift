import Fluent
import FluentSQL
import FluentMySQLDriver

public enum StageOneSchema {
    public static let migrations: [any Migration] = [
        CreateAccount(),
        CreatePasskey(),
        CreateSession(),
        CreateInvitation(),
        CreateWebAuthnChallenge(),
        CreateRecoveryCode(),
        CreateFallbackPassword(),
        CreateEmailRecovery(),
        CreateRecoveryAttempt(),
        CreateRateLimitEvent(),
    ]
}

public struct CreateAccount: AsyncMigration {
    public let name = "stage1.create_accounts"
    public init() {}

    public func prepare(on database: any Database) async throws {
        let schema = database.schema("accounts").id()
            .field("handle", .string, .required)
            .field("display_name", .string, .required)
            .field("email", .string)
            .field("email_verified_at", .datetime)
            .field("role", .string, .required)
            .field("created_at", .datetime, .required)
            .field("disabled_at", .datetime)
            .unique(on: "handle")
            .constraint(.sql(unsafeRaw: "CHECK (length(handle) BETWEEN 3 AND 32)"))
            .constraint(.sql(unsafeRaw: "CHECK (role IN ('admin', 'member'))"))
        if database is any MySQLDatabase {
            schema.constraint(.sql(unsafeRaw: "CHECK (BINARY handle REGEXP '^[a-z0-9][a-z0-9._-]{2,31}$')"))
        } else {
            schema.constraint(.sql(unsafeRaw: "CHECK (handle NOT GLOB '*[^a-z0-9._-]*' AND substr(handle, 1, 1) GLOB '[a-z0-9]')"))
        }
        try await schema.create()
        let sql = try requireSQL(database)
        if database is any MySQLDatabase {
            try await sql.raw("ALTER TABLE \(ident: "accounts") CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
        }
        try await sql.create(index: "idx_accounts_email").on("accounts").column("email").run()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema("accounts").delete()
    }
}

public struct CreatePasskey: AsyncMigration {
    public let name = "stage1.create_passkeys"
    public init() {}

    public func prepare(on database: any Database) async throws {
        let schema = database.schema("passkeys").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("credential_id", .sql(unsafeRaw: "VARBINARY(1024)"), .required)
            .field("public_key", .data, .required)
            .field("sign_count", .int64, .required)
            .field("name", .string, .required)
            .field("transports", .json, .required)
            .field("backed_up", .bool, .required)
            .field("created_at", .datetime, .required)
            .field("last_used_at", .datetime)
            .field("revoked_at", .datetime)
            .unique(on: "credential_id")
            .constraint(.sql(unsafeRaw: "CHECK (sign_count >= 0)"))
            .constraint(.sql(unsafeRaw: "CHECK (length(credential_id) BETWEEN 1 AND 1024)"))
        try await schema.create()
        let sql = try requireSQL(database)
        if database is any MySQLDatabase {
            try await sql.raw("ALTER TABLE \(ident: "passkeys") CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
        }
        try await sql.create(index: "idx_passkeys_account_id").on("passkeys").column("account_id").run()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema("passkeys").delete()
    }
}

public struct CreateSession: AsyncMigration {
    public let name = "stage1.create_sessions"
    public init() {}

    public func prepare(on database: any Database) async throws {
        let schema = database.schema("sessions").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("token_hash", .string, .required)
            .field("csrf_token_hash", .string, .required)
            .field("recovery", .bool, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .field("last_seen_at", .datetime)
            .field("revoked_at", .datetime)
            .unique(on: "token_hash")
        try await schema.create()
        let sql = try requireSQL(database)
        if database is any MySQLDatabase {
            try await sql.raw("ALTER TABLE \(ident: "sessions") CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
        }
        try await sql.create(index: "idx_sessions_account_id").on("sessions").column("account_id").run()
        try await sql.create(index: "idx_sessions_expires_at").on("sessions").column("expires_at").run()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema("sessions").delete()
    }
}

public struct CreateInvitation: AsyncMigration {
    public let name = "stage1.create_invitations"
    public init() {}

    public func prepare(on database: any Database) async throws {
        let schema = database.schema("invitations").id()
            .field("token_hash", .string, .required)
            .field("created_by", .uuid, .references("accounts", "id", onDelete: .restrict))
            .field("note", .string)
            .field("role", .string, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .field("used_by", .uuid, .references("accounts", "id", onDelete: .restrict))
            .field("revoked_at", .datetime)
            .unique(on: "token_hash")
            .constraint(.sql(unsafeRaw: "CHECK (role IN ('admin', 'member'))"))
        try await schema.create()
        let sql = try requireSQL(database)
        if database is any MySQLDatabase {
            try await sql.raw("ALTER TABLE \(ident: "invitations") CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
        }
        try await sql.create(index: "idx_invitations_created_by").on("invitations").column("created_by").run()
        try await sql.create(index: "idx_invitations_used_by").on("invitations").column("used_by").run()
        try await sql.create(index: "idx_invitations_expires_at").on("invitations").column("expires_at").run()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema("invitations").delete()
    }
}

public struct CreateWebAuthnChallenge: AsyncMigration {
    public let name = "stage1.create_webauthn_challenges"
    public init() {}

    public func prepare(on database: any Database) async throws {
        let schema = database.schema("webauthn_challenges").id()
            .field("purpose", .string, .required)
            .field("challenge", .data, .required)
            .field("payload", .json, .required)
            .field("account_id", .uuid, .references("accounts", "id", onDelete: .restrict))
            .field("invitation_id", .uuid, .references("invitations", "id", onDelete: .restrict))
            .field("expires_at", .datetime, .required)
            .field("consumed_at", .datetime)
            .constraint(.sql(unsafeRaw: "CHECK (purpose IN ('registration', 'authentication', 'add_passkey'))"))
        try await schema.create()
        let sql = try requireSQL(database)
        if database is any MySQLDatabase {
            try await sql.raw("ALTER TABLE \(ident: "webauthn_challenges") CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
        }
        try await sql.create(index: "idx_webauthn_challenges_account_id").on("webauthn_challenges").column("account_id").run()
        try await sql.create(index: "idx_webauthn_challenges_invitation_id").on("webauthn_challenges").column("invitation_id").run()
        try await sql.create(index: "idx_webauthn_challenges_expires_at").on("webauthn_challenges").column("expires_at").run()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema("webauthn_challenges").delete()
    }
}

public struct CreateRecoveryCode: AsyncMigration {
    public let name = "stage1.create_recovery_codes"
    public init() {}

    public func prepare(on database: any Database) async throws {
        let schema = database.schema("recovery_codes").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("code_hash", .string, .required)
            .field("used_at", .datetime)
            .unique(on: "account_id", "code_hash")
        try await schema.create()
        let sql = try requireSQL(database)
        if database is any MySQLDatabase {
            try await sql.raw("ALTER TABLE \(ident: "recovery_codes") CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
        }
        try await sql.create(index: "idx_recovery_codes_account_id").on("recovery_codes").column("account_id").run()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema("recovery_codes").delete()
    }
}

public struct CreateFallbackPassword: AsyncMigration {
    public let name = "stage1.create_fallback_passwords"
    public init() {}

    public func prepare(on database: any Database) async throws {
        let schema = database.schema("fallback_passwords").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("hash", .string, .required)
            .field("algorithm", .string, .required)
            .field("updated_at", .datetime, .required)
            .unique(on: "account_id")
        try await schema.create()
        let sql = try requireSQL(database)
        if database is any MySQLDatabase {
            try await sql.raw("ALTER TABLE \(ident: "fallback_passwords") CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
        }
    }

    public func revert(on database: any Database) async throws {
        try await database.schema("fallback_passwords").delete()
    }
}

public struct CreateEmailRecovery: AsyncMigration {
    public let name = "stage1.create_email_recovery"
    public init() {}

    public func prepare(on database: any Database) async throws {
        let schema = database.schema("email_recovery").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("email", .string, .required)
            .field("verified_at", .datetime)
            .field("active", .bool, .required)
            .unique(on: "account_id")
        try await schema.create()
        let sql = try requireSQL(database)
        if database is any MySQLDatabase {
            try await sql.raw("ALTER TABLE \(ident: "email_recovery") CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
        }
    }

    public func revert(on database: any Database) async throws {
        try await database.schema("email_recovery").delete()
    }
}

public struct CreateRecoveryAttempt: AsyncMigration {
    public let name = "stage1.create_recovery_attempts"
    public init() {}

    public func prepare(on database: any Database) async throws {
        let schema = database.schema("recovery_attempts").id()
            .field("kind", .string, .required)
            .field("account_id", .uuid, .references("accounts", "id", onDelete: .restrict))
            .field("code_hash", .string)
            .field("proof_hash", .string)
            .field("expires_at", .datetime, .required)
            .field("consumed_at", .datetime)
            .field("attempt_count", .int, .required)
            .field("created_at", .datetime, .required)
            .constraint(.sql(unsafeRaw: "CHECK (kind IN ('email', 'recovery-code', 'fallback-password', 'email-verification'))"))
            .constraint(.sql(unsafeRaw: "CHECK (attempt_count >= 0)"))
        try await schema.create()
        let sql = try requireSQL(database)
        if database is any MySQLDatabase {
            try await sql.raw("ALTER TABLE \(ident: "recovery_attempts") CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
        }
        try await sql.create(index: "idx_recovery_attempts_account_id").on("recovery_attempts").column("account_id").run()
        try await sql.create(index: "idx_recovery_attempts_expires_at").on("recovery_attempts").column("expires_at").run()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema("recovery_attempts").delete()
    }
}

public struct CreateRateLimitEvent: AsyncMigration {
    public let name = "stage1.create_rate_limit_events"
    public init() {}

    public func prepare(on database: any Database) async throws {
        let schema = database.schema("rate_limit_events").id()
            .field("key", .string, .required)
            .field("occurred_at", .datetime, .required)
        try await schema.create()
        let sql = try requireSQL(database)
        if database is any MySQLDatabase {
            try await sql.raw("ALTER TABLE \(ident: "rate_limit_events") CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin").run()
        }
        try await sql.create(index: "idx_rate_limit_events_key_occurred_at").on("rate_limit_events").column("key").column("occurred_at").run()
        try await sql.create(index: "idx_rate_limit_events_occurred_at").on("rate_limit_events").column("occurred_at").run()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema("rate_limit_events").delete()
    }
}
