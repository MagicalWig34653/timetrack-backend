import Foundation
import Fluent
import FluentSQL

// Stage 3a persistence. Dates are stored as ISO strings like the stage-2 tables.

final class VacationSettingsRecord: Model, @unchecked Sendable {
    static let schema = "vacation_settings"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "region") var region: String
    @Field(key: "annual_entitlement_half_days") var annualEntitlementHalfDays: Int
    @Field(key: "carry_over") var carryOver: [String: Int]
    @OptionalField(key: "carry_over_expiry") var carryOverExpiry: String?
    /// N4: company-day rules; nil until the account configures any.
    @OptionalField(key: "company_days") var companyDays: [CompanyDayRule]?
    init() {}
}

final class VacationSnapshotRecord: Model, @unchecked Sendable {
    static let schema = "vacation_snapshots"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "date") var date: String
    @Field(key: "remaining_half_days") var remainingHalfDays: Int
    init() {}
}

final class VacationAdjustmentRecord: Model, @unchecked Sendable {
    static let schema = "vacation_adjustments"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "date") var date: String
    @Field(key: "half_days") var halfDays: Int
    @Field(key: "reason") var reason: String
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

final class AbsenceRecord: Model, @unchecked Sendable {
    static let schema = "absences"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "start_date") var startDate: String
    @Field(key: "end_date") var endDate: String
    @Field(key: "half_day_start") var halfDayStart: Bool
    @Field(key: "half_day_end") var halfDayEnd: Bool
    @Field(key: "status") var status: String
    @OptionalField(key: "note") var note: String?
    @Field(key: "document_status") var documentStatus: String
    @OptionalField(key: "document_submitted_on") var documentSubmittedOn: String?
    @OptionalField(key: "document_reference_start") var documentReferenceStart: String?
    @OptionalField(key: "document_reference_end") var documentReferenceEnd: String?
    @Field(key: "version") var version: Int
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}

final class CustomCalendarDayRecord: Model, @unchecked Sendable {
    static let schema = "custom_calendar_days"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "start_date") var startDate: String
    @Field(key: "end_date") var endDate: String
    @Field(key: "name") var name: String
    init() {}
}

final class PlanDayRecord: Model, @unchecked Sendable {
    static let schema = "plan_days"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "date") var date: String
    @Field(key: "mode") var mode: String
    @OptionalField(key: "place_id") var placeId: UUID?
    @OptionalField(key: "note") var note: String?
    /// K1: rough planned working window as local wall-clock "HH:mm" and a planned break; all NULL when no times are planned.
    @OptionalField(key: "planned_start") var plannedStart: String?
    @OptionalField(key: "planned_end") var plannedEnd: String?
    @OptionalField(key: "planned_break_minutes") var plannedBreakMinutes: Int?
    init() {}
}

final class ShareRecord: Model, @unchecked Sendable {
    static let schema = "shares"
    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerId: UUID
    @Field(key: "recipient_id") var recipientId: UUID
    @Field(key: "scope_plan") var scopePlan: Bool
    @Field(key: "scope_actual") var scopeActual: Bool
    @Field(key: "scope_vacation") var scopeVacation: Bool
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    /// 1 while active, NULL once revoked: the unique key allows one active share per pair only.
    @OptionalField(key: "active") var active: Int?
    init() {}
    var scopes: ShareScopesDTO { .init(plan: scopePlan, actual: scopeActual, vacation: scopeVacation) }
}

struct AddCompanyDays: AsyncMigration {
    let name = "n4.add_company_days"
    func prepare(on db: any Database) async throws {
        try await db.schema("vacation_settings").field("company_days", .json).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("vacation_settings").deleteField("company_days").update()
    }
}

enum StageThreeSchema {
    static let migrations: [any Migration] = [CreatePlanningPersistence()]
}

