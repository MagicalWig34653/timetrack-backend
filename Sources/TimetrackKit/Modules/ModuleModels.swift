import Fluent
import Vapor

public enum ModuleKey: String, Codable, CaseIterable, Sendable {
    case reports, planning, transfer, automation, mcp

    static func parseDisabled(_ value: String) throws -> Set<ModuleKey> {
        var keys = Set<ModuleKey>()
        for part in value.split(separator: ",", omittingEmptySubsequences: false) {
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            guard let key = ModuleKey(rawValue: name) else {
                throw ConfigurationError(key: "MODULES_DISABLED", reason: "unknown module; expected reports, planning, transfer, automation or mcp")
            }
            keys.insert(key)
        }
        return keys
    }
    static func notification(_ kind: String) -> ModuleKey? {
        switch kind {
        case "report_gap": .reports
        case "document_submission": .planning
        case "pending_suggestions": .automation
        default: nil
        }
    }
    static func tool(_ name: String) -> [ModuleKey] {
        if name == "list_absence_attachments" { return [.planning, .transfer] }
        if name.contains("report") || name == "list_learning_fields" { return [.reports] }
        if ["list_absences", "create_absence", "get_vacation_balance", "list_holidays", "list_plan_days", "set_plan_day", "view_shared"].contains(name) { return [.planning] }
        return []
    }
}

final class ModuleSetting: Model, @unchecked Sendable {
    static let schema = "module_settings"
    @ID(key: .id) var id: UUID?
    @Field(key: "key") var key: String
    @Field(key: "enabled") var enabled: Bool
    @Field(key: "updated_by") var updatedBy: UUID
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}
final class AccountModuleSetting: Model, @unchecked Sendable {
    static let schema = "account_module_settings"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "module_key") var moduleKey: String
    @Field(key: "enabled") var enabled: Bool
    init() {}
}
final class ModuleAudit: Model, @unchecked Sendable {
    static let schema = "module_audit"
    @ID(key: .id) var id: UUID?
    @Field(key: "actor_id") var actorId: UUID
    @Field(key: "occurred_at") var occurredAt: Date
    @Field(key: "module_key") var moduleKey: String
    @Field(key: "old_enabled") var oldEnabled: Bool
    @Field(key: "new_enabled") var newEnabled: Bool
    init() {}
}
struct CreateModuleSettings: AsyncMigration {
    let name = "stage4d.create_module_settings"
    func prepare(on db: any Database) async throws {
        try await db.schema(ModuleSetting.schema).id().field("key", .string, .required).unique(on: "key")
            .field("enabled", .bool, .required).field("updated_by", .uuid, .required, .references("accounts", "id"))
            .field("updated_at", .datetime, .required).create()
        try await db.schema(AccountModuleSetting.schema).id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .cascade))
            .field("module_key", .string, .required).field("enabled", .bool, .required)
            .unique(on: "account_id", "module_key").create()
        try await db.schema(ModuleAudit.schema).id().field("actor_id", .uuid, .required)
            .field("occurred_at", .datetime, .required).field("module_key", .string, .required)
            .field("old_enabled", .bool, .required).field("new_enabled", .bool, .required).create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(ModuleAudit.schema).delete()
        try await db.schema(AccountModuleSetting.schema).delete()
        try await db.schema(ModuleSetting.schema).delete()
    }
}
struct ModuleStatus: Content {
    let key: ModuleKey
    let serverEnabled: Bool
    let accountEnabled: Bool
    var effective: Bool { serverEnabled && accountEnabled }
    let lockedByOperator: Bool
    enum CodingKeys: String, CodingKey { case key, serverEnabled, accountEnabled, effective, lockedByOperator }
    init(key: ModuleKey, serverEnabled: Bool, accountEnabled: Bool, lockedByOperator: Bool) {
        self.key = key; self.serverEnabled = serverEnabled; self.accountEnabled = accountEnabled; self.lockedByOperator = lockedByOperator
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(ModuleKey.self, forKey: .key); serverEnabled = try c.decode(Bool.self, forKey: .serverEnabled)
        accountEnabled = try c.decode(Bool.self, forKey: .accountEnabled); lockedByOperator = try c.decode(Bool.self, forKey: .lockedByOperator)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key); try c.encode(serverEnabled, forKey: .serverEnabled)
        try c.encode(accountEnabled, forKey: .accountEnabled); try c.encode(effective, forKey: .effective)
        try c.encode(lockedByOperator, forKey: .lockedByOperator)
    }
}
struct ServerModule: Content { let key: ModuleKey; let enabled: Bool; let lockedByOperator: Bool }
