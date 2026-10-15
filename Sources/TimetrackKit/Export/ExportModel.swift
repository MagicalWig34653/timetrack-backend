import Foundation

/// One table cell of an export. `text` is untrusted (user input) and gets formula-injection protection per ADR-0006;
/// all other kinds are produced by the exporter itself and are rendered from typed values.
enum ExportCell: Equatable, Sendable {
    case empty
    case text(String)
    case date(LocalDate)
    /// Seconds since local midnight.
    case time(Int)
    /// Unsigned duration in seconds.
    case duration(Int)
    /// Signed duration in seconds, rendered with an explicit sign.
    case signed(Int)
}

enum ExportAlignment: Sendable { case left, right }

struct ExportColumn: Sendable {
    let title: String
    let alignment: ExportAlignment
    /// Relative width (PDF share and XLSX character width).
    let weight: Double
}

struct ExportGroup: Sendable {
    let title: String
    let first: Int
    let last: Int
}

/// Format independent description of the time sheet.
struct ExportDocument: Sendable {
    var title = "Zeitnachweis"
    var accountName: String
    var from: LocalDate
    var to: LocalDate
    var createdAt: Date
    var columns: [ExportColumn]
    var groups: [ExportGroup]
    var rows: [[ExportCell]]
    var totals: [ExportCell]

    var periodText: String { "\(ExportFormat.date(from)) bis \(ExportFormat.date(to))" }
    var createdText: String { "Erstellt am \(ExportFormat.timestamp(createdAt))" }
}

enum ExportFormat {
    static let weekdays = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]

    static func date(_ value: LocalDate) -> String { String(format: "%02d.%02d.%04d", value.day, value.month, value.year) }
    static func time(_ seconds: Int) -> String {
        let minutes = ((seconds % 86_400) + 86_400) % 86_400 / 60
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
    static func duration(_ seconds: Int) -> String {
        let minutes = seconds.magnitude / 60
        return (seconds < 0 ? "-" : "") + "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }
    static func signed(_ seconds: Int) -> String {
        let minutes = seconds.magnitude / 60
        return (minutes == 0 ? "" : seconds < 0 ? "-" : "+") + "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }
    static func timestamp(_ value: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: value)
        return String(format: "%02d.%02d.%04d %02d:%02d", p.day ?? 0, p.month ?? 0, p.year ?? 0, p.hour ?? 0, p.minute ?? 0)
    }
    /// 0 = Monday ... 6 = Sunday.
    static func weekdayIndex(_ value: LocalDate) -> Int { ((daysFromCivil(value) % 7) + 7 + 3) % 7 }
    static func weekday(_ value: LocalDate) -> String { weekdays[weekdayIndex(value)] }

    /// Days since 1970-01-01 (proleptic Gregorian).
    static func daysFromCivil(_ value: LocalDate) -> Int {
        let y = value.month <= 2 ? value.year - 1 : value.year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (value.month + 9) % 12
        let doy = (153 * mp + 2) / 5 + value.day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
    /// Excel serial day number (1900 date system).
    static func excelSerial(_ value: LocalDate) -> Int { daysFromCivil(value) + 25_569 }

    /// Rendered text of a cell (CSV and PDF); untrusted text is returned as is.
    static func text(_ cell: ExportCell) -> String {
        switch cell {
        case .empty: ""
        case .text(let value): value
        case .date(let value): date(value)
        case .time(let value): time(value)
        case .duration(let value): duration(value)
        case .signed(let value): signed(value)
        }
    }
    /// A text starting with one of these characters could be read as a formula (ADR-0006).
    static func isFormulaRisk(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return ["=", "+", "-", "@", "\t", "\r"].contains(Character(first))
    }
}
