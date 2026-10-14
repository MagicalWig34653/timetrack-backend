import Foundation
import XCTest
@testable import TimetrackKit

final class TimeEngineTests: XCTestCase {
    private let day = try! LocalDate("2026-10-12")
    private let now = ISO8601DateFormatter().date(from: "2026-10-14T18:00:00Z")!
    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func time(_ value: String, date: String = "2026-10-12", offset: String = "+02:00") -> Date {
        instant("\(date)T\(value):00\(offset)")
    }
    private func segment(_ start: String, _ end: String, kind: EngineSegmentKind = .work) -> EngineSegment {
        EngineSegment(kind: kind, start: time(start), end: time(end))
    }
    private func model() -> EngineWorkModel {
        EngineWorkModel(validFrom: try! LocalDate("2026-01-01"), weeklyTargetSeconds: 138_600, workdays: [1, 2, 3, 4, 5])
    }
    private func evaluate(_ segments: [EngineSegment], model: EngineWorkModel? = nil,
                          preferences: DayPreferences = DayPreferences()) throws -> DayEvaluationResult {
        try TimeEngine.evaluateDay(date: day, model: model ?? self.model(), segments: segments, preferences: preferences, now: now)
    }
    private func fixed(_ start: Int, _ end: Int) throws -> FixedBreak {
        try FixedBreak(start: LocalTime(hour: start / 60, minute: start % 60), end: LocalTime(hour: end / 60, minute: end % 60))
    }

    func testTargetsAndOverrides() throws {
        XCTAssertEqual(try evaluate([]).targetSeconds, 27_720)
        var m = model()
        m.dailyTargetSeconds = [1: 12_345, 7: 40_000]
        XCTAssertEqual(try evaluate([], model: m).targetSeconds, 12_345)
        XCTAssertEqual(try TimeEngine.evaluateDay(date: LocalDate("2026-10-11"), model: m, segments: [], now: now).targetSeconds, 0)
        m.workdays = []
        XCTAssertEqual(try evaluate([], model: m).targetSeconds, 0)
    }

    func testRoundingExamplesTable() throws {
        let cases: [([EngineSegment], Int, Int, Int, Int)] = [
            ([segment("08:07", "12:00"), segment("13:00", "16:02")], 24_900, 420, 780, 26_100),
            ([segment("08:00", "16:15")], 29_700, 0, 0, 29_700),
            ([segment("08:07", "16:02")], 28_500, 420, 780, 29_700),
            ([segment("08:07", "11:13"), segment("11:13", "16:02")], 28_500, 420, 780, 29_700)
        ]
        for (segments, raw, start, end, evaluated) in cases {
            let result = try evaluate(segments)
            XCTAssertEqual(result.rawWorkSeconds, raw)
            XCTAssertEqual(result.startAdjustSeconds, start)
            XCTAssertEqual(result.endAdjustSeconds, end)
            XCTAssertEqual(result.evaluatedWorkSeconds, evaluated)
            XCTAssertEqual(result.evaluatedStart, time("08:00"))
            XCTAssertEqual(result.evaluatedEnd, time("16:15"))
            XCTAssertEqual(result.segments, segments)
        }
        var m = model(); m.roundingEnabled = false
        XCTAssertEqual(try evaluate(cases[0].0, model: m).evaluatedWorkSeconds, 24_900)
    }

    func testFixedBreakIntersectionsUnionAndSkip() throws {
        var m = model(); m.roundingEnabled = false
        m.fixedBreaks = [try fixed(720, 750), try fixed(735, 765)]
        for (segments, deduction) in [([segment("08:00", "16:00")], 2700),
                                       ([segment("08:00", "12:15"), segment("12:30", "16:00")], 1800),
                                       ([segment("08:00", "12:00"), segment("13:00", "16:00")], 0)] {
            let result = try evaluate(segments, model: m)
            XCTAssertEqual(result.breakDeductionSeconds, deduction)
            XCTAssertEqual(result.evaluatedWorkSeconds, result.rawWorkSeconds - deduction)
            let skipped = try evaluate(segments, model: m, preferences: DayPreferences(skipFixedBreaks: true))
            XCTAssertEqual(skipped.breakDeductionSeconds, 0)
            XCTAssertEqual(skipped.evaluatedWorkSeconds, skipped.rawWorkSeconds)
        }
        let full = try evaluate([segment("08:00", "16:00")], model: m)
        XCTAssertTrue(full.breakHints.contains(BreakHint(code: .breakMissing30)), "Templates do not prove a real break")
    }

