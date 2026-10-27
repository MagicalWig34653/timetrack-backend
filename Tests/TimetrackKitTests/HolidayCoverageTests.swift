import Foundation
import XCTest
@testable import TimetrackKit

/// N2: every region delivers its complete statutory holiday table for the current and the next year.
final class HolidayCoverageTests: XCTestCase {
    private struct Year {
        let year: Int
        let goodFriday: String, easterSunday: String, easterMonday: String, ascension: String
        let whitSunday: String, whitMonday: String, corpusChristi: String, penanceDay: String
    }
    // Independent date tables (no use of the production Easter arithmetic).
    private static let years = [
        Year(year: 2026, goodFriday: "04-03", easterSunday: "04-05", easterMonday: "04-06", ascension: "05-14",
             whitSunday: "05-24", whitMonday: "05-25", corpusChristi: "06-04", penanceDay: "11-18"),
        Year(year: 2027, goodFriday: "03-26", easterSunday: "03-28", easterMonday: "03-29", ascension: "05-06",
             whitSunday: "05-16", whitMonday: "05-17", corpusChristi: "05-27", penanceDay: "11-17"),
    ]
    private static let epiphany: Set<String> = ["DE-BW", "DE-BY", "DE-ST"]
    private static let womensDay: Set<String> = ["DE-BE", "DE-MV"]
    private static let corpus: Set<String> = ["DE-BW", "DE-BY", "DE-HE", "DE-NW", "DE-RP", "DE-SL"]
    private static let reformation: Set<String> = ["DE-BB", "DE-MV", "DE-SN", "DE-ST", "DE-TH", "DE-HB", "DE-HH", "DE-NI", "DE-SH"]
    private static let allSaints: Set<String> = ["DE-BW", "DE-BY", "DE-NW", "DE-RP", "DE-SL"]

    private func expected(_ year: Year, region: String) -> [String: String] {
        var days: [String: String] = [
            "01-01": "Neujahr", year.goodFriday: "Karfreitag", year.easterMonday: "Ostermontag", "05-01": "Tag der Arbeit",
            year.ascension: "Christi Himmelfahrt", year.whitMonday: "Pfingstmontag", "10-03": "Tag der Deutschen Einheit",
            "12-25": "1. Weihnachtstag", "12-26": "2. Weihnachtstag",
        ]
        if Self.epiphany.contains(region) { days["01-06"] = "Heilige Drei Könige" }
        if Self.womensDay.contains(region) { days["03-08"] = "Internationaler Frauentag" }
        if region == "DE-BB" { days[year.easterSunday] = "Ostersonntag"; days[year.whitSunday] = "Pfingstsonntag" }
        if Self.corpus.contains(region) { days[year.corpusChristi] = "Fronleichnam" }
        if region == "DE-SL" { days["08-15"] = "Mariä Himmelfahrt" }
        if region == "DE-TH" { days["09-20"] = "Weltkindertag" }
        if Self.reformation.contains(region) { days["10-31"] = "Reformationstag" }
        if Self.allSaints.contains(region) { days["11-01"] = "Allerheiligen" }
        if region == "DE-SN" { days[year.penanceDay] = "Buß- und Bettag" }
        return days
    }

    func testEveryRegionHasItsCompleteHolidayTableForCurrentAndNextYear() throws {
        XCTAssertEqual(HolidayCalendar.supportedRegions.count, 17)
        for region in HolidayCalendar.supportedRegions.sorted() {
            for year in Self.years {
                let actual = try HolidayCalendar.holidays(year: year.year, region: region)
                let table = Dictionary(actual.map { (String($0.startDate.description.dropFirst(5)), $0.name) }, uniquingKeysWith: { first, _ in first })
                XCTAssertEqual(table, expected(year, region: region), "\(region) \(year.year)")
                XCTAssertEqual(actual.count, table.count, "no duplicate dates in \(region) \(year.year)")
                XCTAssertTrue(actual.allSatisfy { $0.kind == .holiday && $0.source == .builtin && $0.startDate == $0.endDate })
                // 24.12. and 31.12. are no statutory holidays; the model has no half-day kind, so they are never delivered.
                XCTAssertFalse(table.keys.contains("12-24") || table.keys.contains("12-31"), "\(region) \(year.year)")
            }
        }
    }

    func testChristmasAndNewYearAreInEveryRegionForEveryYear() throws {
        for region in HolidayCalendar.supportedRegions {
            for year in 1990...2100 {
                // Two holidays may share a date (1.5.2008 was also Ascension Day).
                let names = Dictionary(try HolidayCalendar.holidays(year: year, region: region).map { ($0.startDate.description, $0.name) }, uniquingKeysWith: { first, _ in first })
                XCTAssertEqual(names["\(year)-12-25"], "1. Weihnachtstag", "\(region) \(year)")
                XCTAssertEqual(names["\(year)-12-26"], "2. Weihnachtstag", "\(region) \(year)")
                XCTAssertEqual(names["\(year)-01-01"], "Neujahr", "\(region) \(year)")
            }
        }
    }
}
