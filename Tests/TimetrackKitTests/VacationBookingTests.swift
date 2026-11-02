import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// Bookings on vacation days (proposal VB1, ADR-0034): allowed and counted fully as actual time above the day's target.
extension AuthTests {
    private func vbToday(_ offset: Int = 0) -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return LocalDate.local(Date(), calendar: calendar).addingDays(offset)
    }
    /// A past Monday (summer time, Europe/Berlin = UTC+2) plus the following days.
    private var monday: String { "2026-09-07" }
    private func day(_ app: Application, _ context: AuthContext, _ date: String) async throws -> [String: Any] {
        try object(await timeRequest(app, context, .GET, "time/days/" + date))
    }
    private func account(_ app: Application, _ context: AuthContext) async throws -> Int {
        let value = try object(await timeRequest(app, context, .GET, "time/account"))
        return try XCTUnwrap(value["balanceSeconds"] as? Int)
    }
    /// Booked vacation in half days (2026).
    private func usedVacation(_ app: Application, _ context: AuthContext) async throws -> Int {
        let value = try object(await timeRequest(app, context, .GET, "vacation/balance?year=2026"))
        return try XCTUnwrap(value["bookedHalfDays"] as? Int, "\(value)")
    }
    /// 08:00-14:00 local (06:00Z-12:00Z) = 6 h on the given 2026-09 day.
    private func book(_ app: Application, _ context: AuthContext, _ date: String, hours: Int = 6) async throws {
        try await timeRequest(app, context, .POST, "time/segments",
                              segmentBody("\(date)T06:00:00Z", "\(date)T\(String(format: "%02d", 6 + hours)):00:00Z"), status: .created)
    }

    func testBookingOnApprovedVacationDayCountsAsOvertimeAndKeepsVacationConsumption() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-01-01"), status: .created)
            try await timeRequest(app, context, .POST, "absences", absenceBody(monday, kind: "vacation", status: "approved"), status: .created)
            let balanceBefore = try await account(app, context), usedBefore = try await usedVacation(app, context)
            let before = try await day(app, context, monday)
            XCTAssertEqual(before["mark"] as? String, "vacation"); XCTAssertEqual(before["targetSeconds"] as? Int, 0)
            XCTAssertEqual(before["deltaSeconds"] as? Int, 0)
            try await book(app, context, monday)
            let after = try await day(app, context, monday)
            XCTAssertEqual(after["mark"] as? String, "vacation", "the day stays a vacation day")
            XCTAssertEqual(after["targetSeconds"] as? Int, 0)
            XCTAssertEqual(after["evaluatedWorkSeconds"] as? Int, 21600)
            XCTAssertEqual(after["creditSeconds"] as? Int, 0)
            XCTAssertEqual(after["deltaSeconds"] as? Int, 21600, "booked time is overtime")
            let balanceAfter = try await account(app, context)
            XCTAssertEqual(balanceAfter - balanceBefore, 21600)
            let usedAfter = try await usedVacation(app, context)
            XCTAssertEqual(usedAfter, usedBefore, "the vacation day is still consumed")
            XCTAssertEqual(usedAfter, 2, "one full day = two half days")
            // Week view and statistics agree.
            let week = try object(await timeRequest(app, context, .GET, "time/weeks/2026-W37"))
            let days = try XCTUnwrap(week["days"] as? [[String: Any]])
            let row = try XCTUnwrap(days.first { $0["date"] as? String == monday })
            XCTAssertEqual(row["mark"] as? String, "vacation"); XCTAssertEqual(row["workSeconds"] as? Int, 21600); XCTAssertEqual(row["balanceSeconds"] as? Int, 21600)
            let stats = try object(await timeRequest(app, context, .GET, "time/statistics?from=\(monday)&to=\(monday)&granularity=day"))
            let totals = try XCTUnwrap(stats["totals"] as? [String: Any])
            XCTAssertEqual(totals["overtimeSeconds"] as? Int, 21600); XCTAssertEqual(totals["actualSeconds"] as? Int, 21600)
            XCTAssertEqual(totals["absenceDays"] as? Double, 1, "the day is still counted as a vacation day")
            // Removing the booking restores the previous balance.
            let segments = try XCTUnwrap(after["segments"] as? [[String: Any]])
            let segmentId = try XCTUnwrap(segments.first?["id"] as? String)
            try await timeRequest(app, context, .DELETE, "time/segments/\(segmentId)?reason=test", status: .noContent)
            let restored = try await account(app, context)
            XCTAssertEqual(restored, balanceBefore)
            try await AbsenceRecord.query(on: app.db).delete() // the revert of the kind migration cannot copy excused rows
        }
    }

    func testBookingOnHalfVacationDayReducesTheRemainingTarget() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-01-01"), status: .created)
            try await timeRequest(app, context, .POST, "absences", absenceBody("2026-09-08", kind: "vacation", status: "approved", first: true), status: .created)
            let balanceBefore = try await account(app, context), usedBefore = try await usedVacation(app, context)
            XCTAssertEqual(usedBefore, 1)
            let before = try await day(app, context, "2026-09-08")
            XCTAssertEqual(before["targetSeconds"] as? Int, 13860)
            try await book(app, context, "2026-09-08", hours: 4)
            let after = try await day(app, context, "2026-09-08")
            XCTAssertEqual(after["targetSeconds"] as? Int, 13860)
            XCTAssertEqual(after["evaluatedWorkSeconds"] as? Int, 14400)
            XCTAssertEqual(after["deltaSeconds"] as? Int, 14400 - 13860, "only the time above the remaining half-day target is overtime")
            let balanceAfter = try await account(app, context)
            XCTAssertEqual(balanceAfter - balanceBefore, 14400)
            let usedAfter = try await usedVacation(app, context)
            XCTAssertEqual(usedAfter, 1)
            try await AbsenceRecord.query(on: app.db).delete()
        }
    }

    func testBookingsOnOtherAbsenceKindsAndOpenRequestsAreAccepted() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-01-01"), status: .created)
            // Sick and excused days have no block either (no change made here; documented by the test).
            try await timeRequest(app, context, .POST, "absences", absenceBody("2026-09-09", kind: "sick", status: "recorded"), status: .created)
            try await timeRequest(app, context, .POST, "absences", absenceBody("2026-09-10", kind: "excused", status: "recorded"), status: .created)
            // Requested and planned vacation does not mark the day yet: normal workday with the full target.
            try await timeRequest(app, context, .POST, "absences", absenceBody("2026-09-11", kind: "vacation", status: "requested"), status: .created)
            // An explicit vacation mark without an absence behaves the same way.
            try await timeRequest(app, context, .PUT, "time/days/2026-09-14", ["mark": "vacation"])
            for date in ["2026-09-09", "2026-09-10", "2026-09-11", "2026-09-14"] { try await book(app, context, date) }
            for (date, mark, target, delta) in [("2026-09-09", "sick", 0, 21600), ("2026-09-10", "excused", 0, 21600), ("2026-09-11", "none", 27720, 21600 - 27720), ("2026-09-14", "vacation", 0, 21600)] {
                let value = try await day(app, context, date)
                XCTAssertEqual(value["mark"] as? String, mark, date); XCTAssertEqual(value["targetSeconds"] as? Int, target, date)
                XCTAssertEqual(value["deltaSeconds"] as? Int, delta, date)
            }
            try await AbsenceRecord.query(on: app.db).delete()
        }
    }

    func testTimerStartAndAutomationAreAcceptedOnAVacationDay() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-01-01"), status: .created)
            let today = vbToday().description
            try await timeRequest(app, context, .POST, "absences", absenceBody(today, kind: "vacation", status: "approved"), status: .created)
            let started = try object(await timeRequest(app, context, .POST, "time/timer/start", ["clientEventId": UUID().uuidString.lowercased()]))
            XCTAssertNotNil(started["id"])
            let stopped = try object(await timeRequest(app, context, .POST, "time/timer/stop", ["clientEventId": UUID().uuidString.lowercased()]))
            XCTAssertNotNil(stopped["endedAt"])
            let value = try await day(app, context, today)
            XCTAssertEqual(value["mark"] as? String, "vacation"); XCTAssertEqual(value["targetSeconds"] as? Int, 0)
            try await AbsenceRecord.query(on: app.db).delete()
        }
    }
}
