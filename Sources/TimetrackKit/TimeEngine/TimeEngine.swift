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
        guard validInstant(start) else { throw TimeEngineError.invalidSegment }
        let calendar = model.calendar
        let date = LocalDate.local(start, calendar: calendar)
        let minutes = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
        return minutes < model.dayBoundaryMinutes ? date.addingDays(-1) : date
    }

    /// Version starts are local midnights; adjacent versions share the successor's start instant.
    static func assignment(for start: Date, models: [EngineWorkModel]) throws -> (model: EngineWorkModel, date: LocalDate)? {
        guard validInstant(start) else { throw TimeEngineError.invalidSegment }
        let sorted = models.sorted { $0.validFrom < $1.validFrom }
        _ = try selectModel(for: LocalDate("2000-01-01"), models: sorted)
        func midnight(_ date: LocalDate, _ model: EngineWorkModel) -> Date {
            model.calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))!
        }
        for index in sorted.indices.reversed() {
            let model = sorted[index]
            guard start >= midnight(model.validFrom, model) else { continue }
            if let end = model.validTo {
                let successor = index + 1 < sorted.count ? sorted[index + 1] : nil
                let limit = successor.map { $0.validFrom == end.addingDays(1) ? midnight($0.validFrom, $0) : midnight(end.addingDays(1), model) }
                    ?? midnight(end.addingDays(1), model)
                guard start < limit else { continue }
            }
            let shifted = try assignedDate(for: start, model: model)
            let bounded = max(shifted, model.validFrom)
            return (model, model.validTo.map { min(bounded, $0) } ?? bounded)
        }
        return nil
    }

    public static func evaluateDay(date: LocalDate, model: EngineWorkModel, segments: [EngineSegment],
                                   preferences: DayPreferences = DayPreferences(), now: Date) throws -> DayEvaluationResult {
        try evaluateAssignedDay(date: date, model: model, segments: segments, preferences: preferences, now: now, preassigned: false)
    }

    static func evaluateAssignedDay(date: LocalDate, model: EngineWorkModel, segments: [EngineSegment],
                                    preferences: DayPreferences, now: Date, preassigned: Bool = true) throws -> DayEvaluationResult {
        try model.validate()
        guard model.contains(date) else { throw TimeEngineError.modelNotEffective }
        guard validInstant(now) else { throw TimeEngineError.invalidSegment }
        guard preferences.creditSeconds.map({ $0 >= 0 }) ?? true else { throw TimeEngineError.invalidPreferences }
        guard preferences.targetOverrideSeconds.map({ $0 >= 0 }) ?? true else { throw TimeEngineError.invalidPreferences }
        guard preferences.schoolLessonCount.map({ (0...20).contains($0) }) ?? true else { throw TimeEngineError.invalidPreferences }
        let legalProfile = LegalWorkProfile.profile(model.legalProfileId)!
        let calendar = model.calendar
        let today = LocalDate.local(now, calendar: calendar)
        var selected: [EngineSegment] = []
        for segment in segments where !segment.voided {
            try validate(segment)
            if try preassigned || assignedDate(for: segment.startedAt, model: model) == date { selected.append(segment) }
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
        let absence = [.holiday, .vacation, .sick, .excused].contains(preferences.mark)
        let target = preferences.targetOverrideSeconds ?? (absence ? 0 : baseTarget)
        // Explicit marks win over automatic school credit; absence without credit still allows actual work.
        let statutorySchool = legalProfile.school != nil && selected.contains { $0.kind == .school }
            && (((preferences.schoolLessonCount ?? 0) >= legalProfile.school!.fullDayLessons && preferences.schoolFullDayAllowed)
                || preferences.schoolBlockWeek)
        let automaticSchool = preferences.mark == .none && selected.contains { $0.kind == .school }
            && (statutorySchool || (legalProfile.school == nil && school >= model.schoolFullDayThresholdSeconds))
        let replacesWork = automaticSchool || preferences.mark == .schoolCredit
            || (absence && preferences.creditSeconds != nil)
        let credit: Int
        if automaticSchool {
            if preferences.schoolBlockWeek, let schoolRule = legalProfile.school {
                credit = schoolRule.blockWeekCreditSeconds / schoolRule.blockWeekDays
            } else {
                credit = statutorySchool ? legalProfile.school!.fullDayCreditSeconds : (model.schoolCreditSeconds ?? baseTarget)
            }
        }
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
        var result = DayEvaluationResult(
            date: date, modelId: model.id, mark: preferences.mark, skipFixedBreaks: preferences.skipFixedBreaks,
            targetSeconds: target, rawWorkSeconds: raw, breakDeductionSeconds: deduction,
            startAdjustSeconds: startAdjust, endAdjustSeconds: endAdjust,
            evaluatedWorkSeconds: replacesWork ? 0 : raw - deduction + startAdjust + endAdjust,
            creditSeconds: credit, evaluatedStart: replacesWork ? nil : start, evaluatedEnd: replacesWork ? nil : end,
            provisional: date <= today && selected.contains { $0.endedAt == nil && $0.startedAt <= now },
            segmentIds: selected.map(\.id), segments: selected, markCreditSeconds: preferences.creditSeconds,
            note: preferences.note, breakHints: hints(intervals, profile: legalProfile))
        result.legalProfileId = legalProfile.id
        result.schoolLessonCount = preferences.schoolLessonCount
        if let maximum = legalProfile.maxDailySeconds, raw > maximum {
            result.legalWarnings.append(.init(.dailyLimit))
        }
        if !legalProfile.restrictedWeekdays.isEmpty, legalProfile.restrictedWeekdays.contains(date.isoWeekday),
           selected.contains(where: { $0.kind != .school }) {
            result.legalWarnings.append(.init(.weekendWork))
        }
        // §9 JArbSchG: on a full school day (more than five lessons) any other work is flagged, also before school.
        if statutorySchool && selected.contains(where: { $0.kind != .school }) {
            result.legalWarnings.append(.init(.workAfterFullSchoolDay))
        }
        if let schoolRule = legalProfile.school, selected.contains(where: { $0.kind == .school }),
           selected.contains(where: { segment in
               segment.kind != .school && calendar.component(.hour, from: segment.startedAt) * 60
                   + calendar.component(.minute, from: segment.startedAt) < schoolRule.noWorkBeforeMinutes
           }) { result.legalWarnings.append(.init(.workBeforeSchool)) }
        return result
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
        let adjustment = adjustments.filter { $0.date >= accountStart && $0.date <= cutoff }.reduce(0) { saturatingAdd($0, $1.seconds) }
        return TimeAccountResult(asOf: cutoff, accountStart: accountStart,
                                 balanceSeconds: saturatingAdd(saturatingAdd(openingSeconds, adjustment), included.reduce(0) { saturatingAdd($0, $1.deltaSeconds) }),
                                 openingSeconds: openingSeconds, adjustmentSeconds: adjustment,
                                 provisional: (accountStart <= today && cutoff == today) || included.contains { $0.provisional })
    }

    /// Builds every day (including empty workdays). The account time zone explicitly defines today's cutoff.
    public static func accountBalance(accountStart: LocalDate, asOf: LocalDate, timezone: String,
                                      models: [EngineWorkModel], segments: [EngineSegment],
                                      preferences: [LocalDate: DayPreferences] = [:], now: Date,
                                      openingSeconds: Int = 0, adjustments: [AccountAdjustment] = []) throws -> TimeAccountResult {
        guard let zone = TimeZone(identifier: timezone), validInstant(now) else {
            throw TimeEngineError.invalidModel
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = LocalDate.local(now, calendar: calendar)
        var date = accountStart
        var evaluations: [DayEvaluationResult] = []
        _ = try selectModel(for: date, models: models)
        let prepared = TimeEvaluationSnapshot(models: models, segments: segments,
            preferences: Dictionary(uniqueKeysWithValues: preferences.map { ($0.key.description, $0.value) }),
            planningEnabled: false).prepared()
        while date <= min(asOf, today) {
            guard try selectModel(for: date, models: models) != nil else { throw TimeEngineError.missingModel(date) }
            evaluations.append(try prepared.evaluate(date, now: now))
            date = date.addingDays(1)
        }
        return try accountBalance(accountStart: accountStart, asOf: asOf, today: today, openingSeconds: openingSeconds,
                                  evaluations: evaluations, adjustments: adjustments)
    }

    static func target(for date: LocalDate, model: EngineWorkModel) -> Int {
        // The civil weekday of the date; local noon of an existing date always falls on it.
        let weekday = LocalDate.fastYears.contains(date.year)
            ? date.isoWeekday
            : (model.calendar.component(.weekday, from: instant(date, minutes: 720, calendar: model.calendar)) + 5) % 7 + 1
        guard model.workdays.contains(weekday) else { return 0 }
        return model.dailyTargetSeconds[weekday] ?? (model.weeklyTargetSeconds / model.workdays.count)
    }
    static func isValidInstant(_ date: Date) -> Bool { validInstant(date) }
    private static func validInstant(_ date: Date) -> Bool {
        (-62_135_769_600...253_402_387_200).contains(date.timeIntervalSince1970)
    }
    private static func validate(_ segment: EngineSegment) throws {
        guard validInstant(segment.startedAt),
              segment.endedAt.map({ validInstant($0) && $0 > segment.startedAt }) ?? true else {
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
        guard calendar.identifier == .gregorian, LocalDate.fastYears.contains(date.year) else {
            return computeInstant(date, minutes: minutes, calendar: calendar, repeated: repeated)
        }
        let key = InstantCache.Key(zone: calendar.timeZone.identifier, epochDays: date.epochDays, minutes: minutes,
                                   last: repeated == .last)
        if let hit = InstantCache.shared.value(for: key) { return hit }
        let value = computeInstant(date, minutes: minutes, calendar: calendar, repeated: repeated)
        InstantCache.shared.store(value, for: key)
        return value
    }
    private static func computeInstant(_ date: LocalDate, minutes: Int, calendar: Calendar,
                                       repeated: Calendar.RepeatedTimePolicy) -> Date {
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
        // For a fixed occurrence policy the candidates grow monotonically with (day, minute), so the best
        // candidate is found by bisection instead of evaluating all of them (reference: roundedExhaustive).
        let days = [date.addingDays(-1), date, date.addingDays(1)]
        let slots = Array(stride(from: 0, to: 1440, by: model.roundingMinutes))
        var best: Date?
        for occurrence in [Calendar.RepeatedTimePolicy.first, .last] {
            func candidate(_ index: Int) -> Date {
                instant(days[index / slots.count], minutes: slots[index % slots.count], calendar: calendar, repeated: occurrence)
            }
            var low = 0, high = days.count * slots.count   // first index that does NOT satisfy `keep`
            let keep: (Date) -> Bool = down ? { $0 <= value } : { $0 < value }
            while low < high {
                let mid = (low + high) / 2
                if keep(candidate(mid)) { low = mid + 1 } else { high = mid }
            }
            if down {
                guard low > 0 else { continue }
                let found = candidate(low - 1)
                best = max(best ?? found, found)
            } else {
                guard low < days.count * slots.count else { continue }
                let found = candidate(low)
                best = min(best ?? found, found)
            }
        }
        return best ?? value
    }
    /// Brute-force reference for `rounded` (kept for the equivalence test).
    static func roundedExhaustive(_ value: Date, down: Bool, model: EngineWorkModel) -> Date {
        let calendar = model.calendar
        let date = LocalDate.local(value, calendar: calendar)
        var best: Date?
        for day in [date.addingDays(-1), date, date.addingDays(1)] {
            for minute in stride(from: 0, to: 1440, by: model.roundingMinutes) {
                for occurrence in [Calendar.RepeatedTimePolicy.first, .last] {
                    let candidate = computeInstant(day, minutes: minute, calendar: calendar, repeated: occurrence)
                    if down && candidate <= value { best = max(best ?? candidate, candidate) }
                    if !down && candidate >= value { best = min(best ?? candidate, candidate) }
                }
            }
        }
        return best ?? value
    }
    static func roundedFast(_ value: Date, down: Bool, model: EngineWorkModel) -> Date { rounded(value, down: down, model: model) }
    private static func hints(_ intervals: [Span], profile: LegalWorkProfile) -> [BreakHint] {
        guard let first = intervals.first else { return [] }
        var qualifiedBreak = 0
        var shortPart = false
        var continuousWork = first.seconds
        var longestWork = continuousWork
        for (left, right) in zip(intervals, intervals.dropFirst()) {
            let gap = seconds(right.start, since: left.end)
            if gap >= profile.minimumBreakPartSeconds { qualifiedBreak += gap; continuousWork = right.seconds }
            else { if gap > 0 { shortPart = true }; continuousWork += right.seconds }
            longestWork = max(longestWork, continuousWork)
        }
        let work = intervals.reduce(0) { $0 + $1.seconds }
        var codes: [BreakHint.Code] = []
        if let rule = profile.breakRules.last(where: { work > $0.afterSeconds && qualifiedBreak < $0.requiredSeconds }) {
            codes.append(rule.requiredSeconds == 3_600 ? .breakMissing60 : rule.requiredSeconds == 2_700 ? .breakMissing45 : .breakMissing30)
        }
        if shortPart { codes.append(.breakPartTooShort) }
        if longestWork > profile.maximumContinuousSeconds {
            codes.append(profile.maximumContinuousSeconds == 16_200 ? .workOver4h30WithoutBreak : .workOver6hWithoutBreak)
        }
        return codes.map { BreakHint(code: $0) }
    }
}

/// Process-wide memo of wall-clock-to-instant conversions. The conversion is a pure function of the time zone
/// rules, so caching it never changes a result; the cache is simply emptied when it grows large.
final class InstantCache: @unchecked Sendable {
    struct Key: Hashable { let zone: String; let epochDays: Int; let minutes: Int; let last: Bool }
    static let shared = InstantCache()
    private let lock = NSLock()
    private var storage: [Key: Date] = [:]
    func value(for key: Key) -> Date? { lock.lock(); defer { lock.unlock() }; return storage[key] }
    func store(_ value: Date, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        if storage.count >= 400_000 { storage.removeAll(keepingCapacity: true) }
        storage[key] = value
    }
}
