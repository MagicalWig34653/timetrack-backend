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
    func snapshot(window: ClosedRange<LocalDate>? = nil) async throws -> TimeEvaluationSnapshot {
        let models = try await scope.models.list().map { try $0.engine() }
        let segments = try await scope.segments.all(window: window)
        let query = DayPreferenceRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
        if let window { query.filter(\.$date >= window.lowerBound.description).filter(\.$date <= window.upperBound.description) }
        let rows = try await query.all()
        let preferences = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row.date, DayPreferences(mark: DayMarkKind(rawValue: row.mark) ?? .none,
                creditSeconds: row.creditSeconds, skipFixedBreaks: row.skipFixedBreaks, note: row.note))
        })
        guard try await scope.modules.enabled(.planning, account: scope.accountId, on: scope.db) else {
            return .init(models: models, segments: segments, preferences: preferences, planningEnabled: false)
        }
        return .init(models: models, segments: segments, preferences: preferences,
                     absences: try await scope.vacation.engineAbsences(window: window), customDays: try await scope.vacation.customDays(),
                     region: try await scope.vacation.settings().region)
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
        guard input.creditSeconds.map({ (0...86_400).contains($0) }) ?? true, input.note?.fitsColumn(200) ?? true else { throw APIError.invalid }
        let existing = try await preference(date)
        let row = existing ?? DayPreferenceRecord()
        if existing == nil { row.accountId = scope.accountId; row.date = date.description; row.mark = "none"; row.skipFixedBreaks = false }
        if let mark = input.mark { row.mark = mark.rawValue }
        if let skip = input.skipFixedBreaks { row.skipFixedBreaks = skip }
        if input.hasCredit { row.creditSeconds = input.creditSeconds }
        if input.hasNote { row.note = input.note }
        if row.mark == "none" { row.creditSeconds = nil }
        try await row.save(on: scope.db)
        return try await evaluate(date)
    }
}

struct AccountService: Sendable {
    let scope: TimeServices
    func balance(asOf: LocalDate? = nil, now: Date = Date()) async throws -> TimeAccountResult {
        let snapshot = try await scope.days.snapshot()
        let adjustments = try await AdjustmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).all()
        return try balance(snapshot: snapshot, adjustments: adjustments, asOf: asOf, now: now)
    }
    /// Balance over already loaded inputs, so a what-if evaluation (work model preview) can reuse one load for
    /// several model sets without further statements.
    func balance(snapshot: TimeEvaluationSnapshot, adjustments: [AdjustmentRecord], asOf: LocalDate? = nil, now: Date = Date()) throws -> TimeAccountResult {
        let models = snapshot.models
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: models.last?.timezone ?? "Europe/Berlin")!
        let today = LocalDate.local(now, calendar: calendar)
        let end = min(asOf ?? today, today)
        let opening = adjustments.first { $0.kind == "opening" }
        let segments = snapshot.segments.filter { !$0.voided }
        let firstSegmentDate = segments.first.map { LocalDate.local($0.startedAt, calendar: calendar) }
        let start = try opening.map { try LocalDate($0.date) } ?? models.first?.validFrom ?? firstSegmentDate ?? adjustments.map { try LocalDate($0.date) }.min()
        guard let start else { return .init(asOf: end, accountStart: nil, balanceSeconds: 0, openingSeconds: 0, adjustmentSeconds: 0, provisional: false) }
        let prepared = snapshot.prepared()
        var evaluations: [DayEvaluationResult] = []; var date = start
        while date <= end { evaluations.append(try prepared.evaluate(date, now: now)); date = date.addingDays(1) }
        let corrections = try adjustments.filter { $0.kind == "correction" }.map { try AccountAdjustment(date: LocalDate($0.date), seconds: $0.seconds) }
        // Reject unrepresentable totals before invoking the engine's integer reduction.
        func sum(_ values: [Int]) throws -> Int {
            try values.reduce(0) { total, value in
                let (next, overflow) = total.addingReportingOverflow(value)
                guard !overflow else { throw APIError.invalid }; return next
            }
        }
        let correctionTotal = try sum(corrections.filter { $0.date >= start && $0.date <= end }.map(\.seconds))
        let evaluationTotal = try sum(evaluations.map(\.deltaSeconds))
        _ = try sum([opening?.seconds ?? 0, correctionTotal, evaluationTotal])
        return try TimeEngine.accountBalance(accountStart: start, asOf: end, today: today, openingSeconds: opening?.seconds ?? 0,
            evaluations: evaluations, adjustments: corrections)
    }
    func adjust(_ input: AdjustmentInput) async throws -> TimeAccountResult {
        try validateReason(input.reason)
        guard ["opening", "correction"].contains(input.kind), (-1_000_000_000...1_000_000_000).contains(input.seconds) else { throw APIError.invalid }
        if input.kind == "opening", try await AdjustmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$opening == 1).first() != nil {
            throw APIError(.conflict, "conflict")
        }
        let row = AdjustmentRecord(); row.accountId = scope.accountId; row.kind = input.kind; row.date = input.date.description
        row.seconds = input.seconds; row.reason = input.reason; row.opening = input.kind == "opening" ? 1 : nil
        try await row.create(on: scope.db)
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
            var next = try segment.dto(); next.endedAt = end
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
        row.resolvedAt = Date(); try await row.update(on: scope.db)
    }
}
