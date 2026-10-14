import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// C10: regression tests for the confirmed defects of the independent C9 review.
extension AuthTests {
    func scenarioC10Limits(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        try await planningModel(app, context)
        let settings: [String: Any] = ["region": "DE-ST", "annualEntitlementHalfDays": 60]
        // Overflow repro: a huge carry-over used to be stored and then trapped the whole process on balance.
        try await api(app, context, .PUT, "vacation/settings", settings.merging(["carryOverByYear": ["2026": 9_223_372_036_854_775_807]]) { $1 }, .badRequest)
        try await api(app, context, .PUT, "vacation/settings", settings.merging(["carryOverByYear": ["2026": 100_001]]) { $1 }, .badRequest)
        try await api(app, context, .PUT, "vacation/settings", ["region": "DE-ST", "annualEntitlementHalfDays": 100_001], .badRequest)
        try await api(app, context, .PUT, "vacation/settings", ["region": "DE-ST", "annualEntitlementHalfDays": 9_223_372_036_854_775_807], .badRequest)
        try await api(app, context, .PUT, "vacation/settings", settings.merging(["carryOverByYear": ["2026": 100_000]]) { $1 })
        let maxed = try await balance(app, context)
        try await eq(maxed["carryOverHalfDays"] as? Int, 100_000)
        try await api(app, context, .POST, "vacation/snapshots", ["date": "2026-10-02", "remainingHalfDays": 9_223_372_036_854_775_807], .badRequest)
        try await api(app, context, .POST, "vacation/snapshots", ["date": "2026-10-02", "remainingHalfDays": 100_001], .badRequest)
        try await api(app, context, .POST, "vacation/snapshots", ["date": "2026-10-02", "remainingHalfDays": 100_000], .created)
        try await api(app, context, .POST, "vacation/adjustments", ["date": "2026-10-20", "halfDays": 9_223_372_036_854_775_807, "reason": "x"], .badRequest)
        _ = try await balance(app, context)
        // Credit and account adjustments are bounded as well.
        try await api(app, context, .PUT, "time/days/2026-10-05", ["mark": "school_credit", "creditSeconds": 9_223_372_036_854_775_807], .badRequest)
        try await api(app, context, .PUT, "time/days/2026-10-05", ["mark": "school_credit", "creditSeconds": 86_401], .badRequest)
        try await api(app, context, .PUT, "time/days/2026-10-05", ["mark": "school_credit", "creditSeconds": 86_400])
        try await api(app, context, .POST, "time/account/adjustments", ["kind": "correction", "date": "2026-10-05", "seconds": 9_223_372_036_854_775_807, "reason": "x"], .badRequest)
        try await api(app, context, .GET, "time/account")
    }

    func scenarioC10ModelEnd(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let model = try object(await api(app, context, .POST, "work-models", modelBody("2026-01-01"), .created))
        let modelId = try XCTUnwrap(model["id"] as? String)
        let early = try await createAbsence(app, context, absenceBody("2026-10-12", "2026-10-16"))
        try await eq(early["countedHalfDays"] as? Int, 10)
        try await api(app, context, .PATCH, "work-models/" + modelId, ["validTo": "2026-10-31"])
        let after = try await balance(app, context)
        try await eq(after["bookedHalfDays"] as? Int, 10)
        let late = try await createAbsence(app, context, absenceBody("2026-11-02", "2026-11-04"))
        try await eq(late["countedHalfDays"] as? Int, 0)
        let id = try XCTUnwrap(late["id"] as? String)
        let updated = try object(await api(app, context, .PUT, "absences/" + id, absenceBody("2026-11-02", "2026-11-05"), version: 1))
        try await eq(updated["countedHalfDays"] as? Int, 0)
        // Spanning the end counts only the days inside the model.
        let spanning = try await createAbsence(app, context, absenceBody("2026-10-29", "2026-11-01"))
        try await eq(spanning["countedHalfDays"] as? Int, 4)
        try await eq(try object(await api(app, context, .GET, "absences/" + id))["countedHalfDays"] as? Int, 0)
        try await eq(try object(await api(app, context, .GET, "absences/" + (early["id"] as! String)))["countedHalfDays"] as? Int, 10)
        try await eq(try await balance(app, context)["bookedHalfDays"] as? Int, 14)
    }

    func scenarioC10Minor(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        try await planningModel(app, context)
        // If-Match is required on PUT absences; weak and quoted forms are normalised.
        let created = try await createAbsence(app, context, absenceBody("2026-10-12"))
        let id = try XCTUnwrap(created["id"] as? String)
        let missing = try await api(app, context, .PUT, "absences/" + id, absenceBody("2026-10-12"), .badRequest)
        try await eq(try errorCode(missing), "bad_request")
        let weak = try await timeRequest(app, context, .PUT, "absences/" + id, absenceBody("2026-10-12"), status: .ok, extra: ["If-Match": "W/\"1\""])
        try await eq(try object(weak)["version"] as? Int, 2)
        try await timeRequest(app, context, .PUT, "absences/" + id, absenceBody("2026-10-12"), status: .ok, extra: ["If-Match": "\"2\""])
        try await timeRequest(app, context, .PUT, "absences/" + id, absenceBody("2026-10-12"), status: .preconditionFailed, extra: ["If-Match": "W/\"2\""])
        // Limits count unicode scalars: 100 x "e + combining acute" is 100 graphemes but 200 scalars.
        let combining = String(repeating: "e\u{301}", count: 100), tooLong = String(repeating: "e\u{301}", count: 101)
        try await api(app, context, .PUT, "plan/days/2026-10-14", ["mode": "home", "note": combining])
        try await api(app, context, .PUT, "plan/days/2026-10-14", ["mode": "home", "note": tooLong], .badRequest)
        try await api(app, context, .POST, "vacation/adjustments", ["date": "2026-10-20", "halfDays": 2, "reason": tooLong], .badRequest)
        let name = String(repeating: "e\u{301}", count: 41)   // 82 scalars > 80
        try await api(app, context, .POST, "calendar/custom-days", ["kind": "holiday", "startDate": "2026-07-01", "endDate": "2026-07-01", "name": name], .badRequest)
        try await api(app, context, .POST, "calendar/custom-days", ["kind": "holiday", "startDate": "2026-07-01", "endDate": "2026-07-01", "name": String(name.dropLast())], .created)
        try await api(app, context, .POST, "absences", absenceBody("2026-10-30", extra: ["note": String(repeating: "e\u{301}", count: 251)]), .badRequest)
        try await api(app, context, .POST, "absences", absenceBody("2026-10-30", extra: ["note": String(repeating: "e\u{301}", count: 250)]), .created)
        // Archived places behave like foreign ones for plan days.
        let place = try object(await api(app, context, .POST, "places", placeBody(), .created))
        let placeId = try XCTUnwrap(place["id"] as? String)
        try await api(app, context, .PUT, "plan/days/2026-10-15", ["mode": "office", "placeId": placeId])
        try await api(app, context, .DELETE, "places/" + placeId, nil, .noContent)
        try await api(app, context, .PUT, "plan/days/2026-10-16", ["mode": "office", "placeId": placeId], .notFound)
    }

    private var c10Scenarios: [Scenario] { [scenarioC10Limits, scenarioC10ModelEnd, scenarioC10Minor] }

    func testC10FixesSQLite() async throws {
        for scenario in c10Scenarios { try await withApp(scenario) }
    }
    func testC10FixesMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"]
        for scenario in c10Scenarios { try await withApp(environment: environment, scenario) }
    }
}
