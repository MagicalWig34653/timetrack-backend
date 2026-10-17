import Foundation
import Fluent

struct WorktimeExportOptions: Sendable {
    var actual = false
    var pauseMinutes: Int?
    var standardStart = 8 * 3600
    var date1904 = false

    init(times: String? = nil, pauseMinutes: String? = nil, standardStart: String? = nil, dateSystem: String? = nil) throws {
        guard times == nil || ["evaluated", "actual"].contains(times!),
              dateSystem == nil || ["1900", "1904"].contains(dateSystem!) else { throw APIError.invalid }
        actual = times == "actual"; date1904 = dateSystem == "1904"
        if let pauseMinutes {
            guard !pauseMinutes.isEmpty, pauseMinutes.utf8.allSatisfy({ (48...57).contains($0) }),
                  let minutes = Int(pauseMinutes), (0...240).contains(minutes) else { throw APIError.invalid }
            self.pauseMinutes = minutes
        }
        if let standardStart {
            let bytes = Array(standardStart.utf8)
            guard bytes.count == 5, bytes[2] == 58,
                  [bytes[0], bytes[1], bytes[3], bytes[4]].allSatisfy({ (48...57).contains($0) }),
                  let hour = Int(standardStart.prefix(2)), hour < 24,
                  let minute = Int(standardStart.suffix(2)), minute < 60 else { throw APIError.invalid }
            self.standardStart = hour * 3600 + minute * 60
        }
    }
}

struct WorktimeExportService: Sendable {
    let scope: TimeServices

    func document(from: LocalDate, to: LocalDate, options: WorktimeExportOptions, now: Date = Date()) async throws -> FormulaXLSXWriter.Document {
        try LocalDate.checkedRange(from: from, to: to, maxDays: ExportLimits.maxDays)
        let snapshot = try await scope.days.snapshot(window: from...to)
        let prepared = snapshot.prepared()
        var days: [DayEvaluationResult] = []
        var date = from
        while date <= to { days.append(try prepared.evaluate(date, now: now)); date = date.addingDays(1) }
        // Absence notes are not carried by the engine. Read only the owner's notes and only with planning enabled.
        let absences = snapshot.planningEnabled ? try await scope.absences.list(from: from, to: to) : []
        var notes: [LocalDate: String] = [:]
        for day in days {
            if day.markSource == .absence, let absence = absences.first(where: {
                $0.startDate <= day.date && day.date <= $0.endDate && $0.status.isBooked
            }), let note = absence.note { notes[day.date] = note }
            if day.markSource == .holiday, let custom = snapshot.customDays.first(where: {
                $0.kind == .holiday && $0.startDate <= day.date && day.date <= $0.endDate
            }) { notes[day.date] = custom.name }
        }
        return try Self.build(from: from, to: to, days: days, models: snapshot.models, notes: notes, options: options)
    }

    static func week(_ date: LocalDate) -> (year: Int, number: Int) {
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = .gmt
        let instant = ImportInterpreter.instant(date, seconds: 43200, zone: .gmt)!
        return (calendar.component(.yearForWeekOfYear, from: instant), calendar.component(.weekOfYear, from: instant))
    }
    static func monday(_ date: LocalDate) -> LocalDate { date.addingDays(-ExportFormat.weekdayIndex(date)) }

