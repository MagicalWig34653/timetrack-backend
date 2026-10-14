import Foundation

public enum TimeEngine {
    /// Validates the entire version set, including overlaps outside the requested date.
    public static func selectModel(for date: LocalDate, models: [EngineWorkModel]) throws -> EngineWorkModel? {
        let sorted = models.sorted { $0.validFrom < $1.validFrom }
        for model in sorted { try model.validate() }
        for (left, right) in zip(sorted, sorted.dropFirst()) {
            guard let end = left.validTo, end < right.validFrom else { throw TimeEngineError.overlappingModels }
        }
        return sorted.first { $0.contains(date) }
    }

    /// Subtracts the boundary in wall-clock minutes, not elapsed seconds across DST transitions.
    public static func assignedDate(for start: Date, model: EngineWorkModel) throws -> LocalDate {
        try model.validate()
        guard start.timeIntervalSince1970.isFinite else { throw TimeEngineError.invalidSegment }
        let calendar = model.calendar
        let date = LocalDate.local(start, calendar: calendar)
        let minutes = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
        return minutes < model.dayBoundaryMinutes ? date.addingDays(-1) : date
    }

    public static func evaluateDay(date: LocalDate, model: EngineWorkModel, segments: [EngineSegment],
                                   preferences: DayPreferences = DayPreferences(), now: Date) throws -> DayEvaluationResult {
        try model.validate()
        guard model.contains(date) else { throw TimeEngineError.modelNotEffective }
        guard now.timeIntervalSince1970.isFinite else { throw TimeEngineError.invalidSegment }
        guard preferences.creditSeconds.map({ $0 >= 0 }) ?? true else { throw TimeEngineError.invalidPreferences }
        let calendar = model.calendar
        let today = LocalDate.local(now, calendar: calendar)
        var selected: [EngineSegment] = []
        for segment in segments where !segment.voided {
            try validate(segment)
            if try assignedDate(for: segment.startedAt, model: model) == date { selected.append(segment) }
        }
        selected.sort {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }
        guard Set(selected.map(\.id)).count == selected.count else { throw TimeEngineError.duplicateSegmentID }
        for (left, right) in zip(selected, selected.dropFirst()) {
            if try detectOverlap(left, right) { throw TimeEngineError.overlappingSegments }
        }
        let counting = selected.filter { $0.kind != .travel || model.travelCountsAsWork }
        let intervals = counting.compactMap { segment -> Span? in
            let end = segment.endedAt ?? now
            return end > segment.startedAt ? Span(start: wholeSecond(segment.startedAt), end: wholeSecond(end)) : nil
        }.filter { $0.end > $0.start }
        let raw = intervals.reduce(0) { $0 + $1.seconds }
        let school = selected.filter { $0.kind == .school }.reduce(0) {
            $0 + max(0, seconds(wholeSecond($1.endedAt ?? now), since: wholeSecond($1.startedAt)))
        }
        let baseTarget = target(for: date, model: model)
        let absence = [.holiday, .vacation, .sick].contains(preferences.mark)
        let target = absence ? 0 : baseTarget
        // Explicit marks win over automatic school credit; absence without credit still allows actual work.
        let automaticSchool = preferences.mark == .none && selected.contains { $0.kind == .school }
            && school >= model.schoolFullDayThresholdSeconds
        let replacesWork = automaticSchool || preferences.mark == .schoolCredit
            || (absence && preferences.creditSeconds != nil)
        let credit: Int
        if automaticSchool { credit = model.schoolCreditSeconds ?? baseTarget }
        else if preferences.mark == .schoolCredit { credit = preferences.creditSeconds ?? model.schoolCreditSeconds ?? baseTarget }
        else if absence { credit = preferences.creditSeconds ?? 0 }
        else { credit = 0 }

        let breaks = preferences.skipFixedBreaks ? [] : fixedBreakSpans(for: date, model: model)
        let deduction = intervals.reduce(0) { total, span in
            total + breaks.reduce(0) { $0 + max(0, seconds(min(span.end, $1.end), since: max(span.start, $1.start))) }
        }
        var start = intervals.first?.start
        var end = intervals.last?.end
        var startAdjust = 0
        var endAdjust = 0
        if model.roundingEnabled, let first = start, let last = end, !replacesWork {
            start = rounded(first, down: true, model: model)
            end = rounded(last, down: false, model: model)
            startAdjust = seconds(first, since: start!)
            endAdjust = seconds(end!, since: last)
        }
        return DayEvaluationResult(
            date: date, modelId: model.id, mark: preferences.mark, skipFixedBreaks: preferences.skipFixedBreaks,
            targetSeconds: target, rawWorkSeconds: raw, breakDeductionSeconds: deduction,
            startAdjustSeconds: startAdjust, endAdjustSeconds: endAdjust,
            evaluatedWorkSeconds: replacesWork ? 0 : raw - deduction + startAdjust + endAdjust,
            creditSeconds: credit, evaluatedStart: replacesWork ? nil : start, evaluatedEnd: replacesWork ? nil : end,
            provisional: date <= today && selected.contains { $0.endedAt == nil && $0.startedAt <= now },
            segmentIds: selected.map(\.id), segments: selected, markCreditSeconds: preferences.creditSeconds,
            note: preferences.note, breakHints: hints(intervals))
    }

