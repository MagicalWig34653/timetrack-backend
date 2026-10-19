import Foundation
import Fluent

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// Deletes everything that belongs to one account (ADR-0016). Stored files are not handled here: they are purged through
/// the storage service first because their objects may live outside the database.
enum AccountEraser {
    static let chunkSize = 400

    struct Wipe: Sendable {
        let schema: String
        let run: @Sendable (UUID, any Database) async throws -> Void
    }

    private static func byColumn<M: Model>(_ type: M.Type, _ column: String = "account_id") -> Wipe {
        Wipe(schema: M.schema) { id, db in
            try await M.query(on: db).filter(.path([.string(column)], schema: M.schema), .equal, .bind(id)).delete()
        }
    }

    private static func ids<M: Model>(_ type: M.Type, _ column: String = "account_id", of account: UUID, on db: any Database) async throws -> [UUID] {
        try await M.query(on: db).filter(.path([.string(column)], schema: M.schema), .equal, .bind(account)).all().compactMap { $0.id as? UUID }
    }

    /// Dependency order: children before parents. Every table with a column that points at an account must be listed
    /// here (or handled in `eraseIdentity`); `AccountDeletionTests` checks the schema against this list.
    static let wipes: [Wipe] = [
        // Notifications and push: the outbox references both notifications and subscriptions.
        Wipe(schema: PushOutboxRecord.schema) { id, db in
            for chunk in try await ids(PushSubscriptionRecord.self, of: id, on: db).chunked(chunkSize) {
                try await PushOutboxRecord.query(on: db).filter(\.$subscriptionId ~~ chunk).delete()
            }
            for chunk in try await ids(NotificationRecord.self, of: id, on: db).chunked(chunkSize) {
                try await PushOutboxRecord.query(on: db).filter(\.$notificationId ~~ chunk).delete()
            }
        },
        byColumn(NotificationRecord.self), byColumn(NotificationSettingsRecord.self), byColumn(PushSubscriptionRecord.self),
        // OAuth, personal tokens and the MCP audit rows of those credentials.
        Wipe(schema: McpAuditRecord.schema) { id, db in
            let credentials = try await ids(OAuthGrant.self, of: id, on: db) + ids(ApiTokenRecord.self, of: id, on: db)
            for chunk in credentials.chunked(chunkSize) { try await McpAuditRecord.query(on: db).filter(\.$credentialId ~~ chunk).delete() }
        },
        Wipe(schema: OAuthToken.schema) { id, db in
            for chunk in try await ids(OAuthGrant.self, of: id, on: db).chunked(chunkSize) {
                try await OAuthToken.query(on: db).filter(\.$grantId ~~ chunk).delete()
            }
        },
        byColumn(OAuthCode.self), byColumn(OAuthRequestRecord.self), byColumn(OAuthGrant.self), byColumn(ApiTokenRecord.self),
        // Imports.
        byColumn(ImportBatchItemRecord.self), byColumn(ImportBatchSegmentRecord.self), byColumn(ImportBatchRecord.self),
        byColumn(ImportFileRecord.self), byColumn(ImportMappingRecord.self), byColumn(ImportJobRecord.self), byColumn(ImportTemplateRecord.self),
        // Time data. Segments and plan days reference places.
        byColumn(RevisionRecord.self), byColumn(AutomationEventRecord.self), byColumn(TimerEventRecord.self), byColumn(SuggestionRecord.self),
        byColumn(SegmentRecord.self), byColumn(PlanDayRecord.self), byColumn(PlaceRecord.self), byColumn(DayPreferenceRecord.self),
        byColumn(AdjustmentRecord.self), byColumn(WorkModelRecord.self), byColumn(DeviceTokenRecord.self),
        // Reports.
        byColumn(ReportSourceRecord.self), byColumn(ReportEntryRecord.self), byColumn(ReportWeekStatusRecord.self), byColumn(LearningFieldRecord.self),
        // Absences, vacation, calendar, shares in both directions.
        byColumn(AbsenceAttachmentRecord.self), byColumn(AbsenceRecord.self), byColumn(VacationSettingsRecord.self), byColumn(VacationRequestFormRecord.self),
        byColumn(VacationSnapshotRecord.self), byColumn(VacationAdjustmentRecord.self), byColumn(CustomCalendarDayRecord.self),
        byColumn(ShareRecord.self, "owner_id"), byColumn(ShareRecord.self, "recipient_id"),
        // Identity and security material.
        byColumn(WebAuthnChallenge.self), byColumn(RecoveryAttempt.self), byColumn(RecoveryCode.self), byColumn(FallbackPassword.self),
        byColumn(EmailRecovery.self), byColumn(EmailChangeRequest.self), byColumn(Passkey.self), byColumn(Session.self), byColumn(ExternalIdentity.self), byColumn(OIDCState.self),
        byColumn(AccountModuleSetting.self), byColumn(ModuleAudit.self, "actor_id"),
    ]

    /// Tables handled outside `wipes` (stored files by the storage service, the rest by `detachReferences`).
    static let otherSchemas: Set<String> = [StoredFileRecord.schema, Invitation.schema, ModuleSetting.schema, AccountAuditRecord.schema, Account.schema]

    // MARK: Credentials

    /// Makes every credential of the account unusable and removes push subscriptions. Used by disabling and deleting.
    static func revokeCredentials(of account: UUID, on db: any Database, now: Date = Date()) async throws {
        try await Session.query(on: db).filter(\.$accountId == account).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
        try await DeviceTokenRecord.query(on: db).filter(\.$accountId == account).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
        try await ApiTokenRecord.query(on: db).filter(\.$accountId == account).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
        let grants = try await OAuthGrant.query(on: db).filter(\.$accountId == account).all().compactMap(\.id)
        try await OAuthGrant.query(on: db).filter(\.$accountId == account).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
        for chunk in grants.chunked(chunkSize) {
            try await OAuthToken.query(on: db).filter(\.$grantId ~~ chunk).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
        }
        try await OAuthCode.query(on: db).filter(\.$accountId == account).filter(\.$consumedAt == nil).set(\.$consumedAt, to: now).update()
        try await OAuthRequestRecord.query(on: db).filter(\.$accountId == account).delete()
        try await wipes.first { $0.schema == PushOutboxRecord.schema }!.run(account, db)
        try await PushSubscriptionRecord.query(on: db).filter(\.$accountId == account).delete()
    }

    // MARK: Erase

    /// Removes all rows of the account except the stored files (which must already be gone) and the account itself.
    static func eraseRows(of account: UUID, on db: any Database, now: Date = Date()) async throws {
        for wipe in wipes { try await wipe.run(account, db) }
        // Invitations stay as history without a reference; links that were still open are closed.
        try await Invitation.query(on: db).filter(\.$createdBy == account).filter(\.$usedAt == nil).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
        try await Invitation.query(on: db).filter(\.$createdBy == account).set(\.$createdBy, to: nil).update()
        try await Invitation.query(on: db).filter(\.$usedBy == account).set(\.$usedBy, to: nil).update()
        // `module_settings.updated_by` must keep pointing at an existing account.
        if try await ModuleSetting.query(on: db).filter(\.$updatedBy == account).count() > 0 {
            guard let successor = try await Account.query(on: db).filter(\.$role == .admin).filter(\.$disabledAt == nil).filter(\.$id != account).first()?.id else {
                throw APIError(.conflict, "last_admin")
            }
            try await ModuleSetting.query(on: db).filter(\.$updatedBy == account).set(\.$updatedBy, to: successor).update()
        }
    }
}
