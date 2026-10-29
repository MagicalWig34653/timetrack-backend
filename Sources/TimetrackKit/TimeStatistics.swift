import Foundation
import Fluent

/// GET /time/statistics (W3): read-only series for charts, derived from the day evaluation only. Nothing here changes
/// evaluation rules, rounding or legal profiles; the series just groups the same per-day results by day, ISO week or month.
enum StatisticsGranularity: String, Sendable { case day, week, month }
/// `evaluated` follows the account rules (rounded start/end, fixed breaks); `raw` removes only the rounding adjustment.
enum StatisticsBasis: String, Sendable { case evaluated, raw }

struct TimeStatisticsBucket: Encodable, Sendable {
    struct Kinds: Encodable, Sendable { var work = 0, school = 0, travel = 0 }
    struct Absences: Encodable, Sendable { var vacation = 0.0, sick = 0.0, excused = 0.0, holiday = 0.0, school = 0.0 }
    var label: String
    /// First and last day of the bucket inside the requested range (edge buckets can be partial).
    var from: LocalDate; var to: LocalDate; var days = 0
    /// Soll of all days of the bucket and of the completed days (through yesterday; the running current day is not included).
    var targetSeconds = 0; var targetToDateSeconds = 0
    /// Ist according to `basis` (without credit), plus the pieces it is made of.
    var actualSeconds = 0; var creditSeconds = 0
    var evaluatedWorkSeconds = 0; var rawWorkSeconds = 0; var roundingSeconds = 0
    /// Differenz = Ist + credit - Soll, summed over the completed days only (through yesterday, basis-dependent).
    var deltaSeconds = 0
    var overtimeSeconds = 0; var undertimeSeconds = 0
    /// Cumulative Zeitkonto balance as of `balanceAsOf` (bucket end, at most today); always the official evaluated balance.
    var balanceSeconds: Int?; var balanceAsOf: LocalDate?
    var kindSeconds = Kinds()
    var absences = Absences(); var absenceDays = 0.0
    var breakSeconds = 0; var breakDeductionSeconds = 0
    var workDays = 0; var provisional = false
    var legalWarningDays = 0
    var breakHintDays = 0
}

struct TimeStatisticsDTO: Encodable, Sendable {
    struct Totals: Encodable, Sendable {
        var targetSeconds = 0, targetToDateSeconds = 0, actualSeconds = 0, creditSeconds = 0, deltaSeconds = 0
        var overtimeSeconds = 0, undertimeSeconds = 0, breakSeconds = 0, breakDeductionSeconds = 0
        var kindSeconds = TimeStatisticsBucket.Kinds(); var absenceDays = 0.0
        var legalWarningDays = 0; var breakHintDays = 0
    }
    var from: LocalDate; var to: LocalDate
    var granularity: String; var basis: String; var timezone: String
    var accountStart: LocalDate?
    /// Zeitkonto balance at the end of the day before `from` (chart baseline); nil before the account starts.
    var openingBalanceSeconds: Int?
    var buckets: [TimeStatisticsBucket]; var totals: Totals
    /// Always false: the running current day is in no `deltaSeconds`, `targetToDateSeconds` or cumulative balance (C3, ADR-0032).
    var includesToday = false
    /// Delta (Ist + credit - Soll, official evaluation) of the running current day; nil when today is outside the range.
    var todayDeltaSeconds: Int?
}

struct StatisticsService: Sendable {
    static let maxDays = 1100
    let scope: TimeServices

    func series(from: LocalDate, to: LocalDate, granularity: StatisticsGranularity, basis: StatisticsBasis,
                now: Date = Date()) async throws -> TimeStatisticsDTO {
        try LocalDate.checkedRange(from: from, to: to, maxDays: Self.maxDays)
        // W4: windowed snapshot after the last month-end checkpoint before `from`; the cumulative balance starts from it.
        let inputs = try await scope.account.balanceInputs(anchor: from, through: to, also: from...to, now: now)
        return try series(from: from, to: to, granularity: granularity, basis: basis, inputs: inputs, now: now)
    }