    func testSchoolThresholdReplacesAllKindsAndBelowNeverFills() throws {
        for (minutes, credit) in [(135, 0), (180, 27_720), (225, 27_720)] {
            let school = EngineSegment(kind: .school, start: time("08:00"), end: time("08:00").addingTimeInterval(Double(minutes * 60)))
            let result = try evaluate([school, segment("13:00", "14:00"), segment("14:00", "14:30", kind: .travel)])
            XCTAssertEqual(result.creditSeconds, credit)
            XCTAssertEqual(result.rawWorkSeconds, minutes * 60 + 5400)
            XCTAssertEqual(result.evaluatedWorkSeconds, credit == 0 ? minutes * 60 + 5400 : 0)
            XCTAssertEqual(result.startAdjustSeconds + result.endAdjustSeconds, 0)
        }
        var m = model(); m.schoolCreditSeconds = 30_000
        XCTAssertEqual(try evaluate([segment("08:00", "11:00", kind: .school)], model: m).creditSeconds, 30_000)
        m.schoolFullDayThresholdSeconds = 0
        XCTAssertEqual(try evaluate([], model: m).creditSeconds, 0)
    }

    func testSeparateSchoolLessonsAndManualSupplement() throws {
        let lessons = [segment("08:00", "08:45", kind: .school), segment("09:00", "09:45", kind: .school),
                       segment("10:00", "10:45", kind: .school), segment("11:00", "11:45", kind: .school)]
        XCTAssertEqual(try evaluate(lessons).creditSeconds, 27_720)
        XCTAssertEqual(try evaluate(Array(lessons.prefix(3))).evaluatedWorkSeconds, 8100)
        XCTAssertEqual(try evaluate(Array(lessons.prefix(3)) + [segment("13:00", "14:00")]).evaluatedWorkSeconds, 11_700)
    }

    func testOvernightBreakAndNonCountingOuterSegments() throws {
        var m = model(); m.fixedBreaks = [try fixed(23 * 60 + 45, 15)]
        let shift = EngineSegment(start: time("22:00"), end: time("06:00", date: "2026-10-13"))
        XCTAssertEqual(try evaluate([shift], model: m).breakDeductionSeconds, 1800)
        m.travelCountsAsWork = false
        let result = try evaluate([segment("07:01", "08:00", kind: .travel), segment("08:07", "12:02"),
                                   segment("12:02", "13:01", kind: .travel)], model: m)
        XCTAssertEqual(result.startAdjustSeconds, 420)
        XCTAssertEqual(result.endAdjustSeconds, 780)
        XCTAssertEqual(result.evaluatedEnd, time("12:15"))
    }

    func testTravelFlagAndVoidedSegments() throws {
        var m = model()
        let travel = segment("07:07", "08:00", kind: .travel)
        let work = segment("08:07", "12:00")
        var voided = segment("06:00", "19:00"); voided.voided = true
        XCTAssertEqual(try evaluate([travel, work, voided]).rawWorkSeconds, 17_160)
        m.travelCountsAsWork = false
        let result = try evaluate([travel, work, voided], model: m)
        XCTAssertEqual(result.rawWorkSeconds, 13_980)
        XCTAssertEqual(result.startAdjustSeconds, 420)
        XCTAssertEqual(result.segmentIds, [travel.id, work.id])
    }

