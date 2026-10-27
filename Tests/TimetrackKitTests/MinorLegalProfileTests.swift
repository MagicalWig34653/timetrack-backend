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
