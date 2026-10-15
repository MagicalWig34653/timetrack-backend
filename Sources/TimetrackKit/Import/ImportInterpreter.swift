import Foundation

struct ImportCandidate: Sendable {
    var row: Int
    var date: LocalDate
    var start: Date
    var end: Date
    var kind: EngineSegmentKind
    var placeId: UUID?
    var note: String?
}

enum ImportRowOutcome: Sendable {
    case blank
    case summary
    case failed(String)
    case candidate(ImportCandidate)
}

private struct RowFailure: Error { let code: String; init(_ code: String) { self.code = code } }

/// Pure interpretation of sheet rows according to a mapping. No database access, no formula evaluation.
struct ImportInterpreter: Sendable {
    let mapping: ImportMapping
    let date1904: Bool
    /// Lower-cased trimmed place name -> id of a non-archived place.
    let places: [String: UUID]

    static let summaryWords = ["summe", "gesamt", "total", "gesamtsumme", "zwischensumme", "übertrag", "saldo", "sum"]

    func interpret(_ rows: [[ImportCell]]) -> [(row: Int, outcome: ImportRowOutcome)] {
        var out: [(Int, ImportRowOutcome)] = []
        for (offset, cells) in rows.enumerated() where offset + 1 > mapping.headerRow {
            let number = offset + 1
            out.append((number, interpretRow(cells)))
        }
        return out
    }