    /// Half-open intervals: touching boundaries do not overlap; an open end extends indefinitely.
    /// When checking a correction, the caller must remove the stored version of the same ID first.
    public static func detectOverlap(_ left: EngineSegment, _ right: EngineSegment) throws -> Bool {
        guard !left.voided, !right.voided else { return false }
        try validate(left); try validate(right)
        return left.startedAt < (right.endedAt ?? .distantFuture)
            && right.startedAt < (left.endedAt ?? .distantFuture)
    }

    /// Reduces complete, unique day evaluations. Callers must supply every date in the account range.
    public static func accountBalance(accountStart: LocalDate, asOf: LocalDate, today: LocalDate,
                                      openingSeconds: Int = 0, evaluations: [DayEvaluationResult],
                                      adjustments: [AccountAdjustment] = []) throws -> TimeAccountResult {
        let cutoff = min(asOf, today)
        let included = evaluations.filter { $0.date >= accountStart && $0.date <= cutoff }
        guard Set(included.map(\.date)).count == included.count else { throw TimeEngineError.duplicateEvaluationDate }
        var date = accountStart
        let dates = Set(included.map(\.date))
        while date <= cutoff {
            guard dates.contains(date) else { throw TimeEngineError.missingEvaluation(date) }
            date = date.addingDays(1)
        }
        let adjustment = adjustments.filter { $0.date >= accountStart && $0.date <= cutoff }.reduce(0) { $0 + $1.seconds }
        return TimeAccountResult(asOf: cutoff, accountStart: accountStart,
                                 balanceSeconds: openingSeconds + adjustment + included.reduce(0) { $0 + $1.deltaSeconds },
                                 openingSeconds: openingSeconds, adjustmentSeconds: adjustment,
                                 provisional: (accountStart <= today && cutoff == today) || included.contains { $0.provisional })
    }

    /// Builds every day (including empty workdays). The account time zone explicitly defines today's cutoff.
    public static func accountBalance(accountStart: LocalDate, asOf: LocalDate, timezone: String,
                                      models: [EngineWorkModel], segments: [EngineSegment],
                                      preferences: [LocalDate: DayPreferences] = [:], now: Date,
                                      openingSeconds: Int = 0, adjustments: [AccountAdjustment] = []) throws -> TimeAccountResult {
        guard let zone = TimeZone(identifier: timezone), now.timeIntervalSince1970.isFinite else {
            throw TimeEngineError.invalidModel
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = LocalDate.local(now, calendar: calendar)
        var date = accountStart
        var evaluations: [DayEvaluationResult] = []
        _ = try selectModel(for: date, models: models)
        while date <= min(asOf, today) {
            guard let model = try selectModel(for: date, models: models) else { throw TimeEngineError.missingModel(date) }
            evaluations.append(try evaluateDay(date: date, model: model, segments: segments,
                                               preferences: preferences[date] ?? DayPreferences(), now: now))
            date = date.addingDays(1)
        }
        return try accountBalance(accountStart: accountStart, asOf: asOf, today: today, openingSeconds: openingSeconds,
                                  evaluations: evaluations, adjustments: adjustments)
    }

    private static func target(for date: LocalDate, model: EngineWorkModel) -> Int {
        let weekday = (model.calendar.component(.weekday, from: instant(date, minutes: 720, calendar: model.calendar)) + 5) % 7 + 1
        guard model.workdays.contains(weekday) else { return 0 }
        return model.dailyTargetSeconds[weekday] ?? (model.weeklyTargetSeconds / model.workdays.count)
    }
    private static func validate(_ segment: EngineSegment) throws {
        guard segment.startedAt.timeIntervalSince1970.isFinite,
              segment.endedAt.map({ $0.timeIntervalSince1970.isFinite && $0 > segment.startedAt }) ?? true else {
            throw TimeEngineError.invalidSegment
        }
    }
    private static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }
    private static func seconds(_ end: Date, since start: Date) -> Int { Int(end.timeIntervalSince(start)) }
    private struct Span {
        var start: Date
        var end: Date
        var seconds: Int { TimeEngine.seconds(end, since: start) }
    }

