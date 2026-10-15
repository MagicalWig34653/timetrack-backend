import Fluent
import Vapor

/// Intentionally uncached: every decision reads the current database, including inside transactions.
struct ModuleRegistry: Sendable {
    var locked: Set<ModuleKey> = []
    func statuses(account: UUID?, on db: any Database) async throws -> [ModuleStatus] {
        let server = try await ModuleSetting.query(on: db).all()
        let own: [AccountModuleSetting]
        if let account { own = try await AccountModuleSetting.query(on: db).filter(\.$accountId == account).all() }
        else { own = [] }
        return ModuleKey.allCases.map { key in
            .init(key: key, serverEnabled: !locked.contains(key) && (server.first { $0.key == key.rawValue }?.enabled ?? true),
                  accountEnabled: own.first { $0.moduleKey == key.rawValue }?.enabled ?? true, lockedByOperator: locked.contains(key))
        }
    }
    func enabled(_ key: ModuleKey, account: UUID?, on db: any Database) async throws -> Bool {
        try await statuses(account: account, on: db).first { $0.key == key }?.effective ?? false
    }
    func require(_ keys: [ModuleKey], account: UUID?, on db: any Database) async throws {
        let status = try await statuses(account: account, on: db)
        guard keys.allSatisfy({ key in status.contains { $0.key == key && $0.effective } }) else { throw APIError(.notFound, "module_disabled") }
    }
    func server(on db: any Database) async throws -> [ServerModule] {
        try await statuses(account: nil, on: db).map { .init(key: $0.key, enabled: $0.serverEnabled, lockedByOperator: $0.lockedByOperator) }
    }
    func update(_ values: [String: Bool], context: AuthContext, server: Bool, auth: AuthService, on db: any Database) async throws {
        try await auth.transaction(on: db) { tx in
            let current = try await auth.authenticate(context.token, on: tx)
            if server { try current.admin() } else { try current.normal() }
            let account = try current.account.requireID()
            let status = try await statuses(account: account, on: tx)
            for (name, value) in values {
                guard let key = ModuleKey(rawValue: name), let item = status.first(where: { $0.key == key }) else { throw APIError.invalid }
                guard !(server ? locked.contains(key) : value && !item.serverEnabled) else { throw APIError(.conflict, "module_locked") }
            }
            for (name, value) in values.sorted(by: { $0.key < $1.key }) {
                if server {
                    let existing = try await ModuleSetting.query(on: tx).filter(\.$key == name).first()
                    let old = existing?.enabled ?? true
                    let row = existing ?? ModuleSetting(); row.key = name; row.enabled = value; row.updatedBy = account; row.updatedAt = Date()
                    try await row.save(on: tx)
                    if old != value {
                        let audit = ModuleAudit(); audit.actorId = account; audit.occurredAt = row.updatedAt
                        audit.moduleKey = name; audit.oldEnabled = old; audit.newEnabled = value; try await audit.create(on: tx)
                    }
                } else {
                    let row = try await AccountModuleSetting.query(on: tx).filter(\.$accountId == account).filter(\.$moduleKey == name).first() ?? AccountModuleSetting()
                    row.accountId = account; row.moduleKey = name; row.enabled = value; try await row.save(on: tx)
                }
            }
        }
    }
}
extension AuthService { var modules: ModuleRegistry { .init(locked: configuration.disabledModules) } }
extension TimeServices { var modules: ModuleRegistry { .init(locked: disabledModules) } }

enum ModuleMessages {
    static func message(_ code: String) -> String? {
        switch code {
        case "module_disabled": "Dieses Modul ist deaktiviert."
        case "module_locked": "Dieses Modul ist durch den Server gesperrt."
        default: nil
        }
    }
}
