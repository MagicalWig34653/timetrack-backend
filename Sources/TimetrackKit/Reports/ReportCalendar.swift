import Foundation

/// ISO 8601 weeks (Monday to Sunday, week 1 contains January 4th) and the plain-text rendering of ADR-0008.
/// The week arithmetic is done on `LocalDate` so that it does not depend on platform calendar quirks;
/// the tests compare it with `Calendar` (firstWeekday Monday, minimumDaysInFirstWeek 4).
enum ReportCalendar {
    struct Week: Equatable, Sendable {
        let year: Int
        let week: Int
        let start: LocalDate
        let end: LocalDate
        var days: [LocalDate] { (0..<7).map { start.addingDays($0) } }
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 1 = Monday ... 7 = Sunday.
    static func isoWeekday(_ date: LocalDate) -> Int {
        let day = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))!
        return (calendar.component(.weekday, from: day) + 5) % 7 + 1
    }

    /// Throws `bad_request` for an unknown year/week, including week 53 in a year that has only 52 weeks.
    static func week(year: Int, week: Int) throws -> Week {
        guard (ReportLimits.minYear...ReportLimits.maxYear).contains(year), (1...53).contains(week) else { throw APIError.invalid }
        let january4 = try LocalDate(year: year, month: 1, day: 4)
        let firstMonday = january4.addingDays(-(isoWeekday(january4) - 1))
        let monday = firstMonday.addingDays(7 * (week - 1))
        // A week belongs to the year that contains its Thursday.
        guard monday.addingDays(3).year == year else { throw APIError.invalid }
        return Week(year: year, week: week, start: monday, end: monday.addingDays(6))
    }
}

enum ReportText {
    private static let weekdays = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]

    static func germanDate(_ date: LocalDate) -> String { String(format: "%02d.%02d.%04d", date.day, date.month, date.year) }

    /// `h:mm` without leading zero for hours; minutes are truncated.
    static func duration(_ seconds: Int) -> String {
        let minutes = max(seconds, 0) / 60
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    /// Line breaks (LF, CR, CRLF, NEL, LS, PS) become " / "; empty lines and surrounding blanks are dropped.
    static func singleLine(_ text: String) -> String {
        let separators: Set<Character> = ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"]
        var lines: [String] = []; var current = ""
        for character in text {
            if separators.contains(character) { lines.append(current); current = "" } else { current.append(character) }
        }
        lines.append(current)
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " / ")
    }

    /// Standard output profile: header, one block per day with entries, final sum line. Plain text, no markup.
    static func render(week: ReportCalendar.Week, entries: [ReportEntryRecord]) -> String {
        var lines = ["Berichtsheft KW \(week.week)/\(week.year) (\(germanDate(week.start)) – \(germanDate(week.end)))", ""]
        for day in week.days {
            let dayEntries = entries.filter { $0.date == day.description }
            guard !dayEntries.isEmpty else { continue }
            lines.append("\(weekdays[ReportCalendar.isoWeekday(day) - 1]), \(germanDate(day))")
            for entry in dayEntries {
                var line = "\(singleLine(entry.learningFieldName)) | \(duration(entry.durationSeconds)) h"
                let note = singleLine(entry.notes)
                if !note.isEmpty { line += " | " + note }
                lines.append(line)
            }
            lines.append("")
        }
        lines.append("Summe: \(duration(entries.reduce(0) { $0 + $1.durationSeconds })) h")
        return lines.joined(separator: "\n") + "\n"
    }
}