    func testNightShiftMidnightAndBoundary() throws {
        let shift = EngineSegment(start: time("22:07"), end: time("06:02", date: "2026-10-13"))
        let result = try evaluate([shift])
        XCTAssertEqual(result.rawWorkSeconds, 28_500)
        XCTAssertEqual(result.evaluatedWorkSeconds, 29_700)
        XCTAssertEqual(result.evaluatedEnd, time("06:15", date: "2026-10-13"))
        XCTAssertEqual(try TimeEngine.evaluateDay(date: LocalDate("2026-10-13"), model: model(), segments: [shift], now: now).rawWorkSeconds, 0)
        var m = model(); m.dayBoundaryMinutes = 240
        XCTAssertEqual(try TimeEngine.assignedDate(for: time("03:59", date: "2026-10-13"), model: m), day)
        XCTAssertEqual(try TimeEngine.assignedDate(for: time("04:00", date: "2026-10-13"), model: m), try LocalDate("2026-10-13"))
        m.fixedBreaks = [try fixed(120, 150)]
        XCTAssertEqual(try evaluate([shift], model: m).breakDeductionSeconds, 1800)
    }

    func testDSTFullDaysAndRepeatedHourRounding() throws {
        let cases = [
            ("2026-03-29", "2026-03-29T00:00:00+01:00", "2026-03-30T00:00:00+02:00", 23),
            ("2026-10-25", "2026-10-25T00:00:00+02:00", "2026-10-26T00:00:00+01:00", 25)
        ]
        for (date, start, end, hours) in cases {
            let result = try TimeEngine.evaluateDay(date: LocalDate(date), model: model(),
                segments: [EngineSegment(start: instant(start), end: instant(end))], now: instant(end))
            XCTAssertEqual(result.rawWorkSeconds, hours * 3600)
            XCTAssertEqual(result.evaluatedWorkSeconds, hours * 3600)
        }
        for offset in ["+02:00", "+01:00"] {
            let start = time("02:07", date: "2026-10-25", offset: offset)
            let end = time("02:32", date: "2026-10-25", offset: offset)
            let result = try TimeEngine.evaluateDay(date: LocalDate("2026-10-25"), model: model(),
                segments: [EngineSegment(start: start, end: end)], now: end)
            XCTAssertEqual(result.startAdjustSeconds, 420)
            XCTAssertEqual(result.endAdjustSeconds, 780)
        }
    }

    func testDSTBreakTemplatesAndWallClockBoundary() throws {
        var m = model(); m.fixedBreaks = [try fixed(90, 210)]; m.roundingEnabled = false
        for (date, offset, endOffset, deduction) in [("2026-03-29", "+01:00", "+02:00", 3600),
                                                   ("2026-10-25", "+02:00", "+01:00", 10_800)] {
            let result = try TimeEngine.evaluateDay(date: LocalDate(date), model: m,
                segments: [EngineSegment(start: time("00:00", date: date, offset: offset), end: time("05:00", date: date, offset: endOffset))], now: now)
            XCTAssertEqual(result.breakDeductionSeconds, deduction)
        }
        m.fixedBreaks = [try fixed(130, 150)]
        let spring = try TimeEngine.evaluateDay(date: LocalDate("2026-03-29"), model: m,
            segments: [EngineSegment(start: instant("2026-03-29T00:00:00+01:00"), end: instant("2026-03-29T05:00:00+02:00"))], now: now)
        XCTAssertEqual(spring.breakDeductionSeconds, 0, "Both nonexistent endpoints advance to 03:00")
        m.dayBoundaryMinutes = 240
        XCTAssertEqual(try TimeEngine.assignedDate(for: instant("2026-03-29T04:00:00+02:00"), model: m), try LocalDate("2026-03-29"))
    }

    func testRunningFutureAndEmptyDays() throws {
        let running = EngineSegment(start: time("08:07"))
        let result = try TimeEngine.evaluateDay(date: day, model: model(), segments: [running], now: time("09:02"))
        XCTAssertTrue(result.provisional)
        XCTAssertEqual(result.rawWorkSeconds, 3300)
        XCTAssertEqual(result.evaluatedWorkSeconds, 4500)
        let future = try TimeEngine.evaluateDay(date: day, model: model(), segments: [running], now: time("09:00", date: "2026-10-11"))
        XCTAssertFalse(future.provisional)
        XCTAssertEqual(future.evaluatedWorkSeconds, 0)
        XCTAssertFalse(try evaluate([]).provisional)
        XCTAssertNil(try evaluate([]).evaluatedStart)
    }

