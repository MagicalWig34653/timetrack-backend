import Foundation

/// Work models sorted and validated once, with the per-model instants that `TimeEngine.assignment` needs.
/// `assignment(for:)` mirrors `TimeEngine.assignment(for:models:)` exactly (that function stays as the reference
/// implementation for the equivalence tests) but does not repeat the sorting, validation and calendar work per segment.
struct ModelTimeline {
    let sorted: [EngineWorkModel]
    private let calendars: [Calendar]
    private let startMidnights: [Date]
    private let limits: [Date?]
    /// First failure of the whole-set validation (`TimeEngine.selectModel`); thrown by every lookup.
    let validationError: (any Error)?

    init(models: [EngineWorkModel]) {
        let sorted = models.sorted { $0.validFrom < $1.validFrom }
        self.sorted = sorted
        var failure: (any Error)?
        do {
            for model in sorted { try model.validate() }
            for (left, right) in zip(sorted, sorted.dropFirst()) {
                guard let end = left.validTo, end < right.validFrom else { throw TimeEngineError.overlappingModels }
            }
        } catch { failure = error }
        validationError = failure
        guard failure == nil else { calendars = []; startMidnights = []; limits = []; return }
        let calendars = sorted.map(\.calendar)
        func midnight(_ date: LocalDate, _ index: Int) -> Date {
            calendars[index].date(from: DateComponents(year: date.year, month: date.month, day: date.day))!
        }
        let starts = sorted.indices.map { midnight(sorted[$0].validFrom, $0) }
        self.calendars = calendars
        startMidnights = starts
        limits = sorted.indices.map { index -> Date? in
            guard let end = sorted[index].validTo else { return nil }
            let successor = index + 1 < sorted.count ? sorted[index + 1] : nil
            if let successor, successor.validFrom == end.addingDays(1) { return starts[index + 1] }
            return midnight(end.addingDays(1), index)
        }
    }

    func model(for date: LocalDate) throws -> EngineWorkModel? {
        if let validationError { throw validationError }
        return sorted.first { $0.contains(date) }
    }

    func assignment(for start: Date) throws -> (model: EngineWorkModel, date: LocalDate)? {
        guard TimeEngine.isValidInstant(start) else { throw TimeEngineError.invalidSegment }
        if let validationError { throw validationError }
        for index in sorted.indices.reversed() {
            guard start >= startMidnights[index] else { continue }
            if let limit = limits[index], !(start < limit) { continue }
            let model = sorted[index]
            let calendar = calendars[index]
            let local = LocalDate.local(start, calendar: calendar)
            let minutes = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
            let shifted = minutes < model.dayBoundaryMinutes ? local.addingDays(-1) : local
            let bounded = max(shifted, model.validFrom)
            return (model, model.validTo.map { min(bounded, $0) } ?? bounded)
        }
        return nil
    }
}

/// Day evaluation over a snapshot, prepared once: segments are assigned to (model, day) a single time, holiday
/// calendars are built once per year, and the validations that used to run for every single day run once.
/// The result of `evaluate` is identical to the original per-day filtering implementation
/// (`TimeEvaluationSnapshot.evaluateReference`, kept as the oracle of the equivalence tests).
final class PreparedEvaluation {
    private struct Key: Hashable { let model: UUID; let date: LocalDate }
    private let snapshot: TimeEvaluationSnapshot
    private let timeline: ModelTimeline
    private var assigned: [Key: [EngineSegment]] = [:]
    private var unassigned: [EngineSegment] = []
    /// First error the per-segment assignment raised (in segment order), rethrown where the filter used to throw.
    private var assignmentError: (any Error)?
    private var gapByZone: [String: [LocalDate: [EngineSegment]]] = [:]
    private var holidayDays: [Int: [CustomCalendarDay]] = [:]
    private lazy var calendarError: (any Error)? = { do { try HolidayCalendar.validate(snapshot.customDays) } catch { return error }; return nil }()
    private lazy var overlapError: (any Error)? = { do { try VacationEngine.validateNoOverlap(snapshot.absences) } catch { return error }; return nil }()

