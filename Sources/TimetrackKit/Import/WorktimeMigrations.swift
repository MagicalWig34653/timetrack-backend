import Fluent
import FluentSQL
import FluentMySQLDriver
import Foundation

/// Replace the existing kind check without changing historical migrations or disabling checks.
struct EnableExcusedAbsences: AsyncMigration {
    func prepare(on db: any Database) async throws { try await replace(on: db, adding: true) }
    func revert(on db: any Database) async throws { try await replace(on: db, adding: false) }
    private func replace(on db: any Database, adding: Bool) async throws {
        let sql = try requireSQL(db)
        let old = adding ? "'vacation', 'sick', 'other'" : "'vacation', 'sick', 'excused', 'other'"
        let new = adding ? "'vacation', 'sick', 'excused', 'other'" : "'vacation', 'sick', 'other'"
        if db is any MySQLDatabase {
            let rows = try await sql.raw("SELECT CONSTRAINT_NAME, CHECK_CLAUSE FROM information_schema.CHECK_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = 'absences'").all()
            var replaced = false
            for row in rows {
                let clause = try row.decode(column: "CHECK_CLAUSE", as: String.self)
                if clause.contains("'vacation'") && clause.contains("'sick'") {
                    guard !replaced else { throw APIError.invalid }
                    let name = try row.decode(column: "CONSTRAINT_NAME", as: String.self)
                    try await sql.raw("ALTER TABLE absences DROP CONSTRAINT \(ident: name), ADD CONSTRAINT absence_kind_check CHECK (kind IN (\(unsafeRaw: new)))").run()
                    replaced = true
                }
            }
            guard replaced else { throw APIError.invalid }
        } else {
            // No table references absences. Rebuild with every existing column, constraint and row.
            try await db.transaction { tx in
                let connection = try requireSQL(tx)
                guard let row = try await connection.raw("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'absences'").first() else { throw APIError.invalid }
                let definition = try row.decode(column: "sql", as: String.self)
                let indexes = try await connection.raw("SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'absences' AND sql IS NOT NULL").all()
                let updated = definition.replacingOccurrences(of: old, with: new)
                    .replacingOccurrences(of: "CREATE TABLE \"absences\"", with: "CREATE TABLE \"absences_c21\"")
                guard updated != definition, updated.contains("absences_c21") else { throw APIError.invalid }
                try await connection.raw(SQLQueryString(updated)).run()
                try await connection.raw("INSERT INTO absences_c21 SELECT * FROM absences").run()
                try await connection.raw("DROP TABLE absences").run()
                try await connection.raw("ALTER TABLE absences_c21 RENAME TO absences").run()
                for index in indexes { try await connection.raw(SQLQueryString(try index.decode(column: "sql", as: String.self))).run() }
            }
        }
    }
}

final class ImportBatchItemRecord: Model, @unchecked Sendable {
    static let schema = "import_batch_items"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "batch_id") var batchId: UUID
    @Field(key: "item_type") var itemType: String
    @Field(key: "item_id") var itemId: UUID
    @Field(key: "snapshot") var snapshot: String
    init() {}
}

struct CreateWorktimeImportItems: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("import_jobs").field("detected_profile", .string).update()
        try await db.schema("import_batch_items").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("batch_id", .uuid, .required, .references("import_batches", "id", onDelete: .restrict))
            .field("item_type", .string, .required).field("item_id", .uuid, .required)
            .field("snapshot", .sql(unsafeRaw: "TEXT"), .required)
            .unique(on: "batch_id", "item_type", "item_id").create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("import_batch_items").delete()
        try await db.schema("import_jobs").deleteField("detected_profile").update()
    }
}
