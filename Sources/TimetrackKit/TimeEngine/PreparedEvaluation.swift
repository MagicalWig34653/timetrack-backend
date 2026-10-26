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

    /// Name of the public holiday on `date` (built-in table of the configured region plus custom holidays), regardless of the
    /// work model; nil when planning is off or nothing applies.
    func holidayName(on date: LocalDate) -> String? {
        guard snapshot.planningEnabled else { return nil }
        return builtInCalendar(year: date.year).first { $0.kind == .holiday && $0.startDate <= date && date <= $0.endDate }?.name
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

    private func blockWeek(for date: LocalDate, model: EngineWorkModel) throws -> Bool {
        guard let schoolRule = LegalWorkProfile.profile(model.legalProfileId)?.school else { return false }
        let monday = date.addingDays(1 - date.isoWeekday)
        var lessonCount = 0, schoolDays = 0
        for offset in 0..<7 {
            let day = monday.addingDays(offset)
            guard let selected = try timeline.model(for: day), selected.legalProfileId == model.legalProfileId else { continue }
            let key = Key(model: selected.id, date: day)
            if assigned[key, default: []].contains(where: { $0.kind == .school }) {
                schoolDays += 1
                lessonCount += snapshot.preferences[day.description]?.schoolLessonCount ?? 0
            }
        }
        return schoolDays >= schoolRule.blockWeekDays && lessonCount >= schoolRule.blockWeekLessons
    }

    private func baseEvaluation(_ date: LocalDate, now: Date) throws -> (DayEvaluationResult, EngineWorkModel) {
        let selectedModel = try timeline.model(for: date)
        let zone = snapshot.models.last(where: { $0.validFrom <= date })?.timezone ?? snapshot.models.first?.timezone ?? "Europe/Berlin"
        let model = selectedModel ?? EngineWorkModel(validFrom: date, validTo: date, timezone: zone,
            weeklyTargetSeconds: 0, workdays: [], roundingEnabled: false, schoolFullDayThresholdSeconds: Int.max)
        var (preferences, markSource) = try effective(date, explicit: snapshot.preferences[date.description] ?? DayPreferences())
        if selectedModel != nil {
            preferences.schoolBlockWeek = try blockWeek(for: date, model: model)
            if let rule = LegalWorkProfile.profile(model.legalProfileId)?.school, !preferences.schoolBlockWeek {
                let monday = date.addingDays(1 - date.isoWeekday)
                var earlierFullDays = 0
                var earlier = monday
                while earlier < date {
                    if let earlierModel = try timeline.model(for: earlier), earlierModel.legalProfileId == model.legalProfileId,
                       assigned[Key(model: earlierModel.id, date: earlier), default: []].contains(where: { $0.kind == .school }),
                       (snapshot.preferences[earlier.description]?.schoolLessonCount ?? 0) >= rule.fullDayLessons {
                        earlierFullDays += 1
                    }
                    earlier = earlier.addingDays(1)
                }
                preferences.schoolFullDayAllowed = earlierFullDays < rule.fullDaysPerWeek
            }
        }
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
        evaluation.legalProfileId = result.legalProfileId; evaluation.legalWarnings = result.legalWarnings
        evaluation.schoolLessonCount = result.schoolLessonCount
        return (evaluation, model)
    }

    func evaluate(_ date: LocalDate, now: Date) throws -> DayEvaluationResult {
        var (evaluation, model) = try baseEvaluation(date, now: now)
        guard let profile = LegalWorkProfile.profile(model.legalProfileId) else { return evaluation }
        if let minimum = profile.minimumRestSeconds,
           let first = evaluation.segments.map(\.startedAt).min(),
           let previous = try baseEvaluation(date.addingDays(-1), now: now).0.segments.compactMap(\.endedAt).max(),
           first.timeIntervalSince(previous) < Double(minimum) {
            evaluation.legalWarnings.append(.init(.restPeriod))
        }
        if profile.maxWeeklySeconds != nil || profile.maxWorkdaysPerWeek != nil {
            let monday = date.addingDays(1 - date.isoWeekday)
            var seconds = 0, workdays = 0
            for offset in 0..<7 {
                let day = monday.addingDays(offset)
                let (item, selected) = try baseEvaluation(day, now: now)
                guard selected.legalProfileId == model.legalProfileId else { continue }
                let counted = item.creditSeconds > 0 ? item.creditSeconds : item.rawWorkSeconds
                // §4 Abs. 4 JArbSchG: time lost on a public holiday counts towards the weekly working time
                // (the model's Soll of that day, or the worked time if higher); kept out of the workday count.
                let holidayLoss = item.mark == .holiday && item.creditSeconds == 0
                    ? TimeEngine.target(for: day, model: selected) : 0
                seconds += max(counted, holidayLoss)
                if counted > 0 { workdays += 1 }
            }
            if let maximum = profile.maxWeeklySeconds, seconds > maximum { evaluation.legalWarnings.append(.init(.weeklyLimit)) }
            if let maximum = profile.maxWorkdaysPerWeek, workdays > maximum { evaluation.legalWarnings.append(.init(.fiveDayWeek)) }
        }
        return evaluation
    }
}
