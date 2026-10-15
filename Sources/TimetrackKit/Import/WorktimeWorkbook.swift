import Foundation

enum WorktimeAction: String, Codable, Sendable, CaseIterable {
    case work, school, vacation, sick, excused, holiday, skip
    var isAbsence: Bool { [.vacation, .sick, .excused].contains(self) }
}
struct WorktimeRemarkRule: Codable, Sendable, Equatable {
    var pattern: String
    var action: WorktimeAction
    static let defaults: [Self] = [
        .init(pattern: "krank", action: .sick), .init(pattern: "freigestellt", action: .excused),
        .init(pattern: "urlaub", action: .vacation), .init(pattern: "feiertag", action: .holiday),
        .init(pattern: "berufsschule", action: .school), .init(pattern: "^bs$", action: .school)
    ]
    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
    func matches(_ text: String) -> Bool {
        let pattern = Self.normalize(pattern), text = Self.normalize(text)
        // Deliberately no regular expression engine: anchors only select literal equality.
        if pattern.hasPrefix("^"), pattern.hasSuffix("$") { return text == String(pattern.dropFirst().dropLast()) }
        return text.contains(pattern)
    }
}
struct WorktimeOptions: Codable, Sendable, Equatable {
    var pauseMode: String? = nil
    var pauseMinutes: Int? = nil
    var pauseStart: String? = nil
    var roundToMinutes: Bool? = nil
    var holidayTimes: String? = nil
    var partialCredit: String? = nil
    var rules: [WorktimeRemarkRule]? = nil
    var effectiveRules: [WorktimeRemarkRule] { rules ?? WorktimeRemarkRule.defaults }
    func validate() throws {
        guard pauseMode == nil || ["split", "none"].contains(pauseMode!),
              holidayTimes == nil || ["discard", "keep"].contains(holidayTimes!),
              partialCredit == nil || ["work", "absence"].contains(partialCredit!),
              pauseMinutes.map({ (0...240).contains($0) }) ?? true,
              rules.map({ $0.count <= 100 && $0.allSatisfy { !$0.pattern.isEmpty && $0.pattern.fitsColumn(80) } }) ?? true else { throw APIError.invalid }
        if let pauseStart {
            guard pauseStart.count == 5, let seconds = try? ImportInterpreter.seconds(clock: pauseStart), seconds < 86400 else { throw APIError.invalid }
        }
    }
}
struct WorktimePreview: Codable, Sendable {
    struct Remark: Codable, Sendable { var text: String; var count: Int }
    var days = 0
    var segments = 0
    var absences = 0
    var customDays = 0
    var skippedHolidays = 0
    var firstDate: String?
    var lastDate: String?
    var dateSystem: String
    var sheetBalanceSeconds: Int?
    var sheetBalanceUpToTodaySeconds: Int?
    var sheetBalanceFutureSeconds: Int?
    var firstContentDate: String?
    var unmappedRemarks: [Remark] = []
    var byAction: [String: Int] = [:]
}
struct WorktimeDay: Sendable, Equatable {
    var row: Int
    var date: LocalDate
    var start: Int?
    var end: Int?
    var remark: String
    var pause: Int
    func identical(to other: Self) -> Bool {
        date == other.date && start == other.start && end == other.end && remark == other.remark && pause == other.pause
    }
}
struct WorktimeParsed: Sendable {
    var days: [WorktimeDay]
    var errors: [ImportRowError]
    var date1904: Bool
    var balance: Int?
    var balanceRows: [(date: LocalDate, seconds: Double)]
    var dailyTargetSeconds: Int?
    var firstContentDate: LocalDate?
}