    private func cell(_ cells: [ImportCell], _ index: Int?) -> ImportCell {
        guard let index, cells.indices.contains(index) else { return .empty }
        return cells[index]
    }
    private func isBlank(_ cell: ImportCell) -> Bool {
        switch cell {
        case .empty: return true
        case .text(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    private func interpretRow(_ cells: [ImportCell]) -> ImportRowOutcome {
        if cells.allSatisfy(isBlank) { return .blank }
        let dateCell = cell(cells, mapping.columns.date)
        var summary = isBlank(dateCell)
        if case .text(let text) = dateCell {
            let folded = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if Self.summaryWords.contains(where: { folded == $0 || folded.hasPrefix($0 + " ") || folded.hasPrefix($0 + ":") }) { summary = true }
        }
        if summary { return mapping.skipsSummary ? .summary : .failed("summary_row") }
        do { return .candidate(try candidate(cells, dateCell: dateCell)) }
        catch let failure as RowFailure { return .failed(failure.code) }
        catch { return .failed("time_invalid") }
    }

    private func candidate(_ cells: [ImportCell], dateCell: ImportCell) throws -> ImportCandidate {
        let date = try parseDate(dateCell)
        let startCell = cell(cells, mapping.columns.start), endCell = cell(cells, mapping.columns.end)
        let durationCell = cell(cells, mapping.columns.duration)
        guard !isBlank(startCell) else { throw RowFailure("missing_value") }
        let startSeconds = try parseTime(startCell, duration: false)
        guard startSeconds < 86_400 else { throw RowFailure("time_invalid") }
        let zone = mapping.zone
        guard let start = Self.instant(date, seconds: startSeconds, zone: zone) else { throw RowFailure("time_invalid") }
        let end: Date
        if !isBlank(endCell) {
            let endSeconds = try parseTime(endCell, duration: false)
            var endDate = date
            if endSeconds <= startSeconds {
                // Crossing midnight is only accepted when the mapping says so explicitly; never guessed.
                guard mapping.allowOvernight == true, endSeconds < startSeconds else { throw RowFailure("end_before_start") }
                endDate = try Self.nextDay(date)
            }
            guard let value = Self.instant(endDate, seconds: endSeconds, zone: zone) else { throw RowFailure("time_invalid") }
            end = value
        } else if mapping.columns.duration != nil, !isBlank(durationCell) {
            let seconds = try parseTime(durationCell, duration: true)
            guard seconds > 0 else { throw RowFailure("end_before_start") }
            end = start.addingTimeInterval(TimeInterval(seconds))
        } else { throw RowFailure("missing_value") }
        guard end > start else { throw RowFailure("end_before_start") }

        var kind = mapping.defaultKind ?? .work
        let kindCell = cell(cells, mapping.columns.kind)
        if mapping.columns.kind != nil, !isBlank(kindCell) {
            if case .formulaWithoutValue = kindCell { throw RowFailure("formula_without_value") }
            guard let parsed = Self.kind(try text(kindCell)) else { throw RowFailure("unknown_kind") }
            kind = parsed
        }
        var placeId: UUID?
        let placeCell = cell(cells, mapping.columns.place)
        if mapping.columns.place != nil, !isBlank(placeCell) {
            let name = try text(placeCell).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let id = places[name] else { throw RowFailure("unknown_place") }
            placeId = id
        }
        var note: String?
        let noteCell = cell(cells, mapping.columns.note)
        if mapping.columns.note != nil, !isBlank(noteCell) {
            // Stored verbatim as text: a leading "=" is never interpreted.
            let value = try text(noteCell).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{0}", with: "")
            guard value.unicodeScalars.count <= ImportLimits.maxNoteScalars else { throw RowFailure("note_too_long") }
            note = value.isEmpty ? nil : value
        }
        return .init(row: 0, date: date, start: start, end: end, kind: kind, placeId: placeId, note: note)
    }

    private func text(_ cell: ImportCell) throws -> String {
        switch cell {
        case .text(let text): return text
        case .number(let raw, _): return raw
        case .bool(let value): return value ? "TRUE" : "FALSE"
        case .formulaWithoutValue: throw RowFailure("formula_without_value")
        case .empty: return ""
        }
    }

    static func kind(_ text: String) -> EngineSegmentKind? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "work", "arbeit", "arbeitszeit", "betrieb": return .work
        case "travel", "fahrt", "fahrtzeit", "reise", "reisezeit", "anfahrt": return .travel
        case "school", "schule", "berufsschule", "unterricht": return .school
        default: return nil
        }
    }

    // MARK: Dates

    private func parseDate(_ cell: ImportCell) throws -> LocalDate {
        switch cell {
        case .formulaWithoutValue: throw RowFailure("formula_without_value")
        case .empty, .bool: throw RowFailure("date_invalid")
        case .number(let raw, let style):
            // A date-formatted cell is a serial regardless of the declared text format.
            guard style == .date || style == .dateTime || mapping.dateFormat == .excelSerial else { throw RowFailure("date_invalid") }
            return try Self.date(serial: raw, date1904: date1904)
        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch mapping.dateFormat {
            case .excelSerial: return try Self.date(serial: trimmed, date1904: date1904)
            case .ddMMyyyy:
                let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count == 3, (1...2).contains(parts[0].count), (1...2).contains(parts[1].count), parts[2].count == 4,
                      let day = Self.digits(parts[0]), let month = Self.digits(parts[1]), let year = Self.digits(parts[2]),
                      let date = try? LocalDate(year: year, month: month, day: day) else { throw RowFailure("date_invalid") }
                return date
            case .yyyyMMdd:
                guard let date = try? LocalDate(trimmed) else { throw RowFailure("date_invalid") }
                return date
            }
        }
    }

    static func digits(_ text: Substring) -> Int? {
        text.utf8.allSatisfy { (48...57).contains($0) } ? Int(text) : nil
    }

    /// Excel serial -> calendar date. The 1900 system counts the non-existent 29 February 1900 (serial 60),
    /// which is therefore rejected; serials before it are shifted by one day.
    static func date(serial raw: String, date1904: Bool) throws -> LocalDate {
        guard let value = decimal(raw), value >= 0, value < 2_958_466 else { throw RowFailure("date_invalid") }
        let whole = Int(NSDecimalNumber(decimal: value).doubleValue.rounded(.down))
        let epochDays: Int
        if date1904 { epochDays = whole - 24_107 }
        else {
            guard whole >= 1, whole != 60 else { throw RowFailure("date_invalid") }
            epochDays = whole < 60 ? whole - 25_568 : whole - 25_569
        }
        let (year, month, day) = civil(fromEpochDays: epochDays)
        guard let date = try? LocalDate(year: year, month: month, day: day) else { throw RowFailure("date_invalid") }
        return date
    }

    static func civil(fromEpochDays days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
    static func epochDays(_ date: LocalDate) -> Int {
        let y = date.month <= 2 ? date.year - 1 : date.year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (date.month > 2 ? date.month - 3 : date.month + 9) + 2) / 5 + date.day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
    static func nextDay(_ date: LocalDate) throws -> LocalDate {
        let (year, month, day) = civil(fromEpochDays: epochDays(date) + 1)
        guard let next = try? LocalDate(year: year, month: month, day: day) else { throw RowFailure("date_invalid") }
        return next
    }

    // MARK: Times

    /// Seconds since midnight (time of day, 0...86400) or an elapsed duration (0...86400).
    private func parseTime(_ cell: ImportCell, duration: Bool) throws -> Int {
        switch cell {
        case .formulaWithoutValue: throw RowFailure("formula_without_value")
        case .empty, .bool: throw RowFailure("time_invalid")
        case .number(let raw, let style):
            guard let value = Self.decimal(raw), value >= 0 else { throw RowFailure("time_invalid") }
            if style == .time || style == .dateTime || style == .date {
                // Time-formatted cells carry the time as day fraction; a date part is ignored for times of day.
                return try Self.seconds(fraction: value, duration: duration, dateTime: style != .time)
            }
            switch mapping.timeFormat {
            case .excelFraction: return try Self.seconds(fraction: value, duration: duration, dateTime: false)
            case .decimalHours: return try Self.seconds(decimalHours: value)
            case .hhmm: throw RowFailure("time_invalid")
            }
        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch mapping.timeFormat {
            case .hhmm: return try Self.seconds(clock: trimmed)
            case .decimalHours:
                guard let number = Self.decimal(trimmed) else { throw RowFailure("time_invalid") }
                return try Self.seconds(decimalHours: number)
            case .excelFraction:
                guard let number = Self.decimal(trimmed) else { throw RowFailure("time_invalid") }
                return try Self.seconds(fraction: number, duration: duration, dateTime: false)
            }
        }
    }

    static func seconds(clock text: String) throws -> Int {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), (1...2).contains(parts[0].count), parts[1].count == 2,
              let hour = digits(parts[0]), let minute = digits(parts[1]), minute < 60 else { throw RowFailure("time_invalid") }
        var second = 0
        if parts.count == 3 {
            guard parts[2].count == 2, let value = digits(parts[2]), value < 60 else { throw RowFailure("time_invalid") }
            second = value
        }
        let total = hour * 3600 + minute * 60 + second
        guard total <= 86_400 else { throw RowFailure("time_invalid") }
        return total
    }

    /// 7,7 h is 7 h 42 min (27 720 s), never 7:07.
    static func seconds(decimalHours value: Decimal) throws -> Int {
        guard value >= 0, value <= 24 else { throw RowFailure("time_invalid") }
        return try rounded(value * 3600)
    }

    static func seconds(fraction value: Decimal, duration: Bool, dateTime: Bool) throws -> Int {
        guard value >= 0 else { throw RowFailure("time_invalid") }
        if value > 1 && !duration && dateTime {
            // A date-time serial: only the time of day counts.
            let whole = try rounded(value * 86_400)
            return whole % 86_400
        }
        guard value <= 1 else { throw RowFailure("time_invalid") }
        return try rounded(value * 86_400)
    }

    private static func rounded(_ value: Decimal) throws -> Int {
        var input = value, output = Decimal()
        NSDecimalRound(&output, &input, 0, .plain)
        guard let result = Int(exactly: NSDecimalNumber(decimal: output).doubleValue) else { throw RowFailure("time_invalid") }
        return result
    }

    /// Accepts "7,7", "7.7", "1.234,5" and "1,234.5"; scientific notation only with a dot. Rejects anything else.
    static func decimal(_ text: String) -> Decimal? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        let hasComma = trimmed.contains(","), hasDot = trimmed.contains(".")
        if hasComma && hasDot {
            let decimalSeparator: Character = trimmed.lastIndex(of: ",")! > trimmed.lastIndex(of: ".")! ? "," : "."
            let thousands: Character = decimalSeparator == "," ? "." : ","
            guard trimmed.filter({ $0 == decimalSeparator }).count == 1 else { return nil }
            trimmed = trimmed.replacingOccurrences(of: String(thousands), with: "")
        }
        trimmed = trimmed.replacingOccurrences(of: ",", with: ".")
        var sawDigit = false, sawDot = false, sawExponent = false
        for (offset, character) in trimmed.enumerated() {
            switch character {
            case "0"..."9": sawDigit = true
            case ".": guard !sawDot, !sawExponent else { return nil }; sawDot = true
            case "e", "E": guard sawDigit, !sawExponent else { return nil }; sawExponent = true
            case "+", "-":
                let previous = trimmed[trimmed.index(trimmed.startIndex, offsetBy: max(offset - 1, 0))]
                guard offset == 0 || previous == "e" || previous == "E" else { return nil }
            default: return nil
            }
        }
        guard sawDigit else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: Time zones

    /// Local wall-clock time -> instant. Nonexistent times (spring-forward gap) yield nil; for ambiguous
    /// times (fall-back overlap) the first occurrence is used. 86400 means midnight of the next day.
    static func instant(_ date: LocalDate, seconds: Int, zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var day = date, secondsOfDay = seconds
        if seconds >= 86_400 {
            guard seconds == 86_400, let next = try? nextDay(date) else { return nil }
            day = next; secondsOfDay = 0
        }
        let components = DateComponents(year: day.year, month: day.month, day: day.day,
                                        hour: secondsOfDay / 3600, minute: secondsOfDay % 3600 / 60, second: secondsOfDay % 60)
        guard let result = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: result)
        guard back.year == components.year, back.month == components.month, back.day == components.day,
              back.hour == components.hour, back.minute == components.minute, back.second == components.second else { return nil }
        return result
    }

    // MARK: Display (raw preview)

    static func display(_ cell: ImportCell, date1904: Bool) -> String? {
        switch cell {
        case .empty, .formulaWithoutValue: return nil
        case .text(let value): return value
        case .bool(let value): return value ? "TRUE" : "FALSE"
        case .number(let raw, let style):
            guard style != .plain, let value = decimal(raw), value >= 0 else { return raw }
            var parts: [String] = []
            if style == .date || style == .dateTime, let date = try? date(serial: raw, date1904: date1904) { parts.append(date.description) }
            if style == .time || style == .dateTime {
                let day = Double(truncating: NSDecimalNumber(decimal: value))
                let fraction = day - day.rounded(.down)
                guard let rounded = Int(exactly: (fraction * 86_400).rounded()) else { return raw }
                let total = rounded % 86_400
                parts.append(String(format: "%02d:%02d", total / 3600, total % 3600 / 60) + (total % 60 != 0 ? String(format: ":%02d", total % 60) : ""))
            }
            return parts.isEmpty ? raw : parts.joined(separator: " ")
        }
    }
}