    /// The series over already loaded inputs; the equivalence tests feed it the complete history without a carry as the oracle.
    func series(from: LocalDate, to: LocalDate, granularity: StatisticsGranularity, basis: StatisticsBasis,
                inputs: BalanceInputs, now: Date) throws -> TimeStatisticsDTO {
        let snapshot = inputs.snapshot, adjustments = inputs.adjustments
        let timezone = snapshot.models.last?.timezone ?? "Europe/Berlin"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone)!
        let today = LocalDate.local(now, calendar: calendar)
        let start = try scope.account.accountStart(snapshot: snapshot, adjustments: adjustments, calendar: calendar)
        let prepared = snapshot.prepared()
        var correctionsByDay: [LocalDate: Int] = [:]
        for row in adjustments where row.kind == "correction" { correctionsByDay[try LocalDate(row.date), default: 0] += row.seconds }
        let opening = adjustments.first { $0.kind == "opening" }?.seconds ?? 0

        // One evaluation pass from the account start (or `from`) to `to`. The cumulative Zeitkonto is the same sum as
        // GET /time/account: opening + corrections + official day deltas, up to and including today.
        var days: [LocalDate: DayEvaluationResult] = [:]
        var cumulative: [LocalDate: Int] = [:]
        var total = opening
        var date = min(start ?? from, from)
        if let carry = inputs.carry, let start, carry.through >= start, carry.through < from {
            // Days up to the checkpoint are folded into one summand (all of them lie before today).
            total += carry.evaluationSeconds + (correctionsByDay.filter { $0.key >= start && $0.key <= carry.through }.values.reduce(0, +))
            cumulative[carry.through] = total
            date = carry.through.addingDays(1)
        }
        while date <= to {
            let day = try prepared.evaluate(date, now: now)
            days[date] = day
            if let start, date >= start {
                // The current day's delta stays out until the day is over; corrections dated today count at once.
                if date < today { total += day.deltaSeconds + (correctionsByDay[date] ?? 0) }
                else if date == today { total += correctionsByDay[date] ?? 0 }
                cumulative[date] = total
            }
            date = date.addingDays(1)
        }
        let baseline = cumulative[from.addingDays(-1)]

