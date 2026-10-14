import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// Stage 3a: vacation, absences, calendar, plan days, shares and the day-evaluation integration.
extension AuthTests {
    typealias Scenario = (Application, AuthService) async throws -> Void

    func json(_ response: XCTHTTPResponse) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView))
    }
    func eq<T: Equatable>(_ actual: @autoclosure () async throws -> T, _ expected: @autoclosure () -> T,
                          file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await actual(); XCTAssertEqual(value, expected(), file: file, line: line)
    }
    func yes(_ actual: @autoclosure () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await actual(); XCTAssertTrue(value, file: file, line: line)
    }
    func no(_ actual: @autoclosure () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await actual(); XCTAssertFalse(value, file: file, line: line)
    }
    func list(_ response: XCTHTTPResponse) throws -> [[String: Any]] { try XCTUnwrap(json(response) as? [[String: Any]]) }
    func errorCode(_ response: XCTHTTPResponse) throws -> String? {
        ((try object(response))["error"] as? [String: Any])?["code"] as? String
    }
    @discardableResult
    func api(_ app: Application, _ context: AuthContext, _ method: HTTPMethod, _ path: String, _ body: [String: Any]? = nil,
             _ status: HTTPStatus = .ok, version: Int? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> XCTHTTPResponse {
        try await timeRequest(app, context, method, path, body, status: status, extra: version.map { ["If-Match": String($0)] } ?? [:], file: file, line: line)
    }
    func planningModel(_ app: Application, _ context: AuthContext, from: String = "2026-01-01") async throws {
        try await api(app, context, .POST, "work-models", modelBody(from), .created)
    }
    func absenceBody(_ start: String, _ end: String? = nil, kind: String = "vacation", status: String = "approved",
                     first: Bool = false, last: Bool = false, extra: [String: Any] = [:]) -> [String: Any] {
        ["kind": kind, "startDate": start, "endDate": end ?? start, "status": status, "halfDayStart": first, "halfDayEnd": last]
            .merging(extra) { _, new in new }
    }
    @discardableResult
    func createAbsence(_ app: Application, _ context: AuthContext, _ body: [String: Any]) async throws -> [String: Any] {
        try object(await api(app, context, .POST, "absences", body, .created))
    }
    func balance(_ app: Application, _ context: AuthContext, _ year: Int = 2026) async throws -> [String: Any] {
        try object(await api(app, context, .GET, "vacation/balance?year=\(year)"))
    }
    func second(_ app: Application, _ auth: AuthService, _ admin: AuthContext, handle: String = "member") async throws -> AuthContext {
        try await registered(auth, db: app.db, handle: handle, admin: admin).0
    }

    // MARK: Scenarios

    func scenarioVacationAccount(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        // Defaults before anything is stored.
        let defaults = try object(await api(app, context, .GET, "vacation/settings"))
        XCTAssertEqual(defaults["configured"] as? Bool, false); XCTAssertEqual(defaults["region"] as? String, "DE-ST")
        XCTAssertEqual(defaults["annualEntitlementHalfDays"] as? Int, 60)
        let saved = try object(await api(app, context, .PUT, "vacation/settings",
            ["region": "DE-ST", "annualEntitlementHalfDays": 60, "carryOverByYear": ["2026": 8], "carryOverExpiry": "03-31"]))
        XCTAssertEqual(saved["configured"] as? Bool, true); XCTAssertEqual((saved["carryOverByYear"] as? [String: Int])?["2026"], 8)
        try await api(app, context, .PUT, "vacation/settings", ["region": "XX", "annualEntitlementHalfDays": 60], .badRequest)
        try await api(app, context, .PUT, "vacation/settings", ["region": "DE-ST", "annualEntitlementHalfDays": -1], .badRequest)
        try await api(app, context, .PUT, "vacation/settings", ["region": "DE-ST", "annualEntitlementHalfDays": 60, "carryOverByYear": ["26": 1]], .badRequest)
        try await api(app, context, .PUT, "vacation/settings", ["region": "DE-ST", "annualEntitlementHalfDays": 60, "carryOverExpiry": "13-40"], .badRequest)
        try await planningModel(app, context)

        var value = try await balance(app, context)
        XCTAssertEqual(value["entitlementHalfDays"] as? Int, 60); XCTAssertEqual(value["carryOverHalfDays"] as? Int, 8)
        XCTAssertEqual(value["availableHalfDays"] as? Int, 68); XCTAssertTrue(value["snapshotDate"] is NSNull)

        // Approved -> taken must not count twice; a stale version is rejected.
        let vacation = try await createAbsence(app, context, absenceBody("2026-10-12", "2026-10-16"))
        XCTAssertEqual(vacation["countedHalfDays"] as? Int, 10); XCTAssertEqual(vacation["version"] as? Int, 1)
        value = try await balance(app, context)
        XCTAssertEqual(value["bookedHalfDays"] as? Int, 10); XCTAssertEqual(value["availableHalfDays"] as? Int, 58)
        let id = try XCTUnwrap(vacation["id"] as? String)
        let taken = try object(await api(app, context, .PUT, "absences/" + id, absenceBody("2026-10-12", "2026-10-16", status: "taken"), version: 1))
        XCTAssertEqual(taken["version"] as? Int, 2); XCTAssertEqual(taken["status"] as? String, "taken")
        value = try await balance(app, context)
        XCTAssertEqual(value["bookedHalfDays"] as? Int, 10); XCTAssertEqual(value["availableHalfDays"] as? Int, 58)
        let stale = try await api(app, context, .PUT, "absences/" + id, absenceBody("2026-10-12", "2026-10-16"), .preconditionFailed, version: 1)
        XCTAssertEqual(try errorCode(stale), "stale_version")
        try await api(app, context, .PUT, "absences/" + id, absenceBody("2026-10-12", "2026-10-16"), .badRequest)   // C10: If-Match is required

        // Planned and requested are previewed separately.
        try await createAbsence(app, context, absenceBody("2026-11-02", "2026-11-06", status: "planned"))
        try await createAbsence(app, context, absenceBody("2026-11-09", status: "requested", first: true))
        value = try await balance(app, context)
        XCTAssertEqual(value["plannedHalfDays"] as? Int, 11); XCTAssertEqual(value["availableHalfDays"] as? Int, 58)
        XCTAssertEqual(value["availableAfterPlannedHalfDays"] as? Int, 47)

        // Snapshot replaces entitlement and carry-over of its year (not added on top) and counts bookings from its date.
        let snapshot = try object(await api(app, context, .POST, "vacation/snapshots", ["date": "2026-10-01", "remainingHalfDays": 20], .created))
        XCTAssertEqual(snapshot["snapshotRemainingHalfDays"] as? Int, 20); XCTAssertEqual(snapshot["snapshotDate"] as? String, "2026-10-01")
        XCTAssertEqual(snapshot["entitlementHalfDays"] as? Int, 0); XCTAssertEqual(snapshot["carryOverHalfDays"] as? Int, 0)
        XCTAssertEqual(snapshot["availableHalfDays"] as? Int, 10)
        try await api(app, context, .POST, "vacation/snapshots", ["date": "2026-10-01", "remainingHalfDays": 5], .conflict)
        try await api(app, context, .POST, "vacation/snapshots", ["date": "2026-10-02", "remainingHalfDays": -1], .badRequest)
        let adjusted = try object(await api(app, context, .POST, "vacation/adjustments", ["date": "2026-10-20", "halfDays": 4, "reason": "Bonus"], .created))
        XCTAssertEqual(adjusted["adjustmentHalfDays"] as? Int, 4); XCTAssertEqual(adjusted["availableHalfDays"] as? Int, 14)
        try await api(app, context, .POST, "vacation/adjustments", ["date": "2026-10-20", "halfDays": 4, "reason": " "], .badRequest)
        let entries = try object(await api(app, context, .GET, "vacation/entries?year=2026"))
        let snapshots = try XCTUnwrap(entries["snapshots"] as? [[String: Any]]), adjustments = try XCTUnwrap(entries["adjustments"] as? [[String: Any]])
        XCTAssertEqual(snapshots.count, 1); XCTAssertEqual(adjustments.count, 1); XCTAssertEqual(adjustments[0]["reason"] as? String, "Bonus")
        try await eq(((try object(await api(app, context, .GET, "vacation/entries?year=2025")))["snapshots"] as? [Any])?.count, 0)
        // Folgejahr: normal entitlement again.
        let next = try await balance(app, context, 2027)
        XCTAssertEqual(next["entitlementHalfDays"] as? Int, 60); XCTAssertEqual(next["availableHalfDays"] as? Int, 60)
        try await api(app, context, .DELETE, "vacation/entries/" + (snapshots[0]["id"] as! String), nil, .noContent)
        try await api(app, context, .DELETE, "vacation/entries/" + (adjustments[0]["id"] as! String), nil, .noContent)
        try await api(app, context, .DELETE, "vacation/entries/" + (adjustments[0]["id"] as! String), nil, .notFound)
        value = try await balance(app, context)
        XCTAssertNil(value["snapshotRemainingHalfDays"] as? Int); XCTAssertEqual(value["availableHalfDays"] as? Int, 58)
        try await api(app, context, .GET, "vacation/balance?year=1800", nil, .badRequest)
        try await api(app, context, .GET, "vacation/balance", nil, .badRequest)
    }

    func scenarioAbsences(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        try await planningModel(app, context)
        let first = try await createAbsence(app, context, absenceBody("2026-10-12", "2026-10-16"))
        let id = try XCTUnwrap(first["id"] as? String)
        // Overlap (including touching edge days) is rejected for every active kind and status.
        for (kind, status) in [("vacation", "approved"), ("sick", "approved"), ("other", "planned")] {
            let response = try await api(app, context, .POST, "absences", absenceBody("2026-10-16", "2026-10-20", kind: kind, status: status), .conflict)
            XCTAssertEqual(try errorCode(response), "absence_overlap")
        }
        // Rejected/cancelled neither block nor count.
        let rejected = try await createAbsence(app, context, absenceBody("2026-10-14", status: "rejected"))
        XCTAssertEqual(rejected["countedHalfDays"] as? Int, 0)
        let cancelled = try await createAbsence(app, context, absenceBody("2026-10-13", status: "cancelled"))
        XCTAssertEqual(cancelled["countedHalfDays"] as? Int, 0)
        // Reactivating a rejected entry over the booked one conflicts.
        let rejectedId = try XCTUnwrap(rejected["id"] as? String)
        try await api(app, context, .PUT, "absences/" + rejectedId, absenceBody("2026-10-14", status: "approved"), .conflict, version: 1)
        // Sick and other: countedHalfDays is 0 and documents are kept for the owner.
        let sick = try await createAbsence(app, context, absenceBody("2026-10-19", "2026-10-20", kind: "sick",
            extra: ["note": "Flu", "documentStatus": "pending", "documentReferenceStart": "2026-10-19", "documentReferenceEnd": "2026-10-23"]))
        XCTAssertEqual(sick["countedHalfDays"] as? Int, 0); XCTAssertEqual(sick["documentStatus"] as? String, "pending")
        let other = try await createAbsence(app, context, absenceBody("2026-10-21", kind: "other", status: "planned"))
        XCTAssertEqual(other["countedHalfDays"] as? Int, 0)
        // Holidays and weekends count 0; half days halve; Christmas 2026: Wed, Thu, (Fri holiday), Mon.
        let christmas = try await createAbsence(app, context, absenceBody("2026-12-23", "2026-12-28"))
        XCTAssertEqual(christmas["countedHalfDays"] as? Int, 6)
        let half = try await createAbsence(app, context, absenceBody("2026-11-02", first: true))
        XCTAssertEqual(half["countedHalfDays"] as? Int, 1)
        let both = try await createAbsence(app, context, absenceBody("2026-11-09", "2026-11-10", first: true, last: true))
        XCTAssertEqual(both["countedHalfDays"] as? Int, 2)
        // GET by ID, list by range (overlap semantics), update and delete.
        let fetched = try object(await api(app, context, .GET, "absences/" + id)); try await eq(fetched["countedHalfDays"] as? Int, 10)
        try await eq(try list(await api(app, context, .GET, "absences?from=2026-10-16&to=2026-10-19")).count, 2)
        try await eq(try list(await api(app, context, .GET, "absences?from=2026-01-01&to=2026-01-31")).count, 0)
        try await api(app, context, .GET, "absences?from=2026-10-19&to=2026-10-01", nil, .badRequest)
        try await api(app, context, .POST, "absences", absenceBody("2026-10-30", "2026-10-29"), .badRequest)
        try await api(app, context, .POST, "absences", absenceBody("2026-10-30", extra: ["note": String(repeating: "x", count: 501)]), .badRequest)
        try await api(app, context, .POST, "absences", absenceBody("2026-10-30", extra: ["documentStatus": "bogus"]), .badRequest)
        try await api(app, context, .POST, "absences", ["kind": "vacation", "startDate": "2026-10-30"], .badRequest)
        try await api(app, context, .DELETE, "absences/" + id, nil, .noContent)
        try await api(app, context, .GET, "absences/" + id, nil, .notFound)
        try await api(app, context, .DELETE, "absences/" + id, nil, .notFound)
        // Freed range can be booked again.
        try await createAbsence(app, context, absenceBody("2026-10-12", "2026-10-16", status: "planned"))
        // Custom holidays reduce consumption.
        try await api(app, context, .POST, "calendar/custom-days", ["kind": "holiday", "startDate": "2026-11-23", "endDate": "2026-11-23", "name": "Bridge"], .created)
        try await eq(try await createAbsence(app, context, absenceBody("2026-11-23", "2026-11-24"))["countedHalfDays"] as? Int, 2)
    }

    func scenarioDayEvaluationIntegration(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        try await planningModel(app, context, from: "2026-10-05")
        func day(_ date: String) async throws -> [String: Any] { try object(await api(app, context, .GET, "time/days/" + date)) }
        let full = try await createAbsence(app, context, absenceBody("2026-10-05"))
        let sick = try await createAbsence(app, context, absenceBody("2026-10-06", kind: "sick"))
        try await createAbsence(app, context, absenceBody("2026-10-07", first: true))
        var vacationDay = try await day("2026-10-05")
        XCTAssertEqual(vacationDay["mark"] as? String, "vacation"); XCTAssertEqual(vacationDay["markSource"] as? String, "absence")
        XCTAssertEqual(vacationDay["targetSeconds"] as? Int, 0); XCTAssertEqual(vacationDay["deltaSeconds"] as? Int, 0)
        XCTAssertTrue(vacationDay["targetOverrideSeconds"] is NSNull)
        try await eq(try await day("2026-10-06")["mark"] as? String, "sick"); try await eq(try await day("2026-10-06")["targetSeconds"] as? Int, 0)
        let halfDay = try await day("2026-10-07")
        XCTAssertEqual(halfDay["mark"] as? String, "vacation"); XCTAssertEqual(halfDay["targetSeconds"] as? Int, 13860)
        XCTAssertEqual(halfDay["targetOverrideSeconds"] as? Int, 13860); XCTAssertEqual(halfDay["deltaSeconds"] as? Int, -13860)
        // Planned/requested/rejected/cancelled/other do not change the evaluation.
        for (index, status) in ["planned", "requested", "rejected", "cancelled"].enumerated() {
            let date = "2026-10-\(12 + index)"
            try await createAbsence(app, context, absenceBody(date, status: status))
            let evaluation = try await day(date)
            XCTAssertEqual(evaluation["mark"] as? String, "none", status); XCTAssertEqual(evaluation["targetSeconds"] as? Int, 27720, status)
            XCTAssertEqual(evaluation["markSource"] as? String, "none")
        }
        try await createAbsence(app, context, absenceBody("2026-10-16", kind: "other", status: "approved"))
        try await eq(try await day("2026-10-16")["targetSeconds"] as? Int, 27720)
        // Holiday on a workday (Friday 2026-12-25) wins over a vacation or sick absence; neighbours stay vacation.
        try await createAbsence(app, context, absenceBody("2026-12-24", "2026-12-25"))
        let holiday = try await day("2026-12-25")
        XCTAssertEqual(holiday["mark"] as? String, "holiday"); XCTAssertEqual(holiday["markSource"] as? String, "holiday")
        XCTAssertEqual(holiday["targetSeconds"] as? Int, 0)
        try await eq(try await day("2026-12-24")["markSource"] as? String, "absence")
        try await createAbsence(app, context, absenceBody("2026-12-28", kind: "sick"))
        try await eq(try await day("2026-12-28")["mark"] as? String, "sick")
        try await api(app, context, .POST, "calendar/custom-days", ["kind": "holiday", "startDate": "2026-12-28", "endDate": "2026-12-28", "name": "Own"], .created)
        try await eq(try await day("2026-12-28")["mark"] as? String, "holiday")
        // A holiday on a non-workday is not marked; school holidays are only context.
        try await eq(try await day("2026-10-31")["mark"] as? String, "none")
        try await api(app, context, .POST, "calendar/custom-days", ["kind": "school_holiday", "startDate": "2026-10-19", "endDate": "2026-10-23", "name": "Break"], .created)
        try await eq(try await day("2026-10-19")["targetSeconds"] as? Int, 27720)
        // Explicit marks win over absences and holidays; removing them restores the automatic mark.
        try await api(app, context, .PUT, "time/days/2026-10-05", ["mark": "school_credit", "creditSeconds": 3600])
        vacationDay = try await day("2026-10-05")
        XCTAssertEqual(vacationDay["markSource"] as? String, "explicit"); XCTAssertEqual(vacationDay["mark"] as? String, "school_credit")
        try await api(app, context, .PUT, "time/days/2026-10-05", ["mark": "none"])
        try await eq(try await day("2026-10-05")["markSource"] as? String, "absence")
        try await api(app, context, .PUT, "time/days/2026-12-25", ["mark": "vacation"])
        try await eq(try await day("2026-12-25")["markSource"] as? String, "explicit")
        // Actual work on a vacation day is preserved and never produces a negative delta.
        try await createAbsence(app, context, absenceBody("2026-10-26"))
        try await api(app, context, .POST, "time/segments", segmentBody("2026-10-26T06:00:00Z", "2026-10-26T08:00:00Z"), .created)
        let worked = try await day("2026-10-26")
        XCTAssertEqual(worked["rawWorkSeconds"] as? Int, 7200); XCTAssertEqual(worked["targetSeconds"] as? Int, 0)
        XCTAssertEqual(worked["deltaSeconds"] as? Int, 7200)
        // Time account: Oct 5 vacation 0, Oct 6 sick 0, Oct 7 half day -13860, Oct 8..9 plain -27720 each.
        let account = try object(await api(app, context, .GET, "time/account?asOf=2026-10-09"))
        XCTAssertEqual(account["balanceSeconds"] as? Int, -69300)
        // Planned absences leave the account untouched; deleting the booked ones restores the full deficit.
        for absence in [full, sick] { try await api(app, context, .PUT, "absences/" + (absence["id"] as! String), absenceBody(absence["startDate"] as! String, kind: absence["kind"] as! String, status: "planned"), version: 1) }
        let after = try object(await api(app, context, .GET, "time/account?asOf=2026-10-09"))
        XCTAssertEqual(after["balanceSeconds"] as? Int, -69300 - 2 * 27720)
        // time/days keeps its 93-day limit.
        try await api(app, context, .GET, "time/days?from=2026-10-01&to=2026-12-31")
        let tooLarge = try await api(app, context, .GET, "time/days?from=2026-10-01&to=2027-01-02", nil, .badRequest)
        XCTAssertEqual(try errorCode(tooLarge), "range_too_large")
    }

    func scenarioCalendarAndPlan(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let holidays = try list(await api(app, context, .GET, "calendar/holidays?year=2026"))
        func has(_ rows: [[String: Any]], _ date: String) -> Bool { rows.contains { $0["startDate"] as? String == date } }
        XCTAssertTrue(has(holidays, "2026-10-31")); XCTAssertTrue(has(holidays, "2026-04-03")); XCTAssertTrue(holidays.allSatisfy { $0["source"] as? String == "builtin" })
        XCTAssertTrue(holidays.allSatisfy { $0["id"] is NSNull })
        try await no(has(try list(await api(app, context, .GET, "calendar/holidays?year=2026&region=DE-BY")), "2026-10-31"))
        try await api(app, context, .GET, "calendar/holidays?year=2026&region=XX", nil, .badRequest)
        try await api(app, context, .GET, "calendar/holidays", nil, .badRequest)
        // Configured region is the default.
        try await api(app, context, .PUT, "vacation/settings", ["region": "DE-BY", "annualEntitlementHalfDays": 60])
        try await no(has(try list(await api(app, context, .GET, "calendar/holidays?year=2026")), "2026-10-31"))
        // Custom days: school holidays are only custom entries.
        let custom = try object(await api(app, context, .POST, "calendar/custom-days", ["kind": "school_holiday", "startDate": "2026-07-01", "endDate": "2026-08-12", "name": "Sommerferien"], .created))
        XCTAssertEqual(custom["source"] as? String, "custom"); XCTAssertNotNil(custom["id"] as? String)
        let merged = try list(await api(app, context, .GET, "calendar/holidays?year=2026"))
        XCTAssertTrue(merged.contains { $0["kind"] as? String == "school_holiday" })
        try await eq(try list(await api(app, context, .GET, "calendar/holidays?year=2027")).filter { $0["source"] as? String == "custom" }.count, 0)
        try await api(app, context, .POST, "calendar/custom-days", ["kind": "holiday", "startDate": "2026-07-02", "endDate": "2026-07-01", "name": "Bad"], .badRequest)
        try await api(app, context, .POST, "calendar/custom-days", ["kind": "holiday", "startDate": "2026-07-01", "endDate": "2026-07-01", "name": ""], .badRequest)
        try await api(app, context, .POST, "calendar/custom-days", ["kind": "other", "startDate": "2026-07-01", "endDate": "2026-07-01", "name": "X"], .badRequest)
        try await api(app, context, .DELETE, "calendar/custom-days/" + (custom["id"] as! String), nil, .noContent)
        try await api(app, context, .DELETE, "calendar/custom-days/" + (custom["id"] as! String), nil, .notFound)

        // Plan days.
        let place = try resourceID(await api(app, context, .POST, "places", placeBody(), .created))
        let plan = try object(await api(app, context, .PUT, "plan/days/2026-10-12", ["mode": "office", "placeId": place, "note": "Private"]))
        XCTAssertEqual(plan["mode"] as? String, "office"); XCTAssertEqual(plan["note"] as? String, "Private"); XCTAssertEqual(plan["date"] as? String, "2026-10-12")
        try await eq(try object(await api(app, context, .PUT, "plan/days/2026-10-12", ["mode": "home"]))["mode"] as? String, "home")
        try await api(app, context, .PUT, "plan/days/2026-10-13", ["mode": "off"])
        try await eq(try list(await api(app, context, .GET, "plan/days?from=2026-10-12&to=2026-10-13")).count, 2)
        try await eq(try list(await api(app, context, .GET, "plan/days?from=2026-10-13&to=2026-10-13")).count, 1)
        try await api(app, context, .PUT, "plan/days/2026-10-14", ["mode": "bogus"], .badRequest)
        try await api(app, context, .PUT, "plan/days/2026-10-14", ["mode": "home", "note": String(repeating: "x", count: 201)], .badRequest)
        try await api(app, context, .PUT, "plan/days/2026-10-14", ["mode": "home", "placeId": UUID().uuidString], .notFound)
        try await api(app, context, .PUT, "plan/days/2026-02-30", ["mode": "home"], .badRequest)
        try await api(app, context, .DELETE, "plan/days/2026-10-12", nil, .noContent)
        try await api(app, context, .DELETE, "plan/days/2026-10-12", nil, .noContent)
        try await eq(try list(await api(app, context, .GET, "plan/days?from=2026-10-01&to=2026-10-31")).count, 1)
        // Unique key per account and date at the database level.
        let duplicate = PlanDayRecord(); duplicate.accountId = try context.account.requireID(); duplicate.date = "2026-10-13"; duplicate.mode = "home"
        do { try await duplicate.create(on: app.db); XCTFail("Expected plan day uniqueness") } catch {}
    }

    func scenarioRangeLimits(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        for path in ["absences", "plan/days"] {
            try await api(app, context, .GET, "\(path)?from=2026-01-01&to=2027-01-01")
            let response = try await api(app, context, .GET, "\(path)?from=2026-01-01&to=2027-01-02", nil, .badRequest)
            XCTAssertEqual(try errorCode(response), "range_too_large")
        }
        let member = try await second(app, auth, context)
        let share = try object(await api(app, context, .POST, "shares", ["recipientHandle": "member", "scopes": ["plan": true]], .created))
        let path = "shares/incoming/\(share["id"] as! String)/view"
        try await api(app, member, .GET, "\(path)?from=2026-01-01&to=2027-01-01")
        try await eq(try errorCode(await api(app, member, .GET, "\(path)?from=2026-01-01&to=2027-01-02", nil, .badRequest)), "range_too_large")
        try await api(app, member, .GET, "\(path)?from=2026-02-01&to=2026-01-01", nil, .badRequest)
        try await api(app, member, .GET, "\(path)?from=2026-02-01", nil, .badRequest)
    }

    func scenarioAccountIsolation(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        let other = try await second(app, auth, owner)
        let third = try await second(app, auth, owner, handle: "third")
        try await planningModel(app, owner); try await planningModel(app, other)
        let absence = try await createAbsence(app, owner, absenceBody("2026-10-12", "2026-10-14"))
        let absenceId = absence["id"] as! String
        let custom = try object(await api(app, owner, .POST, "calendar/custom-days", ["kind": "holiday", "startDate": "2026-11-23", "endDate": "2026-11-23", "name": "Own"], .created))
        let snapshot = try object(await api(app, owner, .POST, "vacation/snapshots", ["date": "2026-10-01", "remainingHalfDays": 10], .created))
        _ = snapshot
        let entries = try object(await api(app, owner, .GET, "vacation/entries?year=2026"))
        let entryId = ((entries["snapshots"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
        try await api(app, owner, .PUT, "plan/days/2026-10-12", ["mode": "home"])
        let share = try object(await api(app, owner, .POST, "shares", ["recipientHandle": "member", "scopes": ["plan": true, "actual": true, "vacation": true]], .created))
        let shareId = share["id"] as! String

        // Direct ID access with another account is always 404 and never changes anything.
        try await api(app, other, .GET, "absences/" + absenceId, nil, .notFound)
        try await api(app, other, .PUT, "absences/" + absenceId, absenceBody("2026-10-12", "2026-10-14", status: "cancelled"), .notFound, version: 1)
        try await api(app, other, .DELETE, "absences/" + absenceId, nil, .notFound)
        try await api(app, other, .DELETE, "vacation/entries/" + entryId, nil, .notFound)
        try await api(app, other, .DELETE, "calendar/custom-days/" + (custom["id"] as! String), nil, .notFound)
        try await api(app, other, .PATCH, "shares/" + shareId, ["scopes": ["plan": false]], .notFound)   // recipient is not the owner
        try await api(app, other, .DELETE, "shares/" + shareId, nil, .notFound)
        try await api(app, third, .PATCH, "shares/" + shareId, ["scopes": ["plan": false]], .notFound)
        try await api(app, third, .DELETE, "shares/" + shareId, nil, .notFound)
        try await api(app, third, .GET, "shares/incoming/\(shareId)/view?from=2026-10-01&to=2026-10-31", nil, .notFound)
        try await api(app, owner, .GET, "shares/incoming/\(shareId)/view?from=2026-10-01&to=2026-10-31", nil, .notFound)
        try await api(app, other, .GET, "shares/incoming/\(UUID())/view?from=2026-10-01&to=2026-10-31", nil, .notFound)
        try await eq(try list(await api(app, third, .GET, "shares/incoming")).count, 0)
        try await eq(try list(await api(app, third, .GET, "shares")).count, 0)
        try await eq(try list(await api(app, other, .GET, "shares")).count, 0)
        try await eq(try list(await api(app, other, .GET, "absences?from=2026-01-01&to=2026-12-31")).count, 0)
        try await eq(try list(await api(app, other, .GET, "plan/days?from=2026-01-01&to=2026-12-31")).count, 0)
        try await eq(try list(await api(app, other, .GET, "calendar/holidays?year=2026")).filter { $0["source"] as? String == "custom" }.count, 0)
        try await eq((try object(await api(app, other, .GET, "vacation/entries?year=2026"))["snapshots"] as? [Any])?.count, 0)
        try await eq(try await balance(app, other)["availableHalfDays"] as? Int, 60)
        // Another account's evaluation is unaffected by the owner's absence.
        try await eq(try object(await api(app, other, .GET, "time/days/2026-10-12"))["mark"] as? String, "none")
        // Another account's place cannot be referenced from a plan day.
        let place = try resourceID(await api(app, owner, .POST, "places", placeBody(), .created))
        try await api(app, other, .PUT, "plan/days/2026-10-12", ["mode": "office", "placeId": place], .notFound)
        // The owner's data is untouched.
        try await eq(try object(await api(app, owner, .GET, "absences/" + absenceId))["status"] as? String, "approved")
        try await eq(try list(await api(app, owner, .GET, "shares")).count, 1)
    }

    func scenarioShareLifecycle(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db, handle: "owner")
        let member = try await second(app, auth, owner)
        try await planningModel(app, owner, from: "2026-10-05")
        // Owner data containing everything that must never reach the recipient.
        let place = try resourceID(await api(app, owner, .POST, "places", placeBody(), .created))
        try await api(app, owner, .PUT, "plan/days/2026-10-12", ["mode": "customer", "placeId": place, "note": "TopSecretPlanNote"])
        var segment = segmentBody("2026-10-12T06:07:00Z", "2026-10-12T10:00:00Z"); segment["placeId"] = place; segment["note"] = "TopSecretSegmentNote"
        try await api(app, owner, .POST, "time/segments", segment, .created)
        try await createAbsence(app, owner, absenceBody("2026-10-19", "2026-10-20", extra: ["note": "TopSecretVacationNote"]))
        try await createAbsence(app, owner, absenceBody("2026-10-21", status: "taken"))
        try await createAbsence(app, owner, absenceBody("2026-10-22", "2026-10-23", status: "planned"))
        try await createAbsence(app, owner, absenceBody("2026-10-26", kind: "sick", extra: ["note": "TopSecretSick", "documentStatus": "submitted"]))
        try await createAbsence(app, owner, absenceBody("2026-10-27", kind: "other"))
        let view = "from=2026-10-01&to=2026-10-31"

        // Self-share, unknown recipient, duplicate.
        try await eq(try errorCode(await api(app, owner, .POST, "shares", ["recipientHandle": "owner", "scopes": ["plan": true]], .badRequest)), "cannot_share_with_self")
        try await eq(try errorCode(await api(app, owner, .POST, "shares", ["recipientHandle": "nobody", "scopes": ["plan": true]], .notFound)), "recipient_not_found")
        try await api(app, owner, .POST, "shares", ["scopes": ["plan": true]], .badRequest)

        // Default shares nothing: an empty scope set yields an empty view object.
        let created = try object(await api(app, owner, .POST, "shares", ["recipientHandle": "member", "scopes": [:]], .created))
        let id = created["id"] as! String
        XCTAssertEqual(created["recipientHandle"] as? String, "member")
        try await eq(try errorCode(await api(app, owner, .POST, "shares", ["recipientHandle": "member", "scopes": ["plan": true]], .conflict)), "share_exists")
        let incoming = try list(await api(app, member, .GET, "shares/incoming"))
        XCTAssertEqual(incoming.count, 1); XCTAssertEqual(incoming[0]["ownerDisplayName"] as? String, "Test")
        XCTAssertEqual((incoming[0]["scopes"] as? [String: Bool])?.values.filter { $0 }.count, 0)
        let path = "shares/incoming/\(id)/view?\(view)"
        var body = try await api(app, member, .GET, path).body.string
        XCTAssertEqual(body, "{}")

        // Scopes are separate.
        func keys(_ scopes: [String: Bool]) async throws -> Set<String> {
            try await api(app, owner, .PATCH, "shares/" + id, ["scopes": scopes])
            return Set(try object(await api(app, member, .GET, path)).keys)
        }
        let planOnly = try await keys(["plan": true]); try await eq(planOnly, ["plan"])
        let actualOnly = try await keys(["actual": true]); try await eq(actualOnly, ["actual"])
        let vacationOnly = try await keys(["vacation": true]); try await eq(vacationOnly, ["vacation"])
        let all = try await keys(["plan": true, "actual": true, "vacation": true]); try await eq(all, ["plan", "actual", "vacation"])

        // Whitelisted contents only.
        let full = try object(await api(app, member, .GET, path))
        let plan = try XCTUnwrap(full["plan"] as? [[String: Any]])
        XCTAssertEqual(plan.count, 1); XCTAssertEqual(Set(plan[0].keys), ["date", "mode"]); XCTAssertEqual(plan[0]["mode"] as? String, "customer")
        let actual = try XCTUnwrap(full["actual"] as? [[String: Any]])
        XCTAssertEqual(actual.count, 1, "only days with work")
        XCTAssertEqual(Set(actual[0].keys), ["date", "evaluatedStart", "evaluatedEnd", "evaluatedWorkSeconds"])
        XCTAssertEqual(actual[0]["date"] as? String, "2026-10-12"); XCTAssertEqual(actual[0]["evaluatedWorkSeconds"] as? Int, 14_400)
        let vacation = try XCTUnwrap(full["vacation"] as? [[String: Any]])
        XCTAssertEqual(vacation.map { $0["startDate"] as? String }, ["2026-10-19", "2026-10-21"]); XCTAssertEqual(vacation.map { $0["endDate"] as? String }, ["2026-10-20", "2026-10-21"])
        XCTAssertTrue(vacation.allSatisfy { Set($0.keys) == ["startDate", "endDate"] })
        body = try await api(app, member, .GET, path).body.string
        for forbidden in ["TopSecret", place, "note", "placeId", "sick", "document", "segments", "segmentIds", "halfDay", "status", "kind", "2026-10-26", "2026-10-27", "2026-10-22", "countedHalfDays"] {
            XCTAssertFalse(body.contains(forbidden), "leaked \(forbidden): \(body)")
        }
        // Clipped to the requested range.
        let clipped = try object(await api(app, member, .GET, "shares/incoming/\(id)/view?from=2026-10-20&to=2026-10-21"))
        XCTAssertEqual((clipped["vacation"] as? [[String: Any]])?.map { $0["startDate"] as? String }, ["2026-10-20", "2026-10-21"])
        // Incoming list never exposes the owner's handle or other detail.
        try await eq(Set(try list(await api(app, member, .GET, "shares/incoming"))[0].keys), ["id", "ownerDisplayName", "scopes"])
        let outgoing = try list(await api(app, owner, .GET, "shares")); try await eq(outgoing.count, 1)

        // Revoke is immediate; revoked shares are gone for both sides.
        try await api(app, owner, .DELETE, "shares/" + id, nil, .noContent)
        try await api(app, member, .GET, path, nil, .notFound)
        try await eq(try list(await api(app, member, .GET, "shares/incoming")).count, 0)
        try await eq(try list(await api(app, owner, .GET, "shares")).count, 0)
        try await api(app, owner, .DELETE, "shares/" + id, nil, .notFound)
        try await api(app, owner, .PATCH, "shares/" + id, ["scopes": ["plan": true]], .notFound)
        // A new share after revoking is allowed; the old ID stays dead.
        let again = try object(await api(app, owner, .POST, "shares", ["recipientHandle": "member", "scopes": ["vacation": true]], .created))
        XCTAssertNotEqual(again["id"] as? String, id)
        try await api(app, member, .GET, path, nil, .notFound)
        try await eq(Set(try object(await api(app, member, .GET, "shares/incoming/\(again["id"] as! String)/view?\(view)")).keys), ["vacation"])
        // The reverse direction is independent: the recipient owns no share to the owner.
        try await api(app, member, .GET, "shares/incoming/\(again["id"] as! String)/view?\(view)")
        try await eq(try list(await api(app, owner, .GET, "shares/incoming")).count, 0)
        // Database guard: one active share per owner/recipient pair, self-shares impossible.
        let row = ShareRecord(); row.ownerId = try owner.account.requireID(); row.recipientId = try member.account.requireID()
        row.scopePlan = false; row.scopeActual = false; row.scopeVacation = false; row.createdAt = Date(); row.active = 1
        do { try await row.create(on: app.db); XCTFail("Expected active share uniqueness") } catch {}
        let selfRow = ShareRecord(); selfRow.ownerId = row.ownerId; selfRow.recipientId = row.ownerId
        selfRow.scopePlan = false; selfRow.scopeActual = false; selfRow.scopeVacation = false; selfRow.createdAt = Date(); selfRow.active = 1
        do { try await selfRow.create(on: app.db); XCTFail("Expected self-share check") } catch {}
    }

    func scenarioSessionRules(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        try await timeRequest(app, nil, .GET, "vacation/settings", status: .unauthorized)
        try await timeRequest(app, nil, .GET, "absences?from=2026-01-01&to=2026-01-02", status: .unauthorized)
        // Writes need the CSRF header.
        var head = headers(context, csrf: false); head.contentType = .json
        let blocked = try await app.testable().sendRequest(.POST, "/api/v1/absences", headers: head,
            body: ByteBuffer(data: JSONSerialization.data(withJSONObject: absenceBody("2026-10-12"))))
        XCTAssertEqual(blocked.status, .forbidden); XCTAssertEqual(try errorCode(blocked), "csrf_invalid")
        // Recovery sessions are restricted for all planning routes.
        let token = Secrets.token()
        try await Session(accountId: context.account.requireID(), tokenHash: Secrets.hash(token), csrfTokenHash: Secrets.hash(Secrets.csrf(token)),
                          recovery: true, createdAt: Date(), expiresAt: Date().addingTimeInterval(600)).create(on: app.db)
        let stored = try await Session.query(on: app.db).filter(\.$tokenHash == Secrets.hash(token)).first()
        let recovery = AuthContext(session: try XCTUnwrap(stored), account: context.account, token: token)
        for path in ["vacation/settings", "vacation/balance?year=2026", "absences?from=2026-01-01&to=2026-01-02", "calendar/holidays?year=2026",
                     "plan/days?from=2026-01-01&to=2026-01-02", "shares", "shares/incoming"] {
            let response = try await api(app, recovery, .GET, path, nil, .forbidden)
            XCTAssertEqual(try errorCode(response), "recovery_session_restricted")
        }
        let response = try await api(app, recovery, .POST, "shares", ["recipientHandle": "x", "scopes": [:]], .forbidden)
        XCTAssertEqual(try errorCode(response), "recovery_session_restricted")
        // Device tokens never reach planning routes.
        var bearer: HTTPHeaders = ["Authorization": "Bearer " + Secrets.token()]
        bearer.contentType = .json
        let device = try await app.testable().sendRequest(.GET, "/api/v1/absences?from=2026-01-01&to=2026-01-02", headers: bearer)
        XCTAssertEqual(device.status, .unauthorized)
    }

    // MARK: Entry points

    func testPlanningSQLite() async throws {
        let scenarios: [Scenario] = [scenarioVacationAccount, scenarioAbsences, scenarioDayEvaluationIntegration, scenarioCalendarAndPlan,
                                     scenarioRangeLimits, scenarioAccountIsolation, scenarioShareLifecycle, scenarioSessionRules]
        for scenario in scenarios { try await withApp(scenario) }
    }
    func testPlanningTablesExistAndRevert() async throws {
        try await withApp { app, _ in
            let sql = try requireSQL(app.db)
            for table in ["vacation_settings", "vacation_snapshots", "vacation_adjustments", "absences", "custom_calendar_days", "plan_days", "shares"] {
                _ = try await sql.raw("SELECT COUNT(*) AS n FROM \(unsafeRaw: table)").first()
            }
        }
    }
    func testMariaDBPlanning() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"]
        let scenarios: [Scenario] = [scenarioVacationAccount, scenarioAbsences, scenarioDayEvaluationIntegration, scenarioCalendarAndPlan,
                                     scenarioRangeLimits, scenarioAccountIsolation, scenarioShareLifecycle, scenarioSessionRules]
        for scenario in scenarios { try await withApp(environment: environment, scenario) }
    }
}
