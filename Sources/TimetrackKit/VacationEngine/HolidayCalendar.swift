import Foundation

/// Fixed stage-3a region rules, not a historical municipality-level legal calendar.
public enum HolidayCalendar {
    public static let supportedRegions: Set<String> = [
        "DE", "DE-BW", "DE-BY", "DE-BE", "DE-BB", "DE-HB", "DE-HH", "DE-HE", "DE-MV",
        "DE-NI", "DE-NW", "DE-RP", "DE-SL", "DE-SN", "DE-ST", "DE-SH", "DE-TH"
    ]

    public static func holidays(year: Int, region: String = "DE-ST") throws -> [CustomCalendarDay] {
        guard (1990...2100).contains(year) else { throw VacationEngineError.unsupportedYear }
        guard supportedRegions.contains(region) else { throw VacationEngineError.unsupportedRegion }
        var days: [CustomCalendarDay] = []
        func add(_ date: LocalDate, _ name: String) {
            days.append(CustomCalendarDay(startDate: date, endDate: date, name: name, source: .builtin))
        }
        func fixed(_ month: Int, _ day: Int, _ name: String) throws {
            add(try LocalDate(year: year, month: month, day: day), name)
        }
        func inRegions(_ regions: String...) -> Bool { regions.contains(region) }
        let easter = try easterSunday(year: year)
        try fixed(1, 1, "Neujahr")
        if inRegions("DE-BW", "DE-BY", "DE-ST") { try fixed(1, 6, "Heilige Drei Könige") }
        if (region == "DE-BE" && year >= 2019) || (region == "DE-MV" && year >= 2023) {
            try fixed(3, 8, "Internationaler Frauentag")
        }
        add(easter.addingDays(-2), "Karfreitag")
        if region == "DE-BB" { add(easter, "Ostersonntag") }
        add(easter.addingDays(1), "Ostermontag")
        try fixed(5, 1, "Tag der Arbeit")
        add(easter.addingDays(39), "Christi Himmelfahrt")
        if region == "DE-BB" { add(easter.addingDays(49), "Pfingstsonntag") }
        add(easter.addingDays(50), "Pfingstmontag")
        if inRegions("DE-BW", "DE-BY", "DE-HE", "DE-NW", "DE-RP", "DE-SL") {
            add(easter.addingDays(60), "Fronleichnam")
        }
        // Bavaria is municipality-dependent: omit it statewide; callers can add a custom holiday.
        if region == "DE-SL" { try fixed(8, 15, "Mariä Himmelfahrt") }
        if region == "DE-TH" && year >= 2019 { try fixed(9, 20, "Weltkindertag") }
        try fixed(10, 3, "Tag der Deutschen Einheit")
        if inRegions("DE-BB", "DE-MV", "DE-SN", "DE-ST", "DE-TH")
            || (year >= 2018 && inRegions("DE-HB", "DE-HH", "DE-NI", "DE-SH")) || year == 2017 {
            try fixed(10, 31, "Reformationstag")
        }
        if inRegions("DE-BW", "DE-BY", "DE-NW", "DE-RP", "DE-SL") {
            try fixed(11, 1, "Allerheiligen")
        }
        if region == "DE-SN" {
            // Wednesday strictly before 23 November, i.e. between 16 and 22 November inclusive.
            var date = try LocalDate(year: year, month: 11, day: 23)
            repeat { date = date.addingDays(-1) } while weekday(date) != 3
            add(date, "Buß- und Bettag")
        }
        try fixed(12, 25, "1. Weihnachtstag")
        try fixed(12, 26, "2. Weihnachtstag")
        return days.sorted {
            $0.startDate == $1.startDate ? $0.name < $1.name : $0.startDate < $1.startDate
        }
    }

    /// Gregorian Meeus/Jones/Butcher algorithm; arithmetic is independent of time zones.
    public static func easterSunday(year: Int) throws -> LocalDate {
        guard (1990...2100).contains(year) else { throw VacationEngineError.unsupportedYear }
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let value = h + l - 7 * m + 114
        return try LocalDate(year: year, month: value / 31, day: value % 31 + 1)
    }

    static func weekday(_ date: LocalDate) -> Int {
        if LocalDate.fastYears.contains(date.year) { return date.isoWeekday }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))!
        return (calendar.component(.weekday, from: instant) + 5) % 7 + 1
    }
    static func validate(_ days: [CustomCalendarDay]) throws {
        guard days.allSatisfy({ $0.startDate <= $0.endDate }) else { throw VacationEngineError.invalidRange }
    }
    /// A day that behaves like a public holiday: statutory, custom, or a company day treated as `full`.
    static func isHoliday(_ date: LocalDate, days: [CustomCalendarDay]) -> Bool {
        days.contains { $0.kind == .holiday && $0.companyTreatment != .half && $0.startDate <= date && date <= $0.endDate }
    }
    /// A company day treated as `half` that is not also a (full) holiday.
    static func isHalfCompanyDay(_ date: LocalDate, days: [CustomCalendarDay]) -> Bool {
        !isHoliday(date, days: days)
            && days.contains { $0.companyTreatment == .half && $0.startDate <= date && date <= $0.endDate }
    }

    /// Statutory holidays of the region plus the configured company days of the year. A company day on a date that already
    /// has a statutory holiday is dropped (the holiday wins).
    public static func calendar(year: Int, region: String = "DE-ST", companyDays: [CompanyDayRule] = []) throws -> [CustomCalendarDay] {
        let builtin = try holidays(year: year, region: region)
        guard companyDays.contains(where: { $0.treatment != .none }) else { return builtin }
        var result = builtin
        for rule in companyDays where rule.treatment != .none {
            guard let date = try? LocalDate(year: year, month: rule.month, day: rule.day),
                  !builtin.contains(where: { $0.startDate <= date && date <= $0.endDate }) else { continue }
            result.append(CustomCalendarDay(startDate: date, endDate: date, name: rule.displayName, kind: .holiday,
                                            source: .builtin, companyTreatment: rule.treatment))
        }
        return result
    }
}
