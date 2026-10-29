import Foundation
import Fluent

struct TimeEvaluationSnapshot: Sendable {
    var models: [EngineWorkModel]
    let segments: [EngineSegment]
    let preferences: [String: DayPreferences]
    var absences: [EngineAbsence] = []
    var customDays: [CustomCalendarDay] = []
    var planningEnabled = true
    var region = "DE-ST"
    var companyDays: [CompanyDayRule] = []
    /// Index the snapshot once (segment assignment, holiday calendars, validations) before evaluating many days.
    func prepared() -> PreparedEvaluation { PreparedEvaluation(self) }
    func evaluate(_ date: LocalDate, now: Date) throws -> DayEvaluationResult {
        try prepared().evaluate(date, now: now)
    }
}

struct DayService: Sendable {
    let scope: TimeServices
    func preference(_ date: LocalDate) async throws -> DayPreferenceRecord? {
        try await DayPreferenceRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$date == date.description).first()
    }
    /// Loads the inputs of the day evaluation. With a `window` only rows that can influence those days are read
    /// (segments by start instant with a safety margin for time zone and day-boundary shifts, preferences and
    /// absences by date); without one the complete history is loaded (account balance, exports of long ranges).
    /// `models` hands in the already loaded (and converted) work models of this request.
    func snapshot(window: ClosedRange<LocalDate>? = nil, includeSegments: Bool = true,
                  models loaded: [EngineWorkModel]? = nil, planning knownPlanning: Bool? = nil) async throws -> TimeEvaluationSnapshot {
        let models: [EngineWorkModel]
        if let loaded { models = loaded } else { models = try await scope.models.list().map { try $0.engine() } }
        // Legal weekly and rest warnings need the complete surrounding week and preceding day.
        let expanded = window.map { $0.lowerBound.addingDays(-7)...$0.upperBound.addingDays(7) }
        let segments = includeSegments ? try await scope.segments.all(window: expanded) : []
        let query = DayPreferenceRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
        if let expanded { query.filter(\.$date >= expanded.lowerBound.description).filter(\.$date <= expanded.upperBound.description) }
        let rows = try await query.all()
        let preferences = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row.date, DayPreferences(mark: DayMarkKind(rawValue: row.mark) ?? .none,
                creditSeconds: row.creditSeconds, skipFixedBreaks: row.skipFixedBreaks, note: row.note,
                schoolLessonCount: row.schoolLessonCount))
        })
        let planningOn: Bool
        if let knownPlanning { planningOn = knownPlanning } else { planningOn = try await scope.modules.enabled(.planning, account: scope.accountId, on: scope.db) }
        guard planningOn else {
            return .init(models: models, segments: segments, preferences: preferences, planningEnabled: false)
        }
        let settings = try await scope.vacation.settings()
        return .init(models: models, segments: segments, preferences: preferences,
                     absences: try await scope.vacation.engineAbsences(window: window), customDays: try await scope.vacation.customDays(),
                     region: settings.region, companyDays: settings.companyDays ?? [])
    }
    func evaluate(_ date: LocalDate, now: Date = Date()) async throws -> DayEvaluationResult {
        try await snapshot(window: date...date).evaluate(date, now: now)
    }
    func range(from: LocalDate, to: LocalDate, limit: Int = PlanningLimits.dayRangeDays) async throws -> [DayEvaluationResult] {
        try LocalDate.checkedRange(from: from, to: to, maxDays: limit)
        let prepared = try await snapshot(window: from...to).prepared(); let now = Date()
        var values: [DayEvaluationResult] = []; var date = from
        while true {
            values.append(try prepared.evaluate(date, now: now))
            if date == to { return values }
            date = date.addingDays(1)
        }
    }
    func set(_ date: LocalDate, input: DayInput) async throws -> DayEvaluationResult {
        guard input.creditSeconds.map({ (0...86_400).contains($0) }) ?? true,
              input.schoolLessonCount.map({ (0...20).contains($0) }) ?? true,
              input.note?.fitsColumn(200) ?? true else { throw APIError.invalid }
        let existing = try await preference(date)
        let row = existing ?? DayPreferenceRecord()
        if existing == nil { row.accountId = scope.accountId; row.date = date.description; row.mark = "none"; row.skipFixedBreaks = false }
        if let mark = input.mark { row.mark = mark.rawValue }
        if let skip = input.skipFixedBreaks { row.skipFixedBreaks = skip }
        if input.hasCredit { row.creditSeconds = input.creditSeconds }
        if input.hasNote { row.note = input.note }
        if input.hasSchoolLessonCount { row.schoolLessonCount = input.schoolLessonCount }
        if row.mark == "none" { row.creditSeconds = nil }
        try await row.save(on: scope.db)
        return try await evaluate(date)
    }
}