struct CreatePlanningPersistence: AsyncMigration {
    let name = "stage3.create_planning_persistence"
    func prepare(on db: any Database) async throws {
        try await db.schema("vacation_settings").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("region", .string, .required)
            .field("annual_entitlement_half_days", .int, .required)
            .field("carry_over", .json, .required)
            .field("carry_over_expiry", .string)
            .unique(on: "account_id")
            .create()
        try await db.schema("vacation_snapshots").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("date", .string, .required)
            .field("remaining_half_days", .int, .required)
            .unique(on: "account_id", "date")
            .constraint(.sql(unsafeRaw: "CHECK (remaining_half_days >= 0)"))
            .create()
        try await db.schema("vacation_adjustments").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("date", .string, .required)
            .field("half_days", .int, .required)
            .field("reason", .string, .required)
            .field("created_at", .datetime, .required)
            .create()
        try await db.schema("absences").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("kind", .string, .required)
            .field("start_date", .string, .required)
            .field("end_date", .string, .required)
            .field("half_day_start", .bool, .required)
            .field("half_day_end", .bool, .required)
            .field("status", .string, .required)
            .field("note", .sql(unsafeRaw: "TEXT"))
            .field("document_status", .string, .required)
            .field("document_submitted_on", .string)
            .field("document_reference_start", .string)
            .field("document_reference_end", .string)
            .field("version", .int, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .constraint(.sql(unsafeRaw: "CHECK (kind IN ('vacation', 'sick', 'other'))"))
            .constraint(.sql(unsafeRaw: "CHECK (status IN ('planned', 'requested', 'approved', 'rejected', 'cancelled', 'taken'))"))
            .constraint(.sql(unsafeRaw: "CHECK (document_status IN ('not_needed', 'pending', 'submitted'))"))
            .constraint(.sql(unsafeRaw: "CHECK (start_date <= end_date)"))
            .create()
        try await db.schema("custom_calendar_days").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("kind", .string, .required)
            .field("start_date", .string, .required)
            .field("end_date", .string, .required)
            .field("name", .string, .required)
            .constraint(.sql(unsafeRaw: "CHECK (kind IN ('holiday', 'school_holiday'))"))
            .constraint(.sql(unsafeRaw: "CHECK (start_date <= end_date)"))
            .create()
        try await db.schema("plan_days").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("date", .string, .required)
            .field("mode", .string, .required)
            .field("place_id", .uuid, .references("places", "id", onDelete: .restrict))
            .field("note", .string)
            .unique(on: "account_id", "date")
            .constraint(.sql(unsafeRaw: "CHECK (mode IN ('office', 'home', 'customer', 'school', 'off'))"))
            .create()
        try await db.schema("shares").id()
            .field("owner_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("recipient_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("scope_plan", .bool, .required)
            .field("scope_actual", .bool, .required)
            .field("scope_vacation", .bool, .required)
            .field("created_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("active", .int)
            .unique(on: "owner_id", "recipient_id", "active")
            .constraint(.sql(unsafeRaw: "CHECK (owner_id <> recipient_id)"))
            .constraint(.sql(unsafeRaw: "CHECK ((revoked_at IS NULL AND active = 1) OR (revoked_at IS NOT NULL AND active IS NULL))"))
            .create()
        let sql = try requireSQL(db)
        try await sql.create(index: "idx_vacation_adjustments_account").on("vacation_adjustments").column("account_id").run()
        try await sql.create(index: "idx_absences_account_start").on("absences").column("account_id").column("start_date").run()
        try await sql.create(index: "idx_custom_calendar_days_account").on("custom_calendar_days").column("account_id").run()
        try await sql.create(index: "idx_shares_recipient").on("shares").column("recipient_id").run()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("shares").delete()
        try await db.schema("plan_days").delete()
        try await db.schema("custom_calendar_days").delete()
        try await db.schema("absences").delete()
        try await db.schema("vacation_adjustments").delete()
        try await db.schema("vacation_snapshots").delete()
        try await db.schema("vacation_settings").delete()
    }
}

/// K1: additive columns for planned times on plan days (ADR-0021). Existing rows keep NULL.
struct AddPlanDayTimes: AsyncMigration {
    let name = "k1.add_plan_day_times"
    func prepare(on db: any Database) async throws {
        // One statement per column: SQLite cannot add several columns in a single ALTER TABLE.
        try await db.schema("plan_days").field("planned_start", .string).update()
        try await db.schema("plan_days").field("planned_end", .string).update()
        try await db.schema("plan_days").field("planned_break_minutes", .int).update()
    }
    func revert(on db: any Database) async throws {
        // One statement per column: SQLite cannot drop several columns in a single ALTER TABLE.
        try await db.schema("plan_days").deleteField("planned_break_minutes").update()
        try await db.schema("plan_days").deleteField("planned_end").update()
        try await db.schema("plan_days").deleteField("planned_start").update()
    }
}
