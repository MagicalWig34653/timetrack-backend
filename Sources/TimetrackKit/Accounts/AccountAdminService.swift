import Foundation
import Fluent
import Vapor

/// Account administration and account deletion (ADR-0016). Every operation re-authenticates inside the serialized
/// auth transaction, so the last-administrator rule cannot be raced.
struct AccountAdminService: Sendable {
    let auth: AuthService
    let db: any Database
    let storage: StorageService

    static let maxPageSize = 100

    // MARK: Listing

    func list(_ context: AuthContext, limit: Int?, offset: Int?) async throws -> AdminAccountPage {
        let size = limit ?? 50, start = offset ?? 0
        guard (1...Self.maxPageSize).contains(size), start >= 0 else { throw APIError.invalid }
        let current = try await auth.authenticate(context.token, on: db)
        try current.admin()
        let total = try await Account.query(on: db).count()
        let accounts = try await Account.query(on: db).sort(\.$createdAt).sort(\.$handle).range(start..<start + size).all()
        var items: [AdminAccountDTO] = []
        for account in accounts { items.append(try await dto(account, on: db)) }
        return AdminAccountPage(items: items, total: total, limit: size, offset: start)
    }

    private func dto(_ account: Account, on db: any Database) async throws -> AdminAccountDTO {
        let id = try account.requireID()
        let keys = try await Passkey.query(on: db).filter(\.$accountId == id).filter(\.$revokedAt == nil).all()
        let session = try await Session.query(on: db).filter(\.$accountId == id).filter(\.$lastSeenAt != nil).sort(\.$lastSeenAt, .descending).first()?.lastSeenAt
        let activity = ([session] + keys.map(\.lastUsedAt)).compactMap { $0 }.max()
        return AdminAccountDTO(id: id, handle: account.handle, displayName: account.displayName, email: account.email, role: account.role,
                               state: account.disabledAt == nil ? "active" : "disabled", createdAt: account.createdAt,
                               disabledAt: account.disabledAt, lastActivityAt: activity, passkeyCount: keys.count)
    }

    // MARK: State and role

    func patch(_ id: UUID, _ input: AdminAccountPatch, context: AuthContext) async throws -> AdminAccountDTO {
        guard input.role != nil || input.state != nil, input.state.map({ ["active", "disabled"].contains($0) }) ?? true else { throw APIError.invalid }
        return try await auth.transaction(on: db) { tx in
            let current = try await auth.authenticate(context.token, on: tx)
            try current.admin()
            let actor = try current.account.requireID()
            if input.role != nil { try current.fresh() }
            guard let target = try await Account.find(id, on: tx) else { throw APIError.missing }
            // An administrator never changes their own role or state; this also keeps the last active administrator.
            guard id != actor else { throw APIError(.conflict, "self_lockout") }
            if let role = input.role, role != target.role {
                if target.role == .admin, target.disabledAt == nil { try await Self.requireOtherActiveAdmin(excluding: id, on: tx) }
                let old = target.role.rawValue
                target.role = role; try await target.update(on: tx)
                try await AccountAuditRecord(action: "account.role_changed", actor: actor, target: id, detail: "\(old)->\(role.rawValue)").create(on: tx)
            }
            if let state = input.state {
                if state == "disabled", target.disabledAt == nil {
                    if target.role == .admin { try await Self.requireOtherActiveAdmin(excluding: id, on: tx) }
                    target.disabledAt = Date(); try await target.update(on: tx)
                    try await AccountEraser.revokeCredentials(of: id, on: tx)
                    try await AccountAuditRecord(action: "account.disabled", actor: actor, target: id).create(on: tx)
                } else if state == "active", target.disabledAt != nil {
                    target.disabledAt = nil; try await target.update(on: tx)
                    try await AccountAuditRecord(action: "account.reactivated", actor: actor, target: id).create(on: tx)
                }
            }
            return try await dto(target, on: tx)
        }
    }

    func revokeSessions(_ id: UUID, context: AuthContext) async throws {
        try await auth.transaction(on: db) { tx in
            let current = try await auth.authenticate(context.token, on: tx)
            try current.admin()
            guard try await Account.find(id, on: tx) != nil else { throw APIError.missing }
            try await Session.query(on: tx).filter(\.$accountId == id).filter(\.$revokedAt == nil).set(\.$revokedAt, to: Date()).update()
            try await AccountAuditRecord(action: "account.sessions_revoked", actor: current.account.requireID(), target: id).create(on: tx)
        }
    }

    static func requireOtherActiveAdmin(excluding id: UUID, on db: any Database) async throws {
        let others = try await Account.query(on: db).filter(\.$role == .admin).filter(\.$disabledAt == nil).filter(\.$id != id).count()
        guard others > 0 else { throw APIError(.conflict, "last_admin") }
    }

    // MARK: Deletion

    /// Three phases. 1: authorize, disable the account, revoke all credentials, mark its files `deleting`.
    /// 2: purge the stored objects outside any transaction. 3: delete all rows and the account in one transaction.
    /// If phase 2 cannot remove an object the whole operation fails with `account_deletion_incomplete`; the account stays
    /// disabled, the files stay marked for the retry, and repeating the request continues where it stopped.
    func delete(_ id: UUID, confirm: AccountDeletionConfirm, context: AuthContext, selfService: Bool) async throws {
        let files: [StoredFileRecord] = try await auth.transaction(on: db) { tx in
            let current = try await auth.authenticate(context.token, on: tx)
            try current.fresh()
            let actor = try current.account.requireID()
            if selfService { guard actor == id else { throw APIError.missing } }
            else { try current.admin(); guard actor != id else { throw APIError(.conflict, "self_lockout") } }
            guard let target = try await Account.find(id, on: tx) else { throw APIError.missing }
            guard confirm.confirmHandle == target.handle else { throw APIError(.badRequest, "confirmation_mismatch") }
            if target.role == .admin { try await Self.requireOtherActiveAdmin(excluding: id, on: tx) }
            if target.disabledAt == nil { target.disabledAt = Date(); try await target.update(on: tx) }
            try await AccountEraser.revokeCredentials(of: id, on: tx)
            let rows = try await StoredFileRecord.query(on: tx).filter(\.$accountId == id).all()
            for row in rows where row.state != FileState.deleting.rawValue { row.state = FileState.deleting.rawValue; try await row.update(on: tx) }
            return rows
        }
        var failed = 0
        for row in files where !(await storage.purge(row)) { failed += 1 }
        guard failed == 0 else { throw APIError(.serviceUnavailable, "account_deletion_incomplete") }
        try await auth.transaction(on: db) { tx in
            guard let target = try await Account.find(id, on: tx) else { return }
            guard try await StoredFileRecord.query(on: tx).filter(\.$accountId == id).count() == 0 else { throw APIError(.serviceUnavailable, "account_deletion_incomplete") }
            if target.role == .admin { try await Self.requireOtherActiveAdmin(excluding: id, on: tx) }
            try await AccountEraser.eraseRows(of: id, on: tx)
            try await target.delete(on: tx)
            try await AccountAuditRecord(action: selfService ? "account.self_deleted" : "account.deleted", actor: selfService ? id : context.account.requireID(), target: id).create(on: tx)
        }
    }
}