struct AccountService: Sendable {
    let scope: TimeServices
    func balance(asOf: LocalDate? = nil, now: Date = Date()) async throws -> TimeAccountResult {
        // W4: only the days after the last month-end checkpoint are loaded and evaluated (see BalanceCheckpoints.swift).
        let inputs = try await balanceInputs(anchor: asOf, through: asOf, now: now)
        return try balance(inputs: inputs, asOf: asOf, now: now)
    }
    /// Balance over already loaded inputs, so a what-if evaluation (work model preview) can reuse one load for
    /// several model sets without further statements. With a `carry` the snapshot only has to contain the days after
    /// `carry.through`; the days up to it are represented by their precomputed delta sum.
    func balance(snapshot: TimeEvaluationSnapshot, adjustments: [AdjustmentRecord], asOf: LocalDate? = nil, now: Date = Date(),
                 carry: BalanceCarry? = nil) throws -> TimeAccountResult {
        let models = snapshot.models
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: models.last?.timezone ?? "Europe/Berlin")!
        let today = LocalDate.local(now, calendar: calendar)
        // C3 (ADR-0032): `reported` is the requested date (at most today); the day deltas count only through `end`, which is
        // never later than yesterday, so the still running current day does not move the balance (it is returned separately).
        let reported = min(asOf ?? today, today)
        let end = min(reported, today.addingDays(-1))
        let opening = adjustments.first { $0.kind == "opening" }
        guard let start = try accountStart(snapshot: snapshot, adjustments: adjustments, calendar: calendar) else { return .init(asOf: reported, accountStart: nil, balanceSeconds: 0, openingSeconds: 0, adjustmentSeconds: 0, provisional: false) }
        let prepared = snapshot.prepared()
        let carried = carry.flatMap { $0.through >= start && $0.through <= end ? $0 : nil }
        var evaluations: [DayEvaluationResult] = []; var date = carried.map { $0.through.addingDays(1) } ?? start
        while date <= end { evaluations.append(try prepared.evaluate(date, now: now)); date = date.addingDays(1) }
        // Today is shown separately, only when the requested date reaches it and the account has started.
        let todayDelta = reported == today && start <= today ? (try? prepared.evaluate(today, now: now))?.deltaSeconds : nil
        let corrections = try adjustments.filter { $0.kind == "correction" }.map { try AccountAdjustment(date: LocalDate($0.date), seconds: $0.seconds) }
        // Reject unrepresentable totals before invoking the engine's integer reduction.
        func sum(_ values: [Int]) throws -> Int {
            try values.reduce(0) { total, value in
                let (next, overflow) = total.addingReportingOverflow(value)
                guard !overflow else { throw APIError.invalid }; return next
            }
        }
        let correctionTotal = try sum(corrections.filter { $0.date >= start && $0.date <= reported }.map(\.seconds))
        let evaluationTotal = try sum(evaluations.map(\.deltaSeconds) + [carried?.evaluationSeconds ?? 0])
        _ = try sum([opening?.seconds ?? 0, correctionTotal, evaluationTotal])
        if let carried {
            // Same reduction as `TimeEngine.accountBalance` with the carried days folded into one summand.
            let adjustment = corrections.filter { $0.date >= start && $0.date <= reported }.reduce(0) { saturatingAdd($0, $1.seconds) }
            let delta = saturatingAdd(evaluations.reduce(0) { saturatingAdd($0, $1.deltaSeconds) }, carried.evaluationSeconds)
            return TimeAccountResult(asOf: reported, accountStart: start,
                                     balanceSeconds: saturatingAdd(saturatingAdd(opening?.seconds ?? 0, adjustment), delta),
                                     openingSeconds: opening?.seconds ?? 0, adjustmentSeconds: adjustment,
                                     provisional: carried.provisional || evaluations.contains { $0.provisional },
                                     todayDeltaSeconds: todayDelta)
        }
        var result = try TimeEngine.accountBalance(accountStart: start, asOf: reported, today: today, openingSeconds: opening?.seconds ?? 0,
            evaluations: evaluations, adjustments: corrections)
        result.todayDeltaSeconds = todayDelta
        return result
    }
    /// First day of the time account: the opening balance date, else the first work model or live segment, moved back to
    /// the earliest stored adjustment if that lies earlier. Shared by the balance and the statistics series.
    func accountStart(snapshot: TimeEvaluationSnapshot, adjustments: [AdjustmentRecord], calendar: Calendar) throws -> LocalDate? {
        let firstSegmentDate = snapshot.segments.first { !$0.voided }.map { LocalDate.local($0.startedAt, calendar: calendar) }
        let opening = adjustments.first { $0.kind == "opening" }
        if let opening { return try LocalDate(opening.date) }
        // Without an opening balance every stored adjustment must stay inside the account range, so the start is the
        // earlier of the base start (first model, else first live segment) and the earliest adjustment. Days before
        // the first model have Soll 0. Segments before the first model keep being ignored as before.
        let base = snapshot.models.first?.validFrom ?? firstSegmentDate
        let earliestAdjustment = try adjustments.map { try LocalDate($0.date) }.min()
        return [base, earliestAdjustment].compactMap { $0 }.min()
    }
    func adjust(_ input: AdjustmentInput) async throws -> TimeAccountResult {
        try validateReason(input.reason)
        guard ["opening", "correction"].contains(input.kind), (-1_000_000_000...1_000_000_000).contains(input.seconds) else { throw APIError.invalid }
        if input.kind == "opening", try await AdjustmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$opening == 1).first() != nil {
            throw APIError(.conflict, "conflict")
        }
        let row = AdjustmentRecord(); row.accountId = scope.accountId; row.kind = input.kind; row.date = input.date.description
        row.seconds = input.seconds; row.reason = input.reason; row.opening = input.kind == "opening" ? 1 : nil; row.createdAt = Date()
        try await row.create(on: scope.db)
        return try await balance()
    }
    func listAdjustments(limit: Int, offset: Int) async throws -> AdjustmentPage {
        guard (1...100).contains(limit), (0...100_000).contains(offset) else { throw APIError.invalid }
        let query = AdjustmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
        let total = try await query.count()
        let rows = try await AdjustmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
            .sort(\.$createdAt, .descending).sort(\.$id, .descending).range(offset..<(offset + limit)).all()
        let items = try rows.map { row in
            guard let createdAt = row.createdAt else { throw APIError.invalid }
            return try AdjustmentDTO(id: row.requireID(), kind: row.kind, date: row.date, seconds: row.seconds,
                                     reason: row.reason, createdAt: createdAt)
        }
        return .init(items: items, total: total, limit: limit, offset: offset)
    }
    func deleteAdjustment(_ id: UUID) async throws -> TimeAccountResult {
        guard let row = try await AdjustmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
            .filter(\.$id == id).first() else { throw APIError.missing }
        try await row.delete(on: scope.db)
        try await AccountAuditRecord(action: "time_adjustment.deleted", actor: scope.accountId,
                                     target: scope.accountId, detail: id.uuidString).create(on: scope.db)
        return try await balance()
    }
}

