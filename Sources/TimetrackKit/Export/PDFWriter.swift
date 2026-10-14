import Foundation

/// Minimal PDF 1.4 writer for the time sheet table: Helvetica/WinAnsi, repeated header, page numbers, clipped text.
enum PDFWriter {
    enum Orientation: Sendable { case landscape, portrait }

    // MARK: Text encoding and metrics

    /// Maps a Unicode scalar to a WinAnsiEncoding byte; unknown characters become `?`.
    static func winAnsi(_ scalar: Unicode.Scalar) -> UInt8 {
        switch scalar.value {
        case 0x20...0x7E, 0xA0...0xFF: return UInt8(scalar.value)
        case 0x20AC: return 0x80
        case 0x201A: return 0x82
        case 0x0192: return 0x83
        case 0x201E: return 0x84
        case 0x2026: return 0x85
        case 0x2018: return 0x91
        case 0x2019: return 0x92
        case 0x201C: return 0x93
        case 0x201D: return 0x94
        case 0x2022: return 0x95
        case 0x2013: return 0x96
        case 0x2014: return 0x97
        case 0x09, 0x0A, 0x0D: return 0x20
        default: return 0x3F
        }
    }
    static func bytes(_ text: String) -> [UInt8] { text.unicodeScalars.map(winAnsi) }

