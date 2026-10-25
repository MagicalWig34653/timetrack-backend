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