    static func build(from: LocalDate, to: LocalDate, days: [DayEvaluationResult], models: [EngineWorkModel],
                      notes: [LocalDate: String] = [:], options: WorktimeExportOptions) throws -> FormulaXLSXWriter.Document {
        let model = try TimeEngine.selectModel(for: to, models: models)
        let weekly = model?.weeklyTargetSeconds ?? 0
        let daily = Double(weekly) / 5
        let pause = options.pauseMinutes.map { $0 * 60 } ?? model.map {
            $0.fixedBreaks.reduce(0) { $0 + (($1.end.minutes - $1.start.minutes + 1440) % 1440) * 60 }
        } ?? 1800
        let indexed = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })
        // Include a boundary owner sheet when the ISO week-year lies outside the requested calendar years.
        let years = Set(from.year...to.year).union(days.map { week($0.date).year }).sorted()
        var sheets: [FormulaXLSXWriter.Sheet] = []
        var cumulative = 0
        for (index, year) in years.enumerated() {
            var sheet = FormulaXLSXWriter.Sheet(name: String(year))
            sheet.set(1, 0, .text("Wochenarbeitszeit", bold: true)); sheet.set(1, 1, .seconds(weekly, style: .boldDuration))
            sheet.set(1, 3, .text("Tägl. Arbeitszeit", bold: true)); sheet.set(1, 4, .init(value: .number(daily / 86400), style: .boldDuration, formula: "B1/5"))
            sheet.set(1, 6, .text("Pause", bold: true)); sheet.set(1, 7, .seconds(pause, style: .boldDuration))
            sheet.set(2, 0, .text("Summe", bold: true))
            let first = index == 0 ? monday(from) : monday(try LocalDate(year: year, month: 1, day: 1))
            let last = monday(try LocalDate(year: year, month: 12, day: 31))
            var start = first, row = 6, balance = 0
            while start <= last {
                let iso = week(start)
                let label = String(format: "KW%02d", iso.number) + (iso.year == year ? "" : " - \(iso.year)")
                for (column, text) in [label, "Beginn", "Ende", "Stunden", "Differenz", "Bemerkung"].enumerated() {
                    sheet.set(row, column, .text(text, bold: true))
                }
                var weekSeconds = 0
                for offset in 0..<7 {
                    let date = start.addingDays(offset), r = row + offset + 1
                    sheet.set(r, 0, .init(value: .number(Double(FormulaXLSXWriter.serial(date, date1904: options.date1904))), style: .date))
                    guard date >= from, date <= to, week(date).year == year, let day = indexed[date] else { continue }
                    let dayModel = try TimeEngine.selectModel(for: date, models: models)
                    let values = dayCells(day, model: dayModel, templateTarget: daily, pause: pause, row: r,
                                          note: notes[date], options: options)
                    for (column, value) in values.cells { sheet.set(r, column, value) }
                    balance += values.delta
                    if offset < 5 { weekSeconds += values.work }
                }
                sheet.set(row, 6, .init(value: .number(Double(weekSeconds) / 3600), style: .boldDecimal,
                                       formula: "SUM(D\(row + 1):D\(row + 5))*24"))
                sheet.rows[row + 8] = [:]
                row += 9; start = start.addingDays(7)
            }
            cumulative += balance
            let previous = index > 0 ? "+'\(years[index - 1])'!B2" : ""
            sheet.set(2, 1, .seconds(cumulative, style: .boldBalance, formula: "SUM(E7:E\(row - 2))" + previous))
            sheets.append(sheet)
        }
        return .init(sheets: sheets, date1904: options.date1904)
    }

    struct DayCells {
        var cells: [Int: FormulaXLSXWriter.Cell] = [:]
        var work = 0
        var delta = 0
    }
    static func dayCells(_ day: DayEvaluationResult, model: EngineWorkModel?, templateTarget: Double, pause: Int,
                         row: Int, note: String? = nil, options: WorktimeExportOptions) -> DayCells {
        var result = DayCells()
        let baseTarget = model.map { TimeEngine.target(for: day.date, model: $0) } ?? 0
        let schoolCredit = day.creditSeconds > 0 && (day.mark == .schoolCredit || day.segments.contains { $0.kind == .school })
        let credited = (day.mark != .none || schoolCredit) && baseTarget > 0
        var remarks: [String] = []
        var warnings: [String] = []
        let label: String? = switch day.mark {
        case .vacation: "Urlaub"
        case .sick: "Krank"
        case .excused: "Freigestellt"
        case .holiday: "Feiertag"
        case .schoolCredit: "Berufsschule"
        case .none: schoolCredit || day.segments.contains(where: { $0.kind == .school }) ? "Berufsschule" : nil
        }
        if let label { remarks.append(label) }
        for text in [note, day.note] + day.segments.map(\.note) {
            if var text, !text.isEmpty {
                if let label, text.hasPrefix(label + "; ") { text = String(text.dropFirst(label.count + 2)) }
                if !remarks.contains(text) { remarks.append(text) }
            }
        }
        let running = day.segments.contains { $0.endedAt == nil }
        var start: Int?, end: Int?
        var work = day.evaluatedWorkSeconds + day.creditSeconds
        let delta = day.deltaSeconds
        if (credited && day.segments.isEmpty) || schoolCredit {
            let creditTarget = day.mark == .vacation && day.targetOverrideSeconds != nil ? baseTarget / 2 : baseTarget
            start = options.standardStart; end = options.standardStart + creditTarget + pause
            work = creditTarget
        } else {
            let calendar = model?.calendar ?? { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Berlin")!; return c }()
            func clock(_ instant: Date) -> Int {
                let local = LocalDate.local(instant, calendar: calendar)
                let parts = calendar.dateComponents([.hour, .minute, .second], from: instant)
                return day.date.distance(to: local) * 86400 + (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
            }
            if options.actual {
                start = day.segments.map(\.rawStartedAt).min().map(clock)
                if !running { end = day.segments.compactMap { $0.rawEndedAt ?? $0.endedAt }.max().map(clock) }
            } else {
                start = day.evaluatedStart.map(clock)
                if !running { end = day.evaluatedEnd.map(clock) }
            }
        }
        if let start { result.cells[1] = .seconds(start, style: .time) }
        if let end { result.cells[2] = .seconds(end, style: .time) }
        if let start, let end {
            let consistentWork = end - start - pause == work
            result.cells[3] = .seconds(work, formula: consistentWork ? "C\(row)-B\(row)-$H$1" : nil)
            if !consistentWork { warnings.append("Pause abweichend") }
            let consistentTarget = Double(work) - templateTarget == Double(delta)
            result.cells[4] = .seconds(delta, style: .balance, formula: consistentTarget ? "D\(row)-$E$1" : nil)
            if !consistentTarget { warnings.append("Soll abweichend") }
            result.work = work
        } else if delta != 0 {
            // Empty contractual workdays still contribute their deficit to the period balance.
            result.cells[4] = .seconds(delta, style: .balance)
        }
        result.delta = delta
        let suffix = warnings.joined(separator: "; ")
        let allowance = max(0, 100 - suffix.count - (suffix.isEmpty || remarks.isEmpty ? 0 : 2))
        var remark = String(remarks.joined(separator: "; ").prefix(allowance))
        if !suffix.isEmpty { remark += (remark.isEmpty ? "" : "; ") + suffix }
        if !remark.isEmpty { result.cells[5] = .text(remark) }
        return result
    }
}