        var buckets: [TimeStatisticsBucket] = []
        date = from
        while date <= to {
            let day = days[date]!
            let label = Self.label(date, granularity)
            if buckets.last?.label != label { buckets.append(TimeStatisticsBucket(label: label, from: date, to: date)) }
            let model = snapshot.models.first { $0.validFrom <= date && ($0.validTo.map { date <= $0 } ?? true) }
            let view = scope.weeks.dto(day, model: model, absences: snapshot.absences, plan: nil, today: today, now: now)
            Self.add(&buckets[buckets.count - 1], day: day, view: view, basis: basis, now: now)
            buckets[buckets.count - 1].to = date
            date = date.addingDays(1)
        }
        for index in buckets.indices {
            let asOf = min(buckets[index].to, today)
            buckets[index].balanceAsOf = asOf
            buckets[index].balanceSeconds = cumulative[asOf]
            if cumulative[asOf] == nil { buckets[index].balanceAsOf = nil }
        }
        var totals = TimeStatisticsDTO.Totals()
        for bucket in buckets {
            totals.targetSeconds += bucket.targetSeconds; totals.targetToDateSeconds += bucket.targetToDateSeconds
            totals.actualSeconds += bucket.actualSeconds; totals.creditSeconds += bucket.creditSeconds
            totals.deltaSeconds += bucket.deltaSeconds; totals.overtimeSeconds += bucket.overtimeSeconds
            totals.undertimeSeconds += bucket.undertimeSeconds; totals.breakSeconds += bucket.breakSeconds
            totals.breakDeductionSeconds += bucket.breakDeductionSeconds; totals.absenceDays += bucket.absenceDays
            totals.kindSeconds.work += bucket.kindSeconds.work; totals.kindSeconds.school += bucket.kindSeconds.school
            totals.kindSeconds.travel += bucket.kindSeconds.travel
            totals.legalWarningDays += bucket.legalWarningDays; totals.breakHintDays += bucket.breakHintDays
        }
        return .init(from: from, to: to, granularity: granularity.rawValue, basis: basis.rawValue, timezone: timezone, accountStart: start,
                     openingBalanceSeconds: baseline, buckets: buckets, totals: totals,
                     todayDeltaSeconds: start.flatMap { $0 <= today ? days[today]?.deltaSeconds : nil })
    }

    /// Bucket key: the day itself, the ISO week ("2026-W44") or the calendar month ("2026-10").
    static func label(_ date: LocalDate, _ granularity: StatisticsGranularity) -> String {
        switch granularity {
        case .day: return date.description
        case .month: return String(format: "%04d-%02d", date.year, date.month)
        case .week:
            let thursday = date.addingDays(-(date.isoWeekday - 1) + 3)
            let newYear = (try? LocalDate(year: thursday.year, month: 1, day: 1)) ?? thursday
            return String(format: "%04d-W%02d", thursday.year, newYear.distance(to: thursday) / 7 + 1)
        }
    }

    static func add(_ bucket: inout TimeStatisticsBucket, day: DayEvaluationResult, view: TimeWeekDayDTO, basis: StatisticsBasis, now: Date) {
        // C3: the running current day is neither "past" nor future for the sums; it is reported separately.
        let past = !view.isFuture && !view.isToday
        // Raw basis only removes the rounding of first start / last end; credit, fixed breaks and marks stay.
        let rounding = day.startAdjustSeconds + day.endAdjustSeconds
        let actual = basis == .raw ? day.evaluatedWorkSeconds - rounding : day.evaluatedWorkSeconds
        bucket.days += 1
        bucket.targetSeconds += day.targetSeconds
        bucket.evaluatedWorkSeconds += day.evaluatedWorkSeconds; bucket.rawWorkSeconds += day.rawWorkSeconds
        bucket.roundingSeconds += rounding
        bucket.actualSeconds += actual; bucket.creditSeconds += day.creditSeconds
        bucket.breakSeconds += view.breakSeconds; bucket.breakDeductionSeconds += day.breakDeductionSeconds
        if past {
            let delta = actual + day.creditSeconds - day.targetSeconds
            bucket.targetToDateSeconds += day.targetSeconds
            bucket.deltaSeconds += delta
            bucket.overtimeSeconds += max(0, delta); bucket.undertimeSeconds += max(0, -delta)
        }
        for segment in day.segments {
            let length = max(0, Int((segment.endedAt ?? now).timeIntervalSince(segment.startedAt)))
            switch segment.kind {
            case .work: bucket.kindSeconds.work += length
            case .school: bucket.kindSeconds.school += length
            case .travel: bucket.kindSeconds.travel += length
            }
        }
        let half = view.absences.contains { $0.kind == .vacation && $0.halfDay } ? 0.5 : 1
        switch view.mark {
        case "vacation": bucket.absences.vacation += half
        case "sick": bucket.absences.sick += 1
        case "excused": bucket.absences.excused += 1
        case "holiday": bucket.absences.holiday += 1
        case "school": bucket.absences.school += 1
        default: break
        }
        if view.mark == "vacation" { bucket.absenceDays += half } else if view.mark == "sick" || view.mark == "excused" { bucket.absenceDays += 1 }
        if view.workSeconds > 0 { bucket.workDays += 1 }
        if day.provisional { bucket.provisional = true }
        if !day.legalWarnings.isEmpty { bucket.legalWarningDays += 1 }
        if !day.breakHints.isEmpty { bucket.breakHintDays += 1 }
    }
}