    init(_ snapshot: TimeEvaluationSnapshot) {
        self.snapshot = snapshot
        timeline = ModelTimeline(models: snapshot.models)
        guard timeline.validationError == nil else { return }
        for segment in snapshot.segments where !segment.voided {
            do {
                if let owner = try timeline.assignment(for: segment.startedAt) {
                    assigned[Key(model: owner.model.id, date: owner.date), default: []].append(segment)
                } else { unassigned.append(segment) }
            } catch { assignmentError = assignmentError ?? error; break }
        }
    }

    private func builtInCalendar(year: Int) -> [CustomCalendarDay] {
        if let cached = holidayDays[year] { return cached }
        // Years outside the built-in catalogue simply have no built-in holidays.
        let days = ((try? HolidayCalendar.holidays(year: year, region: snapshot.region)) ?? []) + snapshot.customDays
        holidayDays[year] = days
        return days
    }

    /// Precedence (ADR-0005, contract v0.3.2): explicit mark > holiday on a model workday > approved/taken absence.
    private func effective(_ date: LocalDate, explicit: DayPreferences) throws -> (DayPreferences, DayMarkSource) {
        if explicit.mark != .none { return (explicit, .explicit) }
        guard snapshot.planningEnabled else { return (explicit, .none) }
        let days = builtInCalendar(year: date.year)
        if let calendarError { throw calendarError }
        let model = try timeline.model(for: date)
        let holiday = AbsenceDayEffects.apply(for: date, model: model, absences: [], calendarDays: days, explicit: explicit)
        if holiday.mark == .holiday { return (holiday, .holiday) }
        if let overlapError { throw overlapError }
        let result = AbsenceDayEffects.apply(for: date, model: model, absences: snapshot.absences, calendarDays: days, explicit: explicit)
        return (result, result.mark == .none ? .none : .absence)
    }

    private func segments(on date: LocalDate, selected: EngineWorkModel?, zone: String) throws -> [EngineSegment] {
        if let assignmentError { throw assignmentError }
        if let selected { return assigned[Key(model: selected.id, date: date)] ?? [] }
        // Outside every model: the civil date in the time zone that applies to this date.
        if unassigned.isEmpty { return [] }
        if gapByZone[zone] == nil {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            var index: [LocalDate: [EngineSegment]] = [:]
            for segment in unassigned { index[LocalDate.local(segment.startedAt, calendar: calendar), default: []].append(segment) }
            gapByZone[zone] = index
        }
        return gapByZone[zone]?[date] ?? []
    }

    func evaluate(_ date: LocalDate, now: Date) throws -> DayEvaluationResult {
        let selectedModel = try timeline.model(for: date)
        // A model gap has no contractual target or rounding rules. Keep actual time visible.
        let zone = snapshot.models.last(where: { $0.validFrom <= date })?.timezone ?? snapshot.models.first?.timezone ?? "Europe/Berlin"
        let model = selectedModel ?? EngineWorkModel(validFrom: date, validTo: date, timezone: zone,
            weeklyTargetSeconds: 0, workdays: [], roundingEnabled: false, schoolFullDayThresholdSeconds: Int.max)
        let (preferences, markSource) = try effective(date, explicit: snapshot.preferences[date.description] ?? DayPreferences())
        let segments = try segments(on: date, selected: selectedModel, zone: zone)
        let result = try TimeEngine.evaluateAssignedDay(date: date, model: model, segments: segments, preferences: preferences, now: now)
        var evaluation = DayEvaluationResult(date: result.date, modelId: selectedModel?.id, mark: result.mark,
            skipFixedBreaks: result.skipFixedBreaks, targetSeconds: result.targetSeconds, rawWorkSeconds: result.rawWorkSeconds,
            breakDeductionSeconds: result.breakDeductionSeconds, startAdjustSeconds: result.startAdjustSeconds, endAdjustSeconds: result.endAdjustSeconds,
            evaluatedWorkSeconds: result.evaluatedWorkSeconds, creditSeconds: result.creditSeconds,
            evaluatedStart: result.evaluatedStart, evaluatedEnd: result.evaluatedEnd,
            provisional: date == LocalDate.local(now, calendar: model.calendar) || result.provisional,
            segmentIds: result.segmentIds, segments: result.segments, markCreditSeconds: result.markCreditSeconds, note: result.note, breakHints: result.breakHints)
        evaluation.markSource = markSource; evaluation.targetOverrideSeconds = preferences.targetOverrideSeconds
        return evaluation
    }
}