    func testMarksAndCreditPrecedence() throws {
        for mark in [DayMarkKind.holiday, .vacation, .sick] {
            let result = try evaluate([], preferences: DayPreferences(mark: mark))
            XCTAssertEqual(result.targetSeconds, 0)
            XCTAssertEqual(result.deltaSeconds, 0)
            let worked = try evaluate([segment("08:00", "10:00")], preferences: DayPreferences(mark: mark))
            XCTAssertEqual(worked.deltaSeconds, 7200)
            let credited = try evaluate([segment("08:00", "12:00", kind: .school)], preferences: DayPreferences(mark: mark, creditSeconds: 600))
            XCTAssertEqual(credited.creditSeconds, 600)
            XCTAssertEqual(credited.evaluatedWorkSeconds, 0)
        }
        let school = try evaluate([segment("08:00", "12:00", kind: .school)], preferences: DayPreferences(mark: .schoolCredit, creditSeconds: 900))
        XCTAssertEqual(school.creditSeconds, 900)
        XCTAssertEqual(school.evaluatedWorkSeconds, 0)
        XCTAssertEqual(school.targetSeconds, 27_720)
        XCTAssertEqual(try evaluate([], preferences: DayPreferences(mark: .schoolCredit)).deltaSeconds, 0)
    }

    func testBreakHintsTableUsesActualTimes() throws {
        let cases: [([EngineSegment], Set<BreakHint.Code>)] = [
            ([segment("08:00", "14:00")], []),
            ([segment("08:00", "14:01")], [.breakMissing30, .workOver6hWithoutBreak]),
            ([segment("08:00", "12:00"), segment("12:30", "17:31")], [.breakMissing45]),
            ([segment("08:00", "12:00"), segment("12:45", "18:00")], []),
            ([segment("08:00", "11:00"), segment("11:10", "14:10"), segment("14:20", "15:20")],
             [.breakMissing30, .breakPartTooShort, .workOver6hWithoutBreak]),
            ([segment("08:07", "14:07")], []),
            ([segment("08:00", "11:00"), segment("11:15", "14:15"), segment("14:30", "15:00")], [])
        ]
        for (segments, codes) in cases { XCTAssertEqual(Set(try evaluate(segments).breakHints.map(\.code)), codes) }
    }

    func testModelHistoryAndOverlapValidation() throws {
        var first = model(); first.validTo = try LocalDate("2026-10-12")
        var second = model(); second.validFrom = try LocalDate("2026-10-13"); second.weeklyTargetSeconds = 144_000
        let old = try XCTUnwrap(TimeEngine.selectModel(for: day, models: [second, first]))
        XCTAssertEqual(try evaluate([], model: old).targetSeconds, 27_720)
        XCTAssertEqual(try TimeEngine.selectModel(for: LocalDate("2026-10-13"), models: [first, second])?.id, second.id)
        XCTAssertNil(try TimeEngine.selectModel(for: LocalDate("2025-12-31"), models: [first, second]))
        second.validFrom = day
        XCTAssertThrowsError(try TimeEngine.selectModel(for: day, models: [first, second]))
        XCTAssertThrowsError(try TimeEngine.selectModel(for: day, models: [model(), model()]))
    }

    func testAccountIncludesEmptyDaysMarksOpeningAndDatedAdjustments() throws {
        let today = try LocalDate("2026-10-14")
        let result = try TimeEngine.accountBalance(accountStart: day, asOf: LocalDate("2026-10-20"), timezone: "Europe/Berlin",
            models: [model()], segments: [segment("08:00", "16:00")],
            preferences: [try LocalDate("2026-10-13"): DayPreferences(mark: .vacation)], now: now,
            openingSeconds: 3600, adjustments: [AccountAdjustment(date: day, seconds: -600),
                AccountAdjustment(date: try LocalDate("2026-10-15"), seconds: 99_999),
                AccountAdjustment(date: try LocalDate("2026-10-11"), seconds: 99_999)])
        XCTAssertEqual(result.asOf, today)
        XCTAssertEqual(result.adjustmentSeconds, -600)
        XCTAssertEqual(result.balanceSeconds, 3600 - 600 + 28_800 - 27_720 - 27_720)
        XCTAssertTrue(result.provisional)
        let past = try TimeEngine.accountBalance(accountStart: day, asOf: day, today: today, evaluations: [evaluate([])])
        XCTAssertFalse(past.provisional)
        XCTAssertThrowsError(try TimeEngine.accountBalance(accountStart: day, asOf: day, today: today, evaluations: []))
        let evaluated = try evaluate([])
        XCTAssertThrowsError(try TimeEngine.accountBalance(accountStart: day, asOf: day, today: today, evaluations: [evaluated, evaluated]))
    }

