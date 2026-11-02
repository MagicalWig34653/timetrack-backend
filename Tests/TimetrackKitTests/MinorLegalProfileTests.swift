import Foundation
import XCTest
@testable import TimetrackKit

final class MinorLegalProfileTests: XCTestCase {
    private func date(_ value: String) throws -> LocalDate { try LocalDate(value) }
    private func instant(_ day: String, _ clock: String) -> Date {
        ISO8601DateFormatter().date(from: "\(day)T\(clock):00+02:00")!
    }
    private func segment(_ day: String, _ start: String, _ end: String,
                         kind: EngineSegmentKind = .work) -> EngineSegment {
        EngineSegment(kind: kind, start: instant(day, start), end: instant(day, end))
    }
    private func model() throws -> EngineWorkModel {
        EngineWorkModel(validFrom: try date("2026-10-01"), weeklyTargetSeconds: 144_000,
                        workdays: [1, 2, 3, 4, 5], roundingEnabled: false,
                        legalProfileId: LegalWorkProfile.minor.id)
    }

    func testWeeklyLimitFiveDaysWeekendAndRest() throws {
        let days = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16"]
        var segments = days.map { segment($0, "08:00", "16:00") }
        segments.append(segment("2026-10-17", "08:00", "08:01"))
        let snapshot = TimeEvaluationSnapshot(models: [try model()], segments: segments, preferences: [:])
        let result = try snapshot.evaluate(date("2026-10-17"), now: instant("2026-10-20", "12:00"))
        XCTAssertEqual(Set(result.legalWarnings.map(\.code)), [.weeklyLimit, .fiveDayWeek, .weekendWork])

        let shortRest = TimeEvaluationSnapshot(models: [try model()], segments: [
            segment("2026-10-12", "12:00", "20:00"), segment("2026-10-13", "07:59", "08:00")
        ], preferences: [:])
        XCTAssertTrue(try shortRest.evaluate(date("2026-10-13"), now: instant("2026-10-20", "12:00"))
            .legalWarnings.contains(.init(.restPeriod)))
        let exactRest = TimeEvaluationSnapshot(models: [try model()], segments: [
            segment("2026-10-12", "12:00", "20:00"), segment("2026-10-13", "08:00", "08:01")
        ], preferences: [:])
        XCTAssertFalse(try exactRest.evaluate(date("2026-10-13"), now: instant("2026-10-20", "12:00"))
            .legalWarnings.contains(.init(.restPeriod)))
    }

    func testHolidayLossCountsTowardsWeeklyLimit() throws {
        let holiday = CustomCalendarDay(startDate: try date("2026-10-14"), endDate: try date("2026-10-14"), name: "Holiday")
        let days = ["2026-10-12", "2026-10-13", "2026-10-15", "2026-10-16"]
        // 4 x 8h15 = 33h worked plus the 8h Soll lost on Wednesday = 41h.
        let snapshot = TimeEvaluationSnapshot(models: [try model()], segments: days.map { segment($0, "08:00", "16:15") },
                                              preferences: [:], customDays: [holiday])
        let now = instant("2026-10-20", "12:00")
        let friday = try snapshot.evaluate(date("2026-10-16"), now: now)
        XCTAssertTrue(friday.legalWarnings.contains(.init(.weeklyLimit)))
        XCTAssertFalse(friday.legalWarnings.contains(.init(.fiveDayWeek)))
        let shorter = TimeEvaluationSnapshot(models: [try model()], segments: days.map { segment($0, "08:00", "16:00") },
                                             preferences: [:], customDays: [holiday])
        XCTAssertFalse(try shorter.evaluate(date("2026-10-16"), now: now).legalWarnings.contains(.init(.weeklyLimit)))
        let without = TimeEvaluationSnapshot(models: [try model()], segments: days.map { segment($0, "08:00", "16:15") }, preferences: [:])
        XCTAssertFalse(try without.evaluate(date("2026-10-16"), now: now).legalWarnings.contains(.init(.weeklyLimit)))
    }

    func testAnyWorkOnFullSchoolDayIsFlaggedAlsoBeforeSchool() throws {
        let day = "2026-10-12"
        let snapshot = TimeEvaluationSnapshot(models: [try model()], segments: [
            segment(day, "09:00", "09:30"), segment(day, "10:00", "15:00", kind: .school)
        ], preferences: [day: DayPreferences(schoolLessonCount: 6)])
        let result = try snapshot.evaluate(date(day), now: instant("2026-10-20", "12:00"))
        XCTAssertTrue(result.legalWarnings.contains(.init(.workAfterFullSchoolDay)))
        let ordinary = TimeEvaluationSnapshot(models: [try model()], segments: [
            segment(day, "09:00", "09:30"), segment(day, "10:00", "14:00", kind: .school)
        ], preferences: [day: DayPreferences(schoolLessonCount: 5)])
        let five = try ordinary.evaluate(date(day), now: instant("2026-10-20", "12:00"))
        XCTAssertFalse(five.legalWarnings.contains(.init(.workAfterFullSchoolDay)))
    }

