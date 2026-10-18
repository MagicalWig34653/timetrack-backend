import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// V2 (ADR-0025): GET /vacation/suggestions with real account data.
extension AuthTests {
    private func suggestions(_ app: Application, _ context: AuthContext, _ query: String, _ status: HTTPStatus = .ok) async throws -> XCTHTTPResponse {
        try await api(app, context, .GET, "vacation/suggestions?" + query, nil, status)
    }

    func scenarioVacationSuggestions(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        try await planningModel(app, context)
        try await api(app, context, .PUT, "vacation/settings", ["region": "DE-ST", "annualEntitlementHalfDays": 60, "carryOverByYear": [String: Int](), "carryOverExpiry": NSNull()])
        // Budget: 30 days, 2 booked (Mon+Tue 8/9 June), 1 planned.
        try await createAbsence(app, context, absenceBody("2026-06-08", "2026-06-09"))
        try await createAbsence(app, context, absenceBody("2026-06-15", status: "planned"))
        try await createAbsence(app, context, absenceBody("2026-05-22", kind: "sick"))
        try await api(app, context, .POST, "calendar/custom-days", ["kind": "school_holiday", "startDate": "2026-07-06", "endDate": "2026-07-17", "name": "Sommerferien"], .created)
        try await api(app, context, .PUT, "plan/days/2026-05-15", ["mode": "school"])
        try await api(app, context, .PUT, "plan/days/2026-05-22", ["mode": "office"])

        let body = try object(await suggestions(app, context, "from=2026-05-01&to=2026-07-31&limit=100&minDaysOff=4"))
        XCTAssertEqual(body["from"] as? String, "2026-05-01")
        let budget = try XCTUnwrap(body["budget"] as? [String: Any])
        XCTAssertEqual(budget["entitlementDays"] as? Double, 30); XCTAssertEqual(budget["takenDays"] as? Double, 2)
        XCTAssertEqual(budget["plannedDays"] as? Double, 1); XCTAssertEqual(budget["remainingDays"] as? Double, 27)
        let items = try XCTUnwrap(body["suggestions"] as? [[String: Any]])
        let bridge = try XCTUnwrap(items.first { ($0["vacationDates"] as? [String]) == ["2026-05-15"] })
        XCTAssertEqual(bridge["kind"] as? String, "bridge"); XCTAssertEqual(bridge["start"] as? String, "2026-05-14")
        XCTAssertEqual(bridge["totalDaysOff"] as? Int, 4); XCTAssertEqual(bridge["efficiency"] as? Double, 4)
        XCTAssertEqual(bridge["fitsBudget"] as? Bool, true); XCTAssertEqual(bridge["remainingAfter"] as? Double, 26)
        XCTAssertEqual((bridge["id"] as? String)?.count, 16)
        let conflicts = try XCTUnwrap(bridge["conflicts"] as? [[String: Any]])
        XCTAssertEqual(conflicts.compactMap { $0["type"] as? String }, ["school_day"])
        XCTAssertEqual(((bridge["holidays"] as? [[String: Any]])?.first?["name"]) as? String, "Christi Himmelfahrt")
        // Booked vacation is never recommended again; the sick day and planned work are marked, not hidden.
        XCTAssertFalse(items.contains { ($0["vacationDates"] as? [String] ?? []).contains("2026-06-08") })
        let whit = try XCTUnwrap(items.first { ($0["vacationDates"] as? [String]) == ["2026-05-22"] })
        XCTAssertEqual((whit["conflicts"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }, ["absence", "plan"])
        let school = items.filter { $0["kind"] as? String == "school_holiday_extension" }
        XCTAssertFalse(school.isEmpty)
        XCTAssertEqual(((school.first?["schoolHolidays"] as? [[String: Any]])?.first?["name"]) as? String, "Sommerferien")
        let limited = try object(await suggestions(app, context, "from=2026-05-01&to=2026-07-31&limit=2"))
        XCTAssertEqual((limited["suggestions"] as? [Any])?.count, 2)
        // Defaults: from today, until the end of next year.
        let defaults = try object(await suggestions(app, context, ""))
        let from = try XCTUnwrap(defaults["from"] as? String), to = try XCTUnwrap(defaults["to"] as? String)
        XCTAssertEqual(to, "\(try XCTUnwrap(Int(from.prefix(4))) + 1)-12-31")
        XCTAssertLessThanOrEqual((defaults["suggestions"] as? [Any])?.count ?? 0, 20)
    }

    func scenarioVacationSuggestionsValidation(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        for query in ["from=2026-06-01&to=2026-05-01", "from=bad", "from=2026-05-01&to=2026-06-01&maxVacationDays=0",
                      "from=2026-05-01&to=2026-06-01&maxVacationDays=61", "from=2026-05-01&to=2026-06-01&maxVacationDays=x",
                      "from=2026-05-01&to=2026-06-01&minDaysOff=0", "from=2026-05-01&to=2026-06-01&limit=0",
                      "from=2026-05-01&to=2026-06-01&limit=101", "from=1980-01-01&to=1980-02-01"] {
            _ = try await suggestions(app, context, query, .badRequest)
        }
        let tooLong = try await suggestions(app, context, "from=2026-01-01&to=2027-07-02", .badRequest)
        XCTAssertEqual(try errorCode(tooLong), "range_too_large")
        _ = try await suggestions(app, context, "from=2026-01-01&to=2027-07-01")   // exactly 18 months
        try await timeRequest(app, nil, .GET, "vacation/suggestions", status: .unauthorized)
    }

    func scenarioVacationSuggestionsIsolation(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, owner)
        try await planningModel(app, owner); try await planningModel(app, member)
        try await createAbsence(app, owner, absenceBody("2026-05-15"))
        try await api(app, owner, .POST, "calendar/custom-days", ["kind": "school_holiday", "startDate": "2026-05-04", "endDate": "2026-05-08", "name": "Privat"], .created)
        try await api(app, owner, .PUT, "plan/days/2026-05-22", ["mode": "school"])
        let foreign = try object(await suggestions(app, member, "from=2026-05-01&to=2026-05-31&limit=100"))
        let items = try XCTUnwrap(foreign["suggestions"] as? [[String: Any]])
        XCTAssertTrue(items.contains { ($0["vacationDates"] as? [String]) == ["2026-05-15"] }, "the owner's booking must not hide the day for another account")
        XCTAssertTrue(items.allSatisfy { ($0["conflicts"] as? [Any])?.isEmpty == true && ($0["schoolHolidays"] as? [Any])?.isEmpty == true })
        let budget = try XCTUnwrap(foreign["budget"] as? [String: Any])
        XCTAssertEqual(budget["takenDays"] as? Double, 0)
    }

    func vacationSuggestionScenarios() -> [Scenario] {
        [scenarioVacationSuggestions, scenarioVacationSuggestionsValidation, scenarioVacationSuggestionsIsolation]
    }
    func testVacationSuggestionsSQLite() async throws {
        for scenario in vacationSuggestionScenarios() { try await withApp(scenario) }
    }
    func testVacationSuggestionsMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"]
        for scenario in vacationSuggestionScenarios() { try await withApp(environment: environment, scenario) }
    }
}
