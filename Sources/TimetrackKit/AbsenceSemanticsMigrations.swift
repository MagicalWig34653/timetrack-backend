import Fluent
import FluentSQL
import FluentMySQLDriver
import Foundation

// C3 (ADR-0032): `recorded` is a new absence status for kinds without a request workflow. Two migrations: the status check
// constraint allows it first, then existing rows of those kinds are normalised without losing the original status.

private let workflowStatuses = "'planned', 'requested', 'approved', 'rejected', 'cancelled', 'taken'"
private let recordedStatuses = "'planned', 'requested', 'approved', 'rejected', 'cancelled', 'taken', 'recorded'"

/// Replaces the status check of `absences` without touching historical migrations (same technique as `EnableExcusedAbsences`).
struct AllowRecordedAbsenceStatus: AsyncMigration {
    let name = "c3.allow_recorded_absence_status"
    func prepare(on db: any Database) async throws { try await replace(on: db, old: workflowStatuses, new: recordedStatuses) }
    func revert(on db: any Database) async throws {
        try await requireSQL(db).raw("UPDATE absences SET status = 'approved' WHERE status = 'recorded'").run()
        try await replace(on: db, old: recordedStatuses, new: workflowStatuses)
    }

    private func replace(on db: any Database, old: String, new: String) async throws {
        let sql = try requireSQL(db)
        if db is any MySQLDatabase {
            let rows = try await sql.raw("SELECT CONSTRAINT_NAME, CHECK_CLAUSE FROM information_schema.CHECK_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = 'absences'").all()
            var replaced = false
            for row in rows {
                let clause = try row.decode(column: "CHECK_CLAUSE", as: String.self)
                if clause.contains("'requested'") && clause.contains("'taken'") {
                    guard !replaced else { throw APIError.invalid }
                    let constraint = try row.decode(column: "CONSTRAINT_NAME", as: String.self)
                    try await sql.raw("ALTER TABLE absences DROP CONSTRAINT \(ident: constraint), ADD CONSTRAINT absence_status_check CHECK (status IN (\(unsafeRaw: new)))").run()
                    replaced = true
                }
            }
            guard replaced else { throw APIError.invalid }
        } else {
            try await db.transaction { tx in
                let connection = try requireSQL(tx)
                guard let row = try await connection.raw("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'absences'").first() else { throw APIError.invalid }
                let definition = try row.decode(column: "sql", as: String.self)
                let indexes = try await connection.raw("SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'absences' AND sql IS NOT NULL").all()
                let updated = definition.replacingOccurrences(of: old, with: new)
                    .replacingOccurrences(of: "CREATE TABLE \"absences\"", with: "CREATE TABLE \"absences_c3\"")
                guard updated != definition, updated.contains("absences_c3") else { throw APIError.invalid }
                try await connection.raw(SQLQueryString(updated)).run()
                try await connection.raw("INSERT INTO absences_c3 SELECT * FROM absences").run()
                try await connection.raw("DROP TABLE absences").run()
                try await connection.raw("ALTER TABLE absences_c3 RENAME TO absences").run()
                for index in indexes { try await connection.raw(SQLQueryString(try index.decode(column: "sql", as: String.self))).run() }
            }
        }
    }
}

/// Normalises existing rows: sick and excused entries become `recorded` (rejected ones `cancelled`), other absences lose the
/// approval states (requested -> planned, approved/taken -> recorded, rejected -> cancelled). The previous status stays in
/// `legacy_status` so nothing is lost. Vacation is untouched.
struct NormaliseAbsenceStatuses: AsyncMigration {
    let name = "c3.normalise_absence_statuses"
    func prepare(on db: any Database) async throws {
        try await db.schema("absences").field("legacy_status", .string).update()
        let sql = try requireSQL(db)
        let affected = try await sql.raw("""
            SELECT DISTINCT account_id FROM absences WHERE (kind IN ('sick', 'excused') AND status <> 'recorded' AND status <> 'cancelled') \
            OR (kind = 'other' AND status IN ('requested', 'approved', 'taken', 'rejected'))
            """).all()
        let accounts = try affected.map { try $0.decode(column: "account_id", as: UUID.self) }
        try await sql.raw("""
            UPDATE absences SET legacy_status = status, status = 'recorded' \
            WHERE kind IN ('sick', 'excused') AND status IN ('planned', 'requested', 'approved', 'taken')
            """).run()
        try await sql.raw("""
            UPDATE absences SET legacy_status = status, status = 'cancelled' \
            WHERE kind IN ('sick', 'excused', 'other') AND status = 'rejected'
            """).run()
        try await sql.raw("UPDATE absences SET legacy_status = status, status = 'planned' WHERE kind = 'other' AND status = 'requested'").run()
        try await sql.raw("UPDATE absences SET legacy_status = status, status = 'recorded' WHERE kind = 'other' AND status IN ('approved', 'taken')").run()
        // Former planned/requested sick days now count as sick days: cached balance checkpoints of these accounts are stale.
        for account in accounts { try await TimeChangeTracker.touch(account: account, months: [TimeChangeTracker.everything], on: db) }
    }
    func revert(on db: any Database) async throws {
        let sql = try requireSQL(db)
        try await sql.raw("UPDATE absences SET status = legacy_status WHERE legacy_status IS NOT NULL").run()
        try await db.schema("absences").deleteField("legacy_status").update()
    }
}
