import Foundation
import Fluent

// W3: overview, restore and permanent deletion of cancelled (voided, "storniert") segments.
// Cancelling stays the soft delete (voidedAt/voidReason + revision). Only here a cancelled segment can be removed for good.
// Decision (docs/ARCHITEKTUR.md, "Stornierte Abschnitte"): a hard delete removes the segment AND its revision history,
// the end suggestions that reference it and the stored timer replay results (data minimisation / erasure); no tombstone
// row remains. The response carries the counts of what was removed as the only trace. Automation event rows keep their
// idempotency key but lose the segment reference. Permanent deletion is REST/PWA/app only, never exposed to MCP/AI.

struct CancelledSegmentDTO: Encodable, Sendable {
    var segment: EngineSegment
    var cancelledAt: Date
    var cancelReason: String?
}

struct CancelledSegmentPage: Encodable, Sendable {
    var items: [CancelledSegmentDTO]
    var total: Int; var limit: Int; var offset: Int
}

struct PurgeSummary: Encodable, Sendable {
    var dryRun: Bool
    var segments: Int; var revisions: Int; var suggestions: Int; var timerEvents: Int; var automationEvents: Int
}

struct CancelledFilter: Sendable {
    var from: Date?; var to: Date?; var ids: [UUID]?
}

extension SegmentService {
    static let purgeIdLimit = 500

    private func cancelledQuery(_ filter: CancelledFilter) -> QueryBuilder<SegmentRecord> {
        let query = SegmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$voidedAt != nil)
        if let from = filter.from { query.filter(\.$startedAt >= from) }
        if let to = filter.to { query.filter(\.$startedAt < to) }
        if let ids = filter.ids { query.filter(\.$id ~~ ids) }
        return query
    }

    /// Cancelled segments, newest start first, paged. `from`/`to` bound the segment start like `list`.
    func listCancelled(_ filter: CancelledFilter, limit: Int, offset: Int) async throws -> CancelledSegmentPage {
        guard (1...200).contains(limit), offset >= 0 else { throw APIError.invalid }
        let total = try await cancelledQuery(filter).count()
        let rows = try await cancelledQuery(filter).sort(\.$startedAt, .descending).sort(\.$id).range(offset..<(offset + limit)).all()
        return .init(items: try rows.map { .init(segment: try $0.dto(), cancelledAt: $0.voidedAt ?? $0.startedAt, cancelReason: $0.voidReason) },
                     total: total, limit: limit, offset: offset)
    }

    /// Un-cancels a segment when that is safe: no overlap with a live segment (409 segment_overlap) and, for a cancelled
    /// running timer, no other running segment (409 timer_already_running). A revision with the reason is recorded.
    func restore(_ id: UUID, reason: String?, version: Int?) async throws -> EngineSegment {
        let row = try await record(id)
        guard row.voidedAt != nil else { throw APIError(.conflict, "segment_not_cancelled") }
        if let version, version != row.version { throw APIError(.preconditionFailed, "stale_version") }
        let text = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Restored"
        let stored = Self.restoreReasonPrefix + text
        try validateReason(stored)
        if row.endedAt == nil,
           try await SegmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$running == 1).filter(\.$id != id).first() != nil {
            throw APIError(.conflict, "timer_already_running")
        }
        let before = try row.dto()
        var value = before; value.voided = false
        try await validate(value)
        row.voidedAt = nil; row.voidReason = nil; row.version += 1; row.revisions += 1
        row.running = row.endedAt == nil ? 1 : nil
        let after = try row.dto()
        let revision = RevisionRecord(); revision.accountId = scope.accountId; revision.segmentId = id
        revision.before = before; revision.after = after; revision.reason = stored; revision.createdAt = Date()
        try await row.update(on: scope.db); try await revision.create(on: scope.db)
        return after
    }
    static let restoreReasonPrefix = "Restored: "

    /// Permanent deletion of ONE cancelled segment; 404 when unknown, 409 segment_not_cancelled when it is live.
    func purge(_ id: UUID) async throws -> PurgeSummary {
        let row = try await record(id)
        guard row.voidedAt != nil else { throw APIError(.conflict, "segment_not_cancelled") }
        return try await delete([row], dryRun: false)
    }

    /// Bulk purge of cancelled segments selected by range and/or ids. Live segments are never selected by a range; an
    /// explicit id of a live segment fails the whole request with 409 segment_not_cancelled (nothing is deleted).
    /// Unknown ids are ignored. `dryRun` only counts.
    func purgeCancelled(_ filter: CancelledFilter, dryRun: Bool) async throws -> PurgeSummary {
        if let ids = filter.ids {
            guard !ids.isEmpty, ids.count <= Self.purgeIdLimit else { throw APIError.invalid }
            let live = try await SegmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id ~~ ids)
                .filter(\.$voidedAt == nil).count()
            if live > 0 { throw APIError(.conflict, "segment_not_cancelled") }
        }
        return try await delete(try await cancelledQuery(filter).all(), dryRun: dryRun)
    }

    private func delete(_ rows: [SegmentRecord], dryRun: Bool) async throws -> PurgeSummary {
        // Defence in depth: whatever the caller selected, only cancelled rows of this account are ever removed.
        let rows = rows.filter { $0.voidedAt != nil && $0.accountId == scope.accountId }
        let ids = try rows.map { try $0.requireID() }
        let idSet = Set(ids)
        var summary = PurgeSummary(dryRun: dryRun, segments: rows.count, revisions: 0, suggestions: 0, timerEvents: 0, automationEvents: 0)
        guard !ids.isEmpty else { return summary }
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            let revisions = RevisionRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$segmentId ~~ chunk)
            summary.revisions += try await revisions.count()
            if !dryRun { try await revisions.delete() }
        }
        let suggestions = try await SuggestionRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).all()
            .filter { $0.payload.segmentId.map(idSet.contains) ?? false }
        summary.suggestions = suggestions.count
        let timerEvents = try await TimerEventRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).all()
            .filter { idSet.contains($0.result.id) }
        summary.timerEvents = timerEvents.count
        let automationEvents = try await AutomationEventRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).all()
            .filter { $0.result.segmentId.map(idSet.contains) ?? false }
        summary.automationEvents = automationEvents.count
        if dryRun { return summary }
        for row in suggestions { try await row.delete(on: scope.db) }
        for row in timerEvents { try await row.delete(on: scope.db) }
        for row in automationEvents { row.result.segmentId = nil; try await row.update(on: scope.db) }
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            try await SegmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$voidedAt != nil).filter(\.$id ~~ chunk).delete()
        }
        return summary
    }
}
