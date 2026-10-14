import Foundation

/// RFC 4180 writer: comma separated, CRLF line ends, UTF-8 without BOM.
enum CSVWriter {
    /// Untrusted text that could be read as a formula is prefixed with an apostrophe (ADR-0006), then quoted if needed.
    static func field(_ cell: ExportCell) -> String {
        var text = ExportFormat.text(cell)
        if case .text = cell, ExportFormat.isFormulaRisk(text) { text = "'" + text }
        return escape(text)
    }
    static func escape(_ text: String) -> String {
        let needsQuotes = text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) || text.hasPrefix(" ") || text.hasSuffix(" ")
        return needsQuotes ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }
    static func line(_ cells: [ExportCell]) -> String { cells.map(field).joined(separator: ",") + "\r\n" }

    static func write(_ document: ExportDocument) -> Data {
        var out = ""
        out += line([.text(document.title)])
        out += line([.text("Name"), .text(document.accountName)])
        out += line([.text("Zeitraum"), .text(document.periodText)])
        out += "\r\n"
        out += line(document.columns.map { .text($0.title) })
        for row in document.rows { out += line(row) }
        out += line(document.totals)
        out += "\r\n"
        out += line([.text(document.createdText)])
        return Data(out.utf8)
    }
}