    func testOverlapChecksAndInvalidInputs() throws {
        let first = segment("08:00", "10:00")
        XCTAssertFalse(try TimeEngine.detectOverlap(first, segment("10:00", "11:00")))
        XCTAssertTrue(try TimeEngine.detectOverlap(first, segment("09:00", "11:00")))
        XCTAssertTrue(try TimeEngine.detectOverlap(first, EngineSegment(start: time("09:00"))))
        var voided = first; voided.voided = true
        XCTAssertFalse(try TimeEngine.detectOverlap(first, voided))
        XCTAssertThrowsError(try evaluate([first, segment("09:00", "11:00")]))
        XCTAssertThrowsError(try evaluate([first, first]))
        XCTAssertThrowsError(try evaluate([segment("10:00", "08:00")]))
        XCTAssertThrowsError(try evaluate([], preferences: DayPreferences(creditSeconds: -1)))
        for mutate: (inout EngineWorkModel) -> Void in [
            { $0.roundingMinutes = 0 }, { $0.timezone = "Invalid/Zone" }, { $0.workdays = [8] },
            { $0.weeklyTargetSeconds = -1 }, { $0.dayBoundaryMinutes = 720 }
        ] {
            var m = model(); mutate(&m)
            XCTAssertThrowsError(try evaluate([], model: m))
        }
        XCTAssertThrowsError(try LocalDate("2026-02-29"))
        XCTAssertThrowsError(try LocalTime(hour: 24, minute: 0))
        XCTAssertNoThrow(try LocalDate("2024-02-29"))
    }

    func testContractEncodingAndRawMetadataPreservation() throws {
        let start = time("08:07")
        let raw = time("08:10")
        let input = EngineSegment(start: start, rawStartedAt: raw, source: .timer, version: 2, revisions: 1)
        let result = try TimeEngine.evaluateDay(date: day, model: model(), segments: [input], now: time("09:00"))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["date"] as? String, "2026-10-12")
        XCTAssertEqual(object["deltaSeconds"] as? Int, result.deltaSeconds)
        let segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        XCTAssertTrue(segments[0]["endedAt"] is NSNull)
        XCTAssertTrue(segments[0]["rawEndedAt"] is NSNull)
        XCTAssertEqual(result.segments[0].rawStartedAt, raw)
        XCTAssertEqual(try JSONDecoder().decode(LocalDate.self, from: Data("\"2026-10-12\"".utf8)), day)
    }

    func testSeededRoundingPropertiesDeterminismAndOrderIndependence() throws {
        var seed: UInt64 = 0xC5
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed % UInt64(bound))
        }
        for _ in 0..<100 {
            var m = model(); m.roundingMinutes = next(60) + 1
            let start = time("06:00").addingTimeInterval(Double(next(3600)))
            let middle = start.addingTimeInterval(Double(next(3600) + 1))
            let second = middle.addingTimeInterval(Double(next(1800)))
            let end = second.addingTimeInterval(Double(next(18_000) + 1))
            let segments = [EngineSegment(start: start, end: middle), EngineSegment(start: second, end: end)]
            let result = try evaluate(segments, model: m)
            XCTAssertGreaterThanOrEqual(result.evaluatedWorkSeconds, result.rawWorkSeconds)
            XCTAssertEqual(result, try evaluate(segments, model: m))
            XCTAssertEqual(result, try evaluate(segments.reversed(), model: m))
            XCTAssertEqual(result.evaluatedWorkSeconds, result.rawWorkSeconds + result.startAdjustSeconds + result.endAdjustSeconds)
        }
    }
}
