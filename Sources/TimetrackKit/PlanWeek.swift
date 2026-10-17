import Foundation

/// An ISO 8601 week (Monday to Sunday), addressed as "2026-W44" (ADR-0021).
struct ISOWeek: Sendable, Equatable {
    let year: Int, number: Int, monday: LocalDate
    var sunday: LocalDate { monday.addingDays(6) }
    var dates: [LocalDate] { (0..<7).map { monday.addingDays($0) } }
    var label: String { String(format: "%04d-W%02d", year, number) }

    init(_ text: String) throws {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 3, parts[1].first == "W",
              text.utf8.allSatisfy({ $0 == 45 || $0 == 87 || (48...57).contains($0) }),
              let year = Int(parts[0]), let number = Int(parts[1].dropFirst()), (1900...2200).contains(year), (1...53).contains(number) else {
            throw APIError(.badRequest, "invalid_week")
        }
        guard let january4 = try? LocalDate(year: year, month: 1, day: 4) else { throw APIError(.badRequest, "invalid_week") }
        let monday = january4.addingDays(-(january4.isoWeekday - 1) + (number - 1) * 7)
        // The Thursday decides the ISO year: this rejects week 53 in years that only have 52 weeks.
        guard monday.addingDays(3).year == year else { throw APIError(.badRequest, "invalid_week") }
        self.year = year; self.number = number; self.monday = monday
    }
}