struct SuggestionService: Sendable {
    let scope: TimeServices
    func list() async throws -> [SuggestionDTO] {
        try await scope.automation.reviewMissingDeparture()
        return try await SuggestionRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$resolvedAt == nil).all().map(\.payload)
    }
    func record(_ id: UUID) async throws -> SuggestionRecord {
        guard let row = try await SuggestionRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() else { throw APIError.missing }
        return row
    }
    func create(type: String, placeId: UUID?, start: Date?, end: Date?, segmentId: UUID?) async throws -> SuggestionDTO {
        let row = SuggestionRecord(); row.id = UUID(); row.accountId = scope.accountId
        row.payload = try .init(id: row.requireID(), type: type, placeId: placeId, proposedStartedAt: start, proposedEndedAt: end, segmentId: segmentId, createdAt: Date())
        try await row.create(on: scope.db); return row.payload
    }
    func accept(_ id: UUID, input: SuggestionAccept) async throws -> EngineSegment {
        let row = try await record(id)
        guard row.resolvedAt == nil else { throw APIError(.conflict, "suggestion_resolved") }
        let suggestion = row.payload
        let value: EngineSegment
        if suggestion.type == "end", let segmentId = suggestion.segmentId {
            let segment = try await scope.segments.record(segmentId)
            guard segment.endedAt == nil, segment.voidedAt == nil,
                  let end = input.endedAt ?? suggestion.proposedEndedAt else { throw APIError(.conflict, "suggestion_resolved") }
            var next = try segment.dto(); next.endedAt = end; next.needsReview = false
            if let start = input.startedAt { next.startedAt = start }
            value = try await scope.segments.revise(segment, value: next, reason: "End suggestion accepted")
        } else {
            guard let start = input.startedAt ?? suggestion.proposedStartedAt else { throw APIError.invalid }
            let kind: EngineSegmentKind
            if let placeId = suggestion.placeId { kind = try await scope.places.record(placeId).payload.defaultSegmentKind ?? .work } else { kind = .work }
            value = try await scope.segments.create(.init(kind: kind, startedAt: start, endedAt: input.endedAt ?? suggestion.proposedEndedAt, placeId: suggestion.placeId), source: .suggestion)
        }
        row.payload.segmentId = value.id
        row.resolvedAt = Date(); try await row.update(on: scope.db); return value
    }
    func reject(_ id: UUID) async throws {
        let row = try await record(id)
        guard row.resolvedAt == nil else { throw APIError(.conflict, "suggestion_resolved") }
        if row.payload.type == "end", let segmentId = row.payload.segmentId {
            let segment = try await scope.segments.record(segmentId)
            if segment.needsReview, segment.voidedAt == nil {
                var next = try segment.dto(); next.needsReview = false
                _ = try await scope.segments.revise(segment, value: next, reason: "End suggestion rejected")
            }
        }
        row.resolvedAt = Date(); try await row.update(on: scope.db)
    }
}