    /// Missing wall times advance to the next valid time; repeated times use the requested occurrence.
    private static func instant(_ date: LocalDate, minutes: Int, calendar: Calendar,
                                repeated: Calendar.RepeatedTimePolicy = .first) -> Date {
        let noon = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: 12))!
        let midnight = calendar.startOfDay(for: noon)
        return calendar.nextDate(after: midnight.addingTimeInterval(-1),
                                 matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
                                 matchingPolicy: .nextTime, repeatedTimePolicy: repeated, direction: .forward)!
    }
    private static func fixedBreakSpans(for date: LocalDate, model: EngineWorkModel) -> [Span] {
        let spans = model.fixedBreaks.map { template in
            // Times before the workday boundary occur on the following civil date.
            let startDate = template.start.minutes < model.dayBoundaryMinutes ? date.addingDays(1) : date
            var endDate = template.end.minutes < model.dayBoundaryMinutes ? date.addingDays(1) : date
            if endDate < startDate || (endDate == startDate && template.end.minutes < template.start.minutes) {
                endDate = startDate.addingDays(1)
            }
            return Span(start: instant(startDate, minutes: template.start.minutes, calendar: model.calendar),
                        end: instant(endDate, minutes: template.end.minutes, calendar: model.calendar))
        }.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [Span] = []
        for span in spans {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else { merged.append(span) }
        }
        return merged
    }
    private static func rounded(_ value: Date, down: Bool, model: EngineWorkModel) -> Date {
        let calendar = model.calendar
        let date = LocalDate.local(value, calendar: calendar)
        // Enumerating both occurrences preserves the rounding direction in the repeated DST hour.
        var best: Date?
        for day in [date.addingDays(-1), date, date.addingDays(1)] {
            for minute in stride(from: 0, to: 1440, by: model.roundingMinutes) {
                for occurrence in [Calendar.RepeatedTimePolicy.first, .last] {
                    let candidate = instant(day, minutes: minute, calendar: calendar, repeated: occurrence)
                    if down && candidate <= value { best = max(best ?? candidate, candidate) }
                    if !down && candidate >= value { best = min(best ?? candidate, candidate) }
                }
            }
        }
        return best!
    }
    private static func hints(_ intervals: [Span]) -> [BreakHint] {
        guard let first = intervals.first else { return [] }
        var qualifiedBreak = 0
        var shortPart = false
        var continuousWork = first.seconds
        var longestWork = continuousWork
        for (left, right) in zip(intervals, intervals.dropFirst()) {
            let gap = seconds(right.start, since: left.end)
            if gap >= 900 { qualifiedBreak += gap; continuousWork = right.seconds }
            else { if gap > 0 { shortPart = true }; continuousWork += right.seconds }
            longestWork = max(longestWork, continuousWork)
        }
        let work = intervals.reduce(0) { $0 + $1.seconds }
        var codes: [BreakHint.Code] = []
        if work > 32_400 && qualifiedBreak < 2700 { codes.append(.breakMissing45) }
        else if work > 21_600 && qualifiedBreak < 1800 { codes.append(.breakMissing30) }
        if shortPart { codes.append(.breakPartTooShort) }
        if longestWork > 21_600 { codes.append(.workOver6hWithoutBreak) }
        return codes.map { BreakHint(code: $0) }
    }
}