    func testBlockSchoolWeekCreditsFortyHours() throws {
        let days = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16"]
        let preferences = Dictionary(uniqueKeysWithValues: days.map { ($0, DayPreferences(schoolLessonCount: 5)) })
        let snapshot = TimeEvaluationSnapshot(models: [try model()],
            segments: days.map { segment($0, "08:00", "12:00", kind: .school) }, preferences: preferences)
        let results = try days.map { try snapshot.evaluate(date($0), now: instant("2026-10-20", "12:00")) }
        XCTAssertEqual(results.map(\.creditSeconds), Array(repeating: 28_800, count: 5))
        XCTAssertEqual(results.reduce(0) { $0 + $1.creditSeconds }, 144_000)
        XCTAssertFalse(results.contains { $0.legalWarnings.contains(.init(.weeklyLimit)) })
    }

    private func blockWeekCredits(_ days: [String], customDays: [CustomCalendarDay] = [], preferences extra: [String: DayPreferences] = [:]) throws -> [Int] {
        var preferences = Dictionary(uniqueKeysWithValues: days.map { ($0, DayPreferences(schoolLessonCount: 5)) })
        for (key, value) in extra { preferences[key] = value }
        let snapshot = TimeEvaluationSnapshot(models: [try model()],
            segments: days.map { segment($0, "08:00", "12:00", kind: .school) }, preferences: preferences, customDays: customDays)
        return try days.map { try snapshot.evaluate(date($0), now: instant("2026-11-20", "12:00")).creditSeconds }
    }

    /// F10 (ADR-0028 addendum): a block week credits at most the first five school days (Monday to Sunday) with 8 h each.
    func testBlockSchoolWeekWithSixSchoolDaysCreditsFirstFiveOnly() throws {
        let days = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17"]
        let credits = try blockWeekCredits(days)
        XCTAssertEqual(credits, [28_800, 28_800, 28_800, 28_800, 28_800, 0])
        XCTAssertEqual(credits.reduce(0, +), 144_000)
        // The extra day has no credit and keeps its Soll (Saturday: 0 in this model); its school time is not a work-day replacement.
        let snapshot = TimeEvaluationSnapshot(models: [try model()], segments: days.map { segment($0, "08:00", "12:00", kind: .school) },
            preferences: Dictionary(uniqueKeysWithValues: days.map { ($0, DayPreferences(schoolLessonCount: 5)) }))
        let extra = try snapshot.evaluate(date("2026-10-17"), now: instant("2026-11-20", "12:00"))
        XCTAssertEqual(extra.creditSeconds, 0)
    }

    func testBlockSchoolWeekWithSevenSchoolDaysCreditsFortyHours() throws {
        let days = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18"]
        XCTAssertEqual(try blockWeekCredits(days), [28_800, 28_800, 28_800, 28_800, 28_800, 0, 0])
    }

    /// An extra school day on a weekday keeps its Soll and gets no credit; the first five (calendar order) are credited.
    func testBlockSchoolWeekExtraDayKeepsTarget() throws {
        let days = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17"]
        // Saturday counts as a workday here, so its unchanged Soll (8 h) is visible.
        let saturdayModel = EngineWorkModel(validFrom: try date("2026-10-01"), weeklyTargetSeconds: 172_800, workdays: [1, 2, 3, 4, 5, 6],
                                            roundingEnabled: false, legalProfileId: LegalWorkProfile.minor.id)
        let snapshot = TimeEvaluationSnapshot(models: [saturdayModel], segments: days.map { segment($0, "08:00", "12:00", kind: .school) },
            preferences: Dictionary(uniqueKeysWithValues: days.map { ($0, DayPreferences(schoolLessonCount: 5)) }))
        let saturday = try snapshot.evaluate(date("2026-10-17"), now: instant("2026-11-20", "12:00"))
        XCTAssertEqual(saturday.creditSeconds, 0)
        XCTAssertEqual(saturday.targetSeconds, 28_800)
        let friday = try snapshot.evaluate(date("2026-10-16"), now: instant("2026-11-20", "12:00"))
        XCTAssertEqual(friday.creditSeconds, 28_800)
    }

    func testBlockSchoolWeekHolidayDoesNotCountAsSchoolDay() throws {
        let days = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17"]
        let holiday = CustomCalendarDay(startDate: try date("2026-10-12"), endDate: try date("2026-10-12"), name: "Holiday")
        let credits = try blockWeekCredits(days, customDays: [holiday])
        // Monday is a holiday (no school credit); the five remaining school days Tuesday to Saturday are all credited.
        XCTAssertEqual(credits, [0, 28_800, 28_800, 28_800, 28_800, 28_800])
    }

    func testBlockSchoolWeekVacationDoesNotCountAsSchoolDay() throws {
        let days = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17"]
        let credits = try blockWeekCredits(days, preferences: ["2026-10-13": DayPreferences(mark: .vacation, schoolLessonCount: 5)])
        XCTAssertEqual(credits, [28_800, 0, 28_800, 28_800, 28_800, 28_800])
    }

    func testOnlyOneFullSchoolDayPerOrdinaryWeek() throws {
        let first = "2026-10-12", second = "2026-10-13"
        let preferences = [first: DayPreferences(schoolLessonCount: 6), second: DayPreferences(schoolLessonCount: 6)]
        let snapshot = TimeEvaluationSnapshot(models: [try model()], segments: [
            segment(first, "08:00", "13:00", kind: .school), segment(second, "08:00", "13:00", kind: .school)
        ], preferences: preferences)
        let now = instant("2026-10-20", "12:00")
        XCTAssertEqual(try snapshot.evaluate(date(first), now: now).creditSeconds, 28_800)
        let next = try snapshot.evaluate(date(second), now: now)
        XCTAssertEqual(next.creditSeconds, 0)
        XCTAssertEqual(next.rawWorkSeconds, 18_000)
    }
}