    // Helvetica advance widths (1/1000 em) for 0x20...0x7E.
    private static let asciiWidths: [Int] = [
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584
    ]
    private static func width(of byte: UInt8, bold: Bool) -> Int {
        var base: Int
        switch byte {
        case 0x20...0x7E: base = asciiWidths[Int(byte) - 0x20]
        case 0xC0...0xC5: base = 667
        case 0xC7: base = 722
        case 0xC8...0xCB: base = 667
        case 0xCC...0xCF: base = 278
        case 0xD1: base = 722
        case 0xD2...0xD6, 0xD8: base = 778
        case 0xD9...0xDC: base = 722
        case 0xDF: base = 611
        case 0xE0...0xE5: base = 556
        case 0xE7: base = 500
        case 0xE8...0xEB: base = 556
        case 0xEC...0xEF: base = 278
        case 0xF1: base = 556
        case 0xF2...0xF6, 0xF8: base = 556
        case 0xF9...0xFC: base = 556
        case 0x80: base = 556
        case 0x85, 0x97: base = 1000
        case 0x96: base = 556
        case 0x91, 0x92: base = 222
        case 0x93, 0x94, 0x84: base = 333
        default: base = 556
        }
        // Helvetica-Bold is wider on average; a uniform factor keeps clipping on the safe side.
        return bold ? base * 108 / 100 : base
    }
    static func textWidth(_ text: String, size: Double, bold: Bool = false) -> Double {
        Double(bytes(text).reduce(0) { $0 + width(of: $1, bold: bold) }) * size / 1000
    }
    /// Shortens `text` with an ellipsis so that it fits into `available` points.
    static func clip(_ text: String, size: Double, bold: Bool, available: Double) -> String {
        if textWidth(text, size: size, bold: bold) <= available { return text }
        var scalars = Array(text.unicodeScalars)
        while !scalars.isEmpty {
            scalars.removeLast()
            var candidate = String.UnicodeScalarView(); candidate.append(contentsOf: scalars)
            let value = String(candidate).trimmingCharacters(in: .whitespaces) + "\u{2026}"
            if textWidth(value, size: size, bold: bold) <= available { return value }
        }
        return ""
    }
    /// Greedy word wrap into at most `maxLines` lines; the last line is clipped.
    static func wrap(_ text: String, size: Double, bold: Bool, available: Double, maxLines: Int) -> [String] {
        var lines: [String] = []; var current = ""
        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if textWidth(candidate, size: size, bold: bold) <= available || current.isEmpty { current = candidate }
            else { lines.append(current); current = String(word) }
        }
        if !current.isEmpty { lines.append(current) }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines - 1)) + [lines.dropFirst(maxLines - 1).joined(separator: " ")]
        }
        return lines.map { clip($0, size: size, bold: bold, available: available) }
    }

    // MARK: Content stream builder

    private struct Page { var content = "" }

    private static func number(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        return text.contains(".") ? String(text.reversed().drop(while: { $0 == "0" }).drop(while: { $0 == "." }).reversed()) : text
    }
    private static func hex(_ text: String) -> String { bytes(text).map { String(format: "%02X", $0) }.joined() }
    private static func text(_ page: inout Page, _ value: String, x: Double, y: Double, size: Double, bold: Bool = false) {
        guard !value.isEmpty else { return }
        page.content += "BT /\(bold ? "F2" : "F1") \(number(size)) Tf \(number(x)) \(number(y)) Td <\(hex(value))> Tj ET\n"
    }
    private static func rectangle(_ page: inout Page, x: Double, y: Double, width: Double, height: Double, gray: Double) {
        page.content += "\(number(gray)) g \(number(x)) \(number(y)) \(number(width)) \(number(height)) re f 0 g\n"
    }
    private static func line(_ page: inout Page, x1: Double, y1: Double, x2: Double, y2: Double, gray: Double, thickness: Double = 0.4) {
        page.content += "\(number(gray)) G \(number(thickness)) w \(number(x1)) \(number(y1)) m \(number(x2)) \(number(y2)) l S 0 G\n"
    }

    // MARK: Writer

    static func write(_ document: ExportDocument, orientation: Orientation = .landscape) -> Data {
        let (pageWidth, pageHeight): (Double, Double) = orientation == .landscape ? (841.89, 595.28) : (595.28, 841.89)
        let margin = 28.0, fontSize = orientation == .landscape ? 7.5 : 6.0, rowHeight = fontSize + 6
        let cellPadding = 3.0
        let tableWidth = pageWidth - 2 * margin
        let totalWeight = document.columns.reduce(0) { $0 + $1.weight }
        let widths = document.columns.map { $0.weight / totalWeight * tableWidth }
        var xs: [Double] = []; var cursor = margin
        for width in widths { xs.append(cursor); cursor += width }
        let headerLines = document.columns.enumerated().map {
            wrap($1.title, size: fontSize, bold: true, available: widths[$0] - 2 * cellPadding, maxLines: 3)
        }
        let headerLineCount = max(1, headerLines.map(\.count).max() ?? 1)
        let headerHeight = Double(headerLineCount) * (fontSize + 1.5) + 4
        let bandHeight = fontSize + 5
        let footerY = 16.0
        let bottomLimit = 34.0

        var pages: [Page] = []
        var page = Page(); var y = pageHeight - margin

        func drawHeader() {
            for group in document.groups {
                let x = xs[group.first], w = xs[group.last] + widths[group.last] - x
                rectangle(&page, x: x, y: y - bandHeight, width: w, height: bandHeight, gray: 0.82)
                let title = clip(group.title, size: fontSize, bold: true, available: w - 2 * cellPadding)
                text(&page, title, x: x + (w - textWidth(title, size: fontSize, bold: true)) / 2, y: y - bandHeight + 3, size: fontSize, bold: true)
                line(&page, x1: x, y1: y, x2: x, y2: y - bandHeight - headerHeight, gray: 0.35, thickness: 0.8)
                line(&page, x1: x + w, y1: y, x2: x + w, y2: y - bandHeight - headerHeight, gray: 0.35, thickness: 0.8)
            }
            y -= bandHeight
            rectangle(&page, x: margin, y: y - headerHeight, width: tableWidth, height: headerHeight, gray: 0.9)
            for (index, lines) in headerLines.enumerated() {
                for (offset, value) in lines.enumerated() {
                    let w = textWidth(value, size: fontSize, bold: true)
                    text(&page, value, x: xs[index] + (widths[index] - w) / 2, y: y - fontSize - 2 - Double(offset) * (fontSize + 1.5), size: fontSize, bold: true)
                }
            }
            y -= headerHeight
            line(&page, x1: margin, y1: y, x2: margin + tableWidth, y2: y, gray: 0, thickness: 0.6)
        }
        func drawRow(_ cells: [ExportCell], bold: Bool) {
            if bold { line(&page, x1: margin, y1: y, x2: margin + tableWidth, y2: y, gray: 0, thickness: 0.8) }
            for (index, cell) in cells.enumerated() where index < document.columns.count {
                let available = widths[index] - 2 * cellPadding
                let value = clip(ExportFormat.text(cell), size: fontSize, bold: bold, available: available)
                let w = textWidth(value, size: fontSize, bold: bold)
                let x = document.columns[index].alignment == .right ? xs[index] + widths[index] - cellPadding - w : xs[index] + cellPadding
                text(&page, value, x: x, y: y - fontSize - 2, size: fontSize, bold: bold)
            }
            y -= rowHeight
            line(&page, x1: margin, y1: y, x2: margin + tableWidth, y2: y, gray: 0.8)
        }

        // Title block on the first page.
        text(&page, document.title, x: margin, y: y - 14, size: 16, bold: true); y -= 24
        text(&page, "Name: \(document.accountName)", x: margin, y: y - 10, size: 10); y -= 14
        text(&page, "Zeitraum: \(document.periodText)", x: margin, y: y - 10, size: 10); y -= 20
        drawHeader()
        for row in document.rows {
            if y - rowHeight < bottomLimit { pages.append(page); page = Page(); y = pageHeight - margin; drawHeader() }
            drawRow(row, bold: false)
        }
        if y - rowHeight < bottomLimit { pages.append(page); page = Page(); y = pageHeight - margin; drawHeader() }
        drawRow(document.totals, bold: true)
        pages.append(page)

        for index in pages.indices {
            text(&pages[index], document.createdText, x: margin, y: footerY, size: 7)
            let label = "Seite \(index + 1) von \(pages.count)"
            text(&pages[index], label, x: pageWidth - margin - textWidth(label, size: 7), y: footerY, size: 7)
        }

        // Objects: 1 catalog, 2 pages, 3/4 fonts, 5 info, then page/content pairs.
        var objects: [Data] = []
        let kids = pages.indices.map { "\(6 + $0 * 2) 0 R" }.joined(separator: " ")
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>".utf8))
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8))
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>".utf8))
        var utc = Calendar(identifier: .gregorian); utc.timeZone = .gmt
        let p = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: document.createdAt)
        let created = String(format: "D:%04d%02d%02d%02d%02d%02dZ", p.year ?? 1970, p.month ?? 1, p.day ?? 1, p.hour ?? 0, p.minute ?? 0, p.second ?? 0)
        objects.append(Data("<< /Title <\(hex("Zeitnachweis"))> /Producer (Timetrack) /CreationDate (\(created)) >>".utf8))
        for (index, content) in pages.enumerated() {
            let stream = Data(content.content.utf8)
            objects.append(Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(number(pageWidth)) \(number(pageHeight))] "
                + "/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents \(7 + index * 2) 0 R >>").utf8))
            var object = Data("<< /Length \(stream.count) >>\nstream\n".utf8)
            object.append(stream); object.append(Data("\nendstream".utf8))
            objects.append(object)
        }

        var output = Data("%PDF-1.4\n".utf8)
        output.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(output.count)
            output.append(Data("\(index + 1) 0 obj\n".utf8)); output.append(object); output.append(Data("\nendobj\n".utf8))
        }
        let xref = output.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 5 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        output.append(Data(table.utf8))
        return output
    }
}
