import Foundation
import Fluent
import Vapor

/// Package M1 (ADR-0004 addendum): correcting an existing work model version in place, with a preview of the effect.
/// Segments store raw and effective times only; evaluations are computed on read, so a correction changes the
/// evaluation of every day the version covers. That is allowed only as an explicit user act, after a preview.
struct WorkModelPreview: Content {
    var affectedFrom: LocalDate?
    /// `nil` while the corrected version is open-ended (it then reaches up to today and beyond).
    var affectedTo: LocalDate?
    var affectedDays: Int
    var balanceBeforeSeconds: Int
    var balanceAfterSeconds: Int
    var differenceSeconds: Int
    var changedFields: [String]
    /// Set when the previous version has to end earlier or later to stay adjacent.
    var previousValidTo: LocalDate?
}

extension WorkModelService {
    private struct Plan {
        var models: [WorkModelDTO]        // all versions after the correction, sorted by validFrom
        var changed: [WorkModelDTO]       // versions to persist (the corrected one and an adjusted predecessor)
        var corrected: WorkModelDTO
        var previousValidTo: LocalDate?
        var changedFields: [String]
    }

    private static func differences(_ old: WorkModelDTO, _ new: WorkModelDTO) -> [String] {
        func normalized(_ value: WorkModelDTO) -> [String: String] {
            let breaks = (value.fixedBreaks ?? []).map { "\($0.start)-\($0.end)" }.sorted().joined(separator: ",")
            let daily = (value.dailyTargetSeconds ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            return [
                "validFrom": value.validFrom.description, "validTo": value.validTo?.description ?? "",
                "timezone": value.timezone ?? "Europe/Berlin", "weeklyTargetSeconds": String(value.weeklyTargetSeconds),
                "workdays": Set(value.workdays).sorted().map(String.init).joined(separator: ","), "dailyTargetSeconds": daily,
                "travelCountsAsWork": String(value.travelCountsAsWork ?? true), "roundingEnabled": String(value.roundingEnabled ?? true),
                "roundingMinutes": String(value.roundingMinutes ?? 15),
                "schoolFullDayThresholdSeconds": String(value.schoolFullDayThresholdSeconds ?? 10800),
                "schoolCreditSeconds": value.schoolCreditSeconds.map(String.init) ?? "",
                "dayBoundaryMinutes": String(value.dayBoundaryMinutes ?? 0), "fixedBreaks": breaks]
        }
        let a = normalized(old), b = normalized(new)
        return a.keys.sorted().filter { a[$0] != b[$0] }
    }

    /// Pure planning step shared by preview and update: validates the replacement against the neighbours.
    private func plan(_ id: UUID, input: WorkModelDTO, versions: [WorkModelDTO]) throws -> Plan {
        guard let current = versions.first(where: { $0.id == id }) else { throw APIError.missing }
        _ = try input.engine()
        let others = versions.filter { $0.id != id }
        let previous = others.last { $0.validFrom < current.validFrom }
        let next = others.first { $0.validFrom > current.validFrom }
        var corrected = input
        corrected.id = id; corrected.createdAt = current.createdAt; corrected.version = (current.version ?? 1) + 1
        var changed: [WorkModelDTO] = []; var previousValidTo: LocalDate?
        if let previous {
            guard corrected.validFrom > previous.validFrom else { throw APIError(.conflict, "model_overlap") }
            let adjacent = previous.validTo == nil || previous.validTo == current.validFrom.addingDays(-1)
            if adjacent || (previous.validTo.map { $0 >= corrected.validFrom } ?? false) {
                let end = corrected.validFrom.addingDays(-1)
                if previous.validTo != end { var moved = previous; moved.validTo = end; moved.version = (previous.version ?? 1) + 1; changed.append(moved); previousValidTo = end }
            }
        }
        if let next {
            guard let end = corrected.validTo, end < next.validFrom else { throw APIError(.conflict, "model_overlap") }
        }
        changed.append(corrected)
        let replaced = Dictionary(uniqueKeysWithValues: changed.compactMap { value in value.id.map { ($0, value) } })
        let models = versions.map { $0.id.flatMap { replaced[$0] } ?? $0 }.sorted { $0.validFrom < $1.validFrom }
        return Plan(models: models, changed: changed, corrected: corrected, previousValidTo: previousValidTo,
                    changedFields: Self.differences(current, corrected))
    }

    func update(_ id: UUID, input: WorkModelDTO, version: Int?) async throws -> WorkModelDTO {
        let versions = try await list()
        let plan = try plan(id, input: input, versions: versions)
        if let version, version != (versions.first { $0.id == id }?.version ?? 1) { throw APIError(.preconditionFailed, "stale_version") }
        for value in plan.changed {
            let row = try await record(value.id!)
            row.validFrom = value.validFrom.description; row.validTo = value.validTo?.description; row.payload = value
            try await row.update(on: scope.db)
        }
        try await AccountAuditRecord(action: "work_model.updated", actor: scope.accountId, target: id).create(on: scope.db)
        return plan.corrected
    }

    /// Evaluates the account balance as of today with the stored and with the corrected model set, without persisting.
    func preview(_ id: UUID, input: WorkModelDTO, now: Date = Date()) async throws -> WorkModelPreview {
        let snapshot = try await scope.days.snapshot()
        let stored = try await list()
        let plan = try plan(id, input: input, versions: stored)
        let adjustments = try await AdjustmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).all()
        let before = try scope.account.balance(snapshot: snapshot, adjustments: adjustments, now: now)
        var after = snapshot; after.models = try plan.models.map { try $0.engine() }
        let afterBalance = try scope.account.balance(snapshot: after, adjustments: adjustments, now: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: snapshot.models.last?.timezone ?? "Europe/Berlin") ?? .gmt
        let today = LocalDate.local(now, calendar: calendar)
        let touched = plan.changed.compactMap { value in stored.first { $0.id == value.id }.map { ($0, value) } }
        let ranges = touched.flatMap { [($0.0.validFrom, $0.0.validTo), ($0.1.validFrom, $0.1.validTo)] }
        let from = ranges.map(\.0).min()
        let open = ranges.contains { $0.1 == nil }
        let to = open ? nil : ranges.compactMap(\.1).max()
        var days = 0
        if let from, from <= today { days = from.distance(to: min(to ?? today, today)) + 1 }
        return WorkModelPreview(affectedFrom: from, affectedTo: to, affectedDays: max(days, 0),
            balanceBeforeSeconds: before.balanceSeconds, balanceAfterSeconds: afterBalance.balanceSeconds,
            differenceSeconds: afterBalance.balanceSeconds - before.balanceSeconds, changedFields: plan.changedFields,
            previousValidTo: plan.previousValidTo)
    }
}
