import Fluent
import FluentSQL
import FluentMySQLDriver
import Foundation

public enum DatabaseSupportError: Error { case sqlRequired, missingAffectedRowCount }

func requireSQL(_ database: any Database) throws -> any SQLDatabase {
    guard let sql = database as? any SQLDatabase else { throw DatabaseSupportError.sqlRequired }
    return sql
}

/// A single conditional write followed by an affected-row count on the same connection.
/// Pass a transaction database when consumption must commit together with other writes.
/// Authorization and proof verification remain the caller's responsibility.
public enum SingleUse {
    public enum Resource: Sendable {
        case invitation, challenge, recoveryCode, recoveryAttempt
    }

    public static func consume(_ resource: Resource, id: UUID, on database: any Database,
                               at now: Date = Date()) async throws -> Bool {
        try await database.withConnection { connection in
            switch resource {
            case .invitation:
                try await Invitation.query(on: connection).filter(\.$id == id)
                    .filter(\.$usedAt == nil).filter(\.$revokedAt == nil)
                    .filter(\.$expiresAt > now).set(\.$usedAt, to: now).update()
            case .challenge:
                try await WebAuthnChallenge.query(on: connection).filter(\.$id == id)
                    .filter(\.$consumedAt == nil).filter(\.$expiresAt > now)
                    .set(\.$consumedAt, to: now).update()
            case .recoveryCode:
                try await RecoveryCode.query(on: connection).filter(\.$id == id)
                    .filter(\.$usedAt == nil).set(\.$usedAt, to: now).update()
            case .recoveryAttempt:
                try await RecoveryAttempt.query(on: connection).filter(\.$id == id)
                    .filter(\.$consumedAt == nil).filter(\.$expiresAt > now)
                    .set(\.$consumedAt, to: now).update()
            }
            let sql = try requireSQL(connection)
            let row = try await sql.raw(connection is any MySQLDatabase
                ? "SELECT ROW_COUNT() AS affected" : "SELECT changes() AS affected").first()
            guard let row else { throw DatabaseSupportError.missingAffectedRowCount }
            return try row.decode(column: "affected", as: Int.self) == 1
        }
    }
}
