import Foundation
import Fluent

// Package W4: the account balance, the week view and the statistics need the balance at the start of a window. Summing
// the day deltas of the complete history on every request made their latency grow with the age of the account. A
// checkpoint keeps the sum of the official day deltas from the account start up to the last day of a month; a request then
// loads and evaluates only the days after that checkpoint. A checkpoint is valid as long as no row that can influence
// those days changed (`TimeChangeTracker.fingerprint`), so the result is identical to evaluating the whole history.

/// Sum of the official day deltas (`deltaSeconds`) from the account start through `through`, and whether one of those days is
/// provisional. Adjustments are not part of it: they are cheap to load and are applied live.
struct BalanceCarry: Sendable, Equatable {
    let through: LocalDate
    let evaluationSeconds: Int
    let provisional: Bool
}

actor BalanceCheckpointCache {
    static let shared = BalanceCheckpointCache()
    struct Key: Hashable, Sendable { let account: UUID; let through: LocalDate; let start: LocalDate; let planning: Bool }
    private struct Entry { let fingerprint: Int; let carry: BalanceCarry }
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private let capacity = 512
    /// Diagnostics for tests and benchmarks.
    private(set) var hits = 0, builds = 0

    func lookup(_ key: Key, fingerprint: Int) -> BalanceCarry? {
        guard let entry = entries[key], entry.fingerprint == fingerprint else { return nil }
        hits += 1
        return entry.carry
    }
    func store(_ key: Key, fingerprint: Int, carry: BalanceCarry) {
        builds += 1
        if entries.updateValue(Entry(fingerprint: fingerprint, carry: carry), forKey: key) == nil {
            order.append(key)
            if order.count > capacity { entries[order.removeFirst()] = nil }
        }
    }
    func reset() { entries = [:]; order = []; hits = 0; builds = 0 }
    var statistics: (hits: Int, builds: Int) { (hits, builds) }
}

/// Everything a balance-based read needs: a snapshot that covers at least `carry.through + 1 ... through` (or the complete
/// history when `carry` is nil), all adjustments, and `today` in the account time zone.
struct BalanceInputs: Sendable {
    let snapshot: TimeEvaluationSnapshot
    let adjustments: [AdjustmentRecord]
    let carry: BalanceCarry?
    let today: LocalDate
}

extension AccountService {
    private static var utcCalendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt; return calendar }

    /// Loads the inputs for balances of the days up to `through` (default today, never beyond today), anchored at `anchor`
    /// (the earliest day whose balance is needed; default `through`). `also` widens the loaded window for days the caller
    /// evaluates itself (the displayed week or statistics range). Falls back to the complete history when no checkpoint can
    /// be used: no work model, or a still running segment that could influence a day before the checkpoint.
    func balanceInputs(anchor: LocalDate? = nil, through: LocalDate? = nil, also: ClosedRange<LocalDate>? = nil,
                       now: Date, useCheckpoints: Bool = true) async throws -> BalanceInputs {
        let models = try await scope.models.list().map { try $0.engine() }
        let adjustments = try await AdjustmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).all()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: models.last?.timezone ?? "Europe/Berlin")!
        let today = LocalDate.local(now, calendar: calendar)
        func full() async throws -> BalanceInputs {
            .init(snapshot: try await scope.days.snapshot(models: models), adjustments: adjustments, carry: nil, today: today)
        }
        guard useCheckpoints, !models.isEmpty else { return try await full() }
        let last = min(through ?? today, today)
        let first = min(anchor ?? last, last)
        // Day before the first day of the month of `first`: strictly before `first` and therefore before today.
        let checkpointDay = first.addingDays(-first.day)
        var window = checkpointDay.addingDays(1)...max(last, checkpointDay.addingDays(1))
        if let also { window = min(window.lowerBound, also.lowerBound)...max(window.upperBound, also.upperBound) }
        let planning = try await scope.modules.enabled(.planning, account: scope.accountId, on: scope.db)
        // The account start only needs the work models and adjustments (the first segment matters only without models).
        let probe = TimeEvaluationSnapshot(models: models, segments: [], preferences: [:])
        guard let start = try accountStart(snapshot: probe, adjustments: adjustments, calendar: calendar),
              start <= checkpointDay else {
            // No account yet, or it starts after the checkpoint: the window contains every day of the account.
            return .init(snapshot: try await scope.days.snapshot(window: window, models: models, planning: planning),
                         adjustments: adjustments, carry: nil, today: today)
        }
        let key = BalanceCheckpointCache.Key(account: scope.accountId, through: checkpointDay, start: start, planning: planning)
        let fingerprint = try await TimeChangeTracker.fingerprint(account: scope.accountId, through: checkpointDay, on: scope.db)
        if let hit = await BalanceCheckpointCache.shared.lookup(key, fingerprint: fingerprint) {
            return .init(snapshot: try await scope.days.snapshot(window: window, models: models, planning: planning),
                         adjustments: adjustments, carry: hit, today: today)
        }
        // Miss: the complete history is needed to build the checkpoint and also serves as the snapshot of this request.
        let history = try await scope.days.snapshot(models: models, planning: planning)
        let carry = try checkpoint(history, start: start, through: checkpointDay, now: now)
        if let carry { await BalanceCheckpointCache.shared.store(key, fingerprint: fingerprint, carry: carry) }
        return .init(snapshot: history, adjustments: adjustments, carry: carry, today: today)
    }

    /// Evaluates every day from the account start through `through` over the complete history. nil when a still running
    /// segment could belong to one of those days: its length depends on `now`, so the sum must not be reused.
    private func checkpoint(_ history: TimeEvaluationSnapshot, start: LocalDate, through: LocalDate, now: Date) throws -> BalanceCarry? {
        // A segment belongs to the day of its start instant or to a neighbouring day (time zone below 15 h, day boundary below 12 h).
        let running = history.segments.contains {
            !$0.voided && $0.endedAt == nil && LocalDate.local($0.startedAt, calendar: Self.utcCalendar).addingDays(-2) <= through
        }
        guard !running else { return nil }
        let prepared = history.prepared()
        var total = 0, provisional = false
        var date = start
        while date <= through {
            let day = try prepared.evaluate(date, now: now)
            let (next, overflow) = total.addingReportingOverflow(day.deltaSeconds)
            guard !overflow else { throw APIError.invalid }
            total = next; provisional = provisional || day.provisional
            date = date.addingDays(1)
        }
        return BalanceCarry(through: through, evaluationSeconds: total, provisional: provisional)
    }

    func balance(inputs: BalanceInputs, asOf: LocalDate? = nil, now: Date) throws -> TimeAccountResult {
        try balance(snapshot: inputs.snapshot, adjustments: inputs.adjustments, asOf: asOf, now: now, carry: inputs.carry)
    }
}