enum WorktimeWorkbook {
    static func cell(_ row: [ImportCell], _ column: Int) -> ImportCell { row.indices.contains(column) ? row[column] : .empty }
    static func text(_ cell: ImportCell) -> String {
        if case .text(let text) = cell { return text }; return ""
    }
    static func weekLabel(_ cell: ImportCell) -> Bool {
        let label = text(cell).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard label.hasPrefix("KW") else { return false }
        let digits = label.dropFirst(2).prefix(while: { $0.isNumber })
        return !digits.isEmpty && Int(digits).map { (1...53).contains($0) } == true
    }
    static func date(_ cell: ImportCell, system: Bool) -> LocalDate? {
        guard case .number(let raw, _) = cell else { return nil }
        return try? ImportInterpreter.date(serial: raw, date1904: system)
    }
    static func detects(_ workbook: ImportWorkbook) throws -> Bool {
        guard workbook.kind == "xlsx" else { return false }
        for name in workbook.sheetNames {
            let sheet = try workbook.sheet(name)
            if let first = sheet.rows.first, WorktimeRemarkRule.normalize(text(cell(first, 0))) == "wochenarbeitszeit" { return true }
            for i in sheet.rows.indices where weekLabel(cell(sheet.rows[i], 0)) {
                if sheet.rows.indices.contains(i + 1), date(cell(sheet.rows[i + 1], 0), system: sheet.date1904) != nil { return true }
            }
        }
        return false
    }
    static func seconds(_ cell: ImportCell, roundMinutes: Bool) throws -> Int? {
        if cell == .empty { return nil }
        guard case .number(let raw, _) = cell, let decimal = ImportInterpreter.decimal(raw) else { throw APIError.invalid }
        let seconds = try ImportInterpreter.seconds(fraction: decimal, duration: false, dateTime: false)
        return roundMinutes ? Int((Double(seconds) / 60).rounded()) * 60 : seconds
    }
    static func parse(_ workbook: ImportWorkbook, options: WorktimeOptions) throws -> WorktimeParsed {
        guard workbook.kind == "xlsx" else { throw APIError.invalid }
        var days: [LocalDate: WorktimeDay] = [:], conflicts = Set<LocalDate>()
        var errors: [ImportRowError] = [], offset = 0, system = false, balance = 0.0, hasBalance = false
        var balanceRows: [(date: LocalDate, seconds: Double)] = []
        var dailyTargetSeconds: Int?
        var firstContentDate: LocalDate?
        for name in workbook.sheetNames {
            let sheet = try workbook.sheet(name); system = sheet.date1904
            let pauseCell = sheet.rows.first.map { cell($0, 7) } ?? .empty
            let pause = options.pauseMinutes.map { $0 * 60 } ?? ((try? seconds(pauseCell, roundMinutes: true)) ?? 0)
            if dailyTargetSeconds == nil, let first = sheet.rows.first,
               case .number(let raw, _) = cell(first, 1), let weekly = Double(raw), weekly.isFinite, weekly >= 0 {
                dailyTargetSeconds = Int((weekly * 86400 / 5).rounded())
            }
            guard (0...14400).contains(pause) else { throw APIError.invalid }
            var remaining = 0
            for (index, row) in sheet.rows.enumerated() {
                let number = offset + index + 1
                if weekLabel(cell(row, 0)) { remaining = 7; continue }
                guard remaining > 0 else { continue }
                remaining -= 1
                guard let date = date(cell(row, 0), system: system) else {
                    errors.append(.init(row: number, code: "date_invalid")); continue
                }
                if cell(row, 1) != .empty || cell(row, 2) != .empty || cell(row, 5) != .empty {
                    firstContentDate = min(firstContentDate ?? date, date)
                }
                if case .number(let raw, _) = cell(row, 4), let value = Double(raw), value.isFinite, abs(value) < 1e6 {
                    balance += value * 86400; hasBalance = true
                    balanceRows.append((date, value * 86400))
                }
                if cell(row, 5) == .formulaWithoutValue {
                    errors.append(.init(row: number, code: "formula_without_value")); conflicts.insert(date); continue
                }
                let remark = text(cell(row, 5))
                if cell(row, 1) == .empty && cell(row, 2) == .empty && remark.isEmpty { continue }
                guard remark.unicodeScalars.count <= ImportLimits.maxNoteScalars else {
                    errors.append(.init(row: number, code: "note_too_long")); conflicts.insert(date); continue
                }
                do {
                    let day = WorktimeDay(row: number, date: date,
                        start: try seconds(cell(row, 1), roundMinutes: options.roundToMinutes ?? true),
                        end: try seconds(cell(row, 2), roundMinutes: options.roundToMinutes ?? true), remark: remark, pause: pause)
                    if let existing = days[date], !existing.identical(to: day) {
                        conflicts.insert(date); errors.append(.init(row: number, code: "duplicate_date_conflict"))
                    } else { days[date] = day }
                } catch {
                    errors.append(.init(row: number, code: cell(row, 1) == .formulaWithoutValue || cell(row, 2) == .formulaWithoutValue ? "formula_without_value" : "time_invalid"))
                    conflicts.insert(date)
                }
            }
            offset += sheet.rows.count
            guard offset <= ImportLimits.maxRows else { throw ImportErrors.tooManyRows }
        }
        return .init(days: days.values.filter { !conflicts.contains($0.date) }.sorted { $0.date < $1.date }, errors: errors,
                     date1904: system, balance: hasBalance ? Int(balance.rounded()) : nil,
                     balanceRows: balanceRows, dailyTargetSeconds: dailyTargetSeconds, firstContentDate: firstContentDate)
    }
    static func segments(_ day: WorktimeDay, action: WorktimeAction, mapping: ImportMapping) throws -> ([ImportCandidate], Bool) {
        guard let start = day.start, let end = day.end else { throw APIError(.badRequest, "missing_value") }
        guard end > start, start < 86400 else { throw APIError(.badRequest, "end_before_start") }
        var intervals = [(start, end)]
        let split = mapping.worktime?.pauseMode != "none" && day.pause > 0
        let warning = split && end - start <= day.pause
        if split && !warning {
            let desired = try ImportInterpreter.seconds(clock: mapping.worktime?.pauseStart ?? "12:00")
            let pauseStart = desired > start && desired + day.pause < end ? desired : start + (end - start - day.pause) / 2
            intervals = [(start, pauseStart), (pauseStart + day.pause, end)].filter { $0.1 > $0.0 }
        }
        return (try intervals.map { a, b in
            guard let from = ImportInterpreter.instant(day.date, seconds: a, zone: mapping.zone),
                  let to = ImportInterpreter.instant(day.date, seconds: b, zone: mapping.zone) else { throw APIError(.badRequest, "time_invalid") }
            return ImportCandidate(row: day.row, date: day.date, start: from, end: to, kind: action == .school ? .school : .work,
                                   note: day.remark.isEmpty ? nil : day.remark)
        }, warning)
    }
}
