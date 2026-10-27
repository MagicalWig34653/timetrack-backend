import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// K1 (ADR-0021): planned times on plan days, the week planner and the week overview.
extension AuthTests {
    // 2026-W30 is Monday 20 July to Sunday 26 July 2026 (CEST, no holiday in the region).
    private static let week = "2026-W30"

    private func intValue(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    func scenarioPlanBlocks(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, owner)
        try await planningModel(app, owner)
        let blocks: [[String: Any]] = [
            ["start": "08:00", "end": "12:00", "kind": "school", "note": "Private block"],
            ["start": "13:00", "end": "17:00", "kind": "work"]
        ]
        let saved = try object(await api(app, owner, .PUT, "plan/days/2026-07-20", ["mode": "office", "blocks": blocks]))
        XCTAssertEqual(saved["plannedStart"] as? String, "08:00")
        XCTAssertEqual(saved["plannedEnd"] as? String, "17:00")
        XCTAssertEqual(saved["plannedBreakMinutes"] as? Int, 60)
        XCTAssertEqual(saved["plannedSeconds"] as? Int, 28_800)
        XCTAssertEqual((saved["blocks"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(saved["planHints"] as? [String], [])
        let week = try object(await api(app, owner, .GET, "plan/weeks/\(Self.week)"))
        XCTAssertEqual((week["totals"] as? [String: Any])?["plannedSeconds"] as? Int, 28_800)
        let actual = try object(await api(app, owner, .GET, "time/weeks/\(Self.week)"))
        let monday = try XCTUnwrap((actual["days"] as? [[String: Any]])?.first)
        XCTAssertEqual((monday["planBlocks"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(monday["planActualDifferenceSeconds"] as? Int, -28_800)
        let share = try object(await api(app, owner, .POST, "shares", ["recipientHandle": "member", "scopes": ["plan": true]], .created))
        let view = try object(await api(app, member, .GET, "shares/incoming/\(share["id"] as! String)/view?from=2026-07-20&to=2026-07-20"))
        let shared = try XCTUnwrap((view["plan"] as? [[String: Any]])?.first)
        XCTAssertEqual((shared["blocks"] as? [[String: Any]])?.count, 2)
        XCTAssertNil((shared["blocks"] as? [[String: Any]])?.first?["note"])
        XCTAssertNil((shared["blocks"] as? [[String: Any]])?.first?["placeId"])
        let invalidInputs: [([String: Any], String)] = [
            (["mode": "office", "blocks": [blocks[0], ["start": "11:00", "end": "14:00", "kind": "work"]]], "plan_blocks_overlap"),
            (["mode": "office", "blocks": [blocks[1], blocks[0]]], "plan_blocks_overlap"),
            (["mode": "office", "blocks": [["start": "08:00", "end": "08:00", "kind": "work"]]], "plan_time_invalid"),
            (["mode": "office", "blocks": [["start": "08:00", "end": "09:00", "kind": "invalid"]]], "plan_kind_invalid"),
            (["mode": "off", "blocks": blocks], "plan_blocks_invalid")
        ]
        for (body, code) in invalidInputs {
            try await eq(try errorCode(await api(app, owner, .PUT, "plan/days/2026-07-20", body, .badRequest)), code)
        }
        let unchanged = try object(await api(app, owner, .GET, "plan/weeks/\(Self.week)"))
        XCTAssertEqual((unchanged["totals"] as? [String: Any])?["plannedSeconds"] as? Int, 28_800)
        // An old client can still overwrite a block plan using the legacy fields.
        let legacy = try object(await api(app, owner, .PUT, "plan/days/2026-07-20", ["mode": "home", "plannedStart": "09:00", "plannedEnd": "17:00", "plannedBreakMinutes": 30]))
        XCTAssertEqual(legacy["plannedSeconds"] as? Int, 27_000)
        XCTAssertEqual((legacy["blocks"] as? [[String: Any]])?.count, 2)
        let longBlock = try object(await api(app, owner, .PUT, "plan/days/2026-07-21", ["mode": "office", "blocks": [["start": "08:00", "end": "16:00", "kind": "work"]]]))
        XCTAssertEqual(Set(longBlock["planHints"] as? [String] ?? []), ["planned_break_short", "planned_work_stretch_long"])
    }

    func scenarioPlanDayTimes(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        // A legacy client without the new fields keeps working; the new fields read back as null.
        let legacy = try object(await api(app, context, .PUT, "plan/days/2026-07-20", ["mode": "office", "note": "n"]))
        XCTAssertTrue(legacy["plannedStart"] is NSNull); XCTAssertTrue(legacy["plannedSeconds"] is NSNull)
        let timed = try object(await api(app, context, .PUT, "plan/days/2026-07-20", ["mode": "office", "plannedStart": "08:00", "plannedEnd": "16:30", "plannedBreakMinutes": 30]))
        XCTAssertEqual(timed["plannedSeconds"] as? Int, 8 * 3600)
        XCTAssertTrue(timed["note"] is NSNull, "PUT replaces the whole entry")
        // The break never makes the planned time negative.
        let clamped = try object(await api(app, context, .PUT, "plan/days/2026-07-21", ["mode": "home", "plannedStart": "09:00", "plannedEnd": "09:30", "plannedBreakMinutes": 60]))
        XCTAssertEqual(clamped["plannedSeconds"] as? Int, 0)
        // Mode off ignores times; the day is stored without them.
        let off = try object(await api(app, context, .PUT, "plan/days/2026-07-22", ["mode": "off", "plannedStart": "08:00", "plannedEnd": "12:00"]))
        XCTAssertTrue(off["plannedStart"] is NSNull); XCTAssertTrue(off["plannedSeconds"] is NSNull)
        // Validation: German message from the existing error mapping.
        for body: [String: Any] in [["mode": "office", "plannedStart": "08:00"], ["mode": "office", "plannedEnd": "16:00"],
                                    ["mode": "office", "plannedStart": "16:00", "plannedEnd": "08:00"], ["mode": "office", "plannedStart": "08:00", "plannedEnd": "08:00"],
                                    ["mode": "office", "plannedStart": "8:00", "plannedEnd": "16:00"], ["mode": "office", "plannedStart": "08:00", "plannedEnd": "24:00"],
                                    ["mode": "office", "plannedStart": "08:60", "plannedEnd": "09:00"]] {
            let response = try await api(app, context, .PUT, "plan/days/2026-07-23", body, .badRequest)
            XCTAssertEqual(try errorCode(response), "plan_time_invalid")
            XCTAssertTrue(try XCTUnwrap(((try object(response))["error"] as? [String: Any])?["message"] as? String).contains("Uhrzeit"))
        }
        for body: [String: Any] in [["mode": "office", "plannedBreakMinutes": 15], ["mode": "office", "plannedStart": "08:00", "plannedEnd": "16:00", "plannedBreakMinutes": 601],
                                    ["mode": "office", "plannedStart": "08:00", "plannedEnd": "16:00", "plannedBreakMinutes": -1]] {
            try await eq(try errorCode(await api(app, context, .PUT, "plan/days/2026-07-23", body, .badRequest)), "plan_break_invalid")
        }
        // Listing returns the times; replacing without times clears them.
        let listed = try list(await api(app, context, .GET, "plan/days?from=2026-07-20&to=2026-07-20"))
        XCTAssertEqual(listed.first?["plannedStart"] as? String, "08:00")
        let cleared = try object(await api(app, context, .PUT, "plan/days/2026-07-20", ["mode": "office"]))
        XCTAssertTrue(cleared["plannedEnd"] is NSNull)
    }

    func scenarioPlanWeek(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        try await planningModel(app, context)
        try await createAbsence(app, context, absenceBody("2026-07-22"))   // Wednesday: approved vacation blocks the plan
        func day(_ date: String, _ mode: String = "office", _ start: String? = "08:00", _ end: String? = "16:30", breakMinutes: Int? = 30) -> [String: Any] {
            var body: [String: Any] = ["date": date, "mode": mode]
            if let start { body["plannedStart"] = start }; if let end { body["plannedEnd"] = end }; if let breakMinutes, start != nil { body["plannedBreakMinutes"] = breakMinutes }
            return body
        }
        let empty = try object(await api(app, context, .GET, "plan/weeks/\(Self.week)"))
        XCTAssertEqual(empty["from"] as? String, "2026-07-20"); XCTAssertEqual(empty["to"] as? String, "2026-07-26")
        XCTAssertEqual((empty["days"] as? [Any])?.count, 7)
        XCTAssertEqual(intValue((empty["totals"] as? [String: Any])?["targetSeconds"]), 138_600 - 27_720)   // vacation day has no target
        XCTAssertEqual(intValue((empty["totals"] as? [String: Any])?["plannedSeconds"]), 0)

        let saved = try object(await api(app, context, .PUT, "plan/weeks/\(Self.week)", ["days": [day("2026-07-20"), day("2026-07-21"), day("2026-07-22"), day("2026-07-23", "home"), day("2026-07-24", "off", nil, nil)]]))
        let days = try XCTUnwrap(saved["days"] as? [[String: Any]])
        XCTAssertEqual(days.map { $0["weekday"] as? Int }, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(days[2]["blockedBy"] as? String, "vacation"); XCTAssertEqual(days[2]["plannedSeconds"] as? Int, 0)
        XCTAssertEqual(days[2]["targetSeconds"] as? Int, 0)
        XCTAssertEqual((days[2]["plan"] as? [String: Any])?["plannedSeconds"] as? Int, 8 * 3600, "the stored plan stays visible")
        XCTAssertTrue(days[0]["blockedBy"] is NSNull); XCTAssertEqual(days[0]["plannedSeconds"] as? Int, 8 * 3600)
        XCTAssertTrue(days[4]["plannedSeconds"] is NSNull); XCTAssertEqual((days[4]["plan"] as? [String: Any])?["mode"] as? String, "off")
        XCTAssertTrue(days[5]["plan"] is NSNull)
        let totals = try XCTUnwrap(saved["totals"] as? [String: Any])
        XCTAssertEqual(intValue(totals["plannedSeconds"]), 3 * 8 * 3600)
        XCTAssertEqual(intValue(totals["differenceSeconds"]), 3 * 8 * 3600 - (138_600 - 27_720))

        // Without replace the other days stay; with replace=true omitted days are deleted.
        _ = try await api(app, context, .PUT, "plan/weeks/\(Self.week)", ["days": [day("2026-07-25", "home")]])
        try await eq(try list(await api(app, context, .GET, "plan/days?from=2026-07-20&to=2026-07-26")).count, 6)
        let replaced = try object(await api(app, context, .PUT, "plan/weeks/\(Self.week)", ["replace": true, "days": [day("2026-07-21", "customer", "07:30", "15:00", breakMinutes: 45)]]))
        try await eq(try list(await api(app, context, .GET, "plan/days?from=2026-07-20&to=2026-07-26")).count, 1)
        XCTAssertEqual(intValue((replaced["totals"] as? [String: Any])?["plannedSeconds"]), (7 * 60 + 30 - 45) * 60)
        _ = try await api(app, context, .PUT, "plan/weeks/\(Self.week)", ["replace": true, "days": []])
        try await eq(try list(await api(app, context, .GET, "plan/days?from=2026-07-20&to=2026-07-26")).count, 0)

        // All or nothing: the invalid second entry rolls back the first, and the replace deletion.
        try await api(app, context, .PUT, "plan/days/2026-07-27", ["mode": "home"])   // other week, must never be touched
        _ = try await api(app, context, .PUT, "plan/weeks/\(Self.week)", ["days": [day("2026-07-20")]])
        try await eq(try errorCode(await api(app, context, .PUT, "plan/weeks/\(Self.week)", ["replace": true, "days": [day("2026-07-21"), day("2026-07-22", "office", "10:00", "09:00")]], .badRequest)), "plan_time_invalid")
        let afterFailure = try list(await api(app, context, .GET, "plan/days?from=2026-07-20&to=2026-07-26"))
        XCTAssertEqual(afterFailure.map { $0["date"] as? String }, ["2026-07-20"])
        try await eq(try list(await api(app, context, .GET, "plan/days?from=2026-07-27&to=2026-07-27")).count, 1)

        // Structure errors.
        for bad in ["2026-30", "2026-W00", "2026-W54", "2027-W53", "26-W30", "2026-W3", "abc"] {
            try await eq(try errorCode(await api(app, context, .GET, "plan/weeks/\(bad)", nil, .badRequest)), "invalid_week")
        }
        try await api(app, context, .GET, "plan/weeks/2026-W53")                       // 2026 has 53 ISO weeks
        try await eq(try errorCode(await api(app, context, .PUT, "plan/weeks/\(Self.week)", ["days": [day("2026-07-27")]], .badRequest)), "week_day_invalid")
        try await eq(try errorCode(await api(app, context, .PUT, "plan/weeks/\(Self.week)", ["days": [day("2026-07-20"), day("2026-07-20")]], .badRequest)), "week_day_invalid")
        try await api(app, context, .PUT, "plan/weeks/\(Self.week)", ["days": (0..<8).map { _ in day("2026-07-20") }], .badRequest)
        try await api(app, context, .PUT, "plan/weeks/\(Self.week)", ["days": [["date": "2026-07-20", "mode": "bogus"]]], .badRequest)
        try await api(app, context, .PUT, "plan/weeks/\(Self.week)", ["days": [day("2026-07-20")], "placeId": 1], .ok)   // unknown fields are ignored
        try await api(app, context, .PUT, "plan/weeks/\(Self.week)", ["days": [["date": "2026-07-20", "mode": "home", "placeId": UUID().uuidString]]], .notFound)
    }

    func scenarioPlanWeekIsolationAndShares(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, owner)
        try await planningModel(app, owner); try await planningModel(app, member)
        try await api(app, owner, .PUT, "plan/weeks/\(Self.week)", ["days": [["date": "2026-07-20", "mode": "office", "note": "Private", "plannedStart": "08:00", "plannedEnd": "16:00", "plannedBreakMinutes": 30]]])
        let foreign = try object(await api(app, member, .GET, "plan/weeks/\(Self.week)"))
        XCTAssertTrue(try XCTUnwrap(foreign["days"] as? [[String: Any]]).allSatisfy { $0["plan"] is NSNull })
        try await api(app, member, .PUT, "plan/weeks/\(Self.week)", ["replace": true, "days": []])   // must not delete the owner's plan
        try await eq(try list(await api(app, owner, .GET, "plan/days?from=2026-07-20&to=2026-07-26")).count, 1)
        // The plan scope shares the planned times, never notes or places.
        let share = try object(await api(app, owner, .POST, "shares", ["recipientHandle": "member", "scopes": ["plan": true]], .created))
        let view = try object(await api(app, member, .GET, "shares/incoming/\(share["id"] as! String)/view?from=2026-07-20&to=2026-07-26"))
        let plan = try XCTUnwrap((view["plan"] as? [[String: Any]])?.first)
        XCTAssertEqual(plan["plannedStart"] as? String, "08:00"); XCTAssertEqual(plan["plannedSeconds"] as? Int, 27_000)
        XCTAssertNil(plan["note"]); XCTAssertNil(plan["placeId"])
        let text = String(decoding: try await api(app, member, .GET, "shares/incoming/\(share["id"] as! String)/view?from=2026-07-20&to=2026-07-26").body.readableBytesView, as: UTF8.self)
        XCTAssertFalse(text.contains("Private"))
        // Module switch: planning endpoints are gone, the time week stays.
        try await api(app, owner, .PUT, "me/modules", ["modules": ["planning": false]])
        try await eq(try errorCode(await api(app, owner, .GET, "plan/weeks/\(Self.week)", nil, .notFound)), "module_disabled")
        try await api(app, owner, .PUT, "plan/weeks/\(Self.week)", ["days": []], .notFound)
        let timeWeek = try object(await api(app, owner, .GET, "time/weeks/\(Self.week)"))
        XCTAssertTrue((timeWeek["summary"] as? [String: Any])?["plannedSeconds"] is NSNull)
    }

    func scenarioTimeWeek(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        try await planningModel(app, context)
        try await createAbsence(app, context, absenceBody("2026-07-22"))                              // Wednesday vacation
        try await createAbsence(app, context, absenceBody("2026-07-23", kind: "sick"))                 // Thursday sick
        try await api(app, context, .POST, "time/segments", segmentBody("2026-07-20T06:07:00Z", "2026-07-20T10:00:00Z"), .created)   // 08:07-12:00 local
        try await api(app, context, .POST, "time/segments", segmentBody("2026-07-20T10:30:00Z", "2026-07-20T14:20:00Z"), .created)   // 12:30-16:20
        try await api(app, context, .POST, "time/segments", ["kind": "travel", "startedAt": "2026-07-21T05:00:00Z", "endedAt": "2026-07-21T05:45:00Z"], .created)
        try await api(app, context, .POST, "time/segments", segmentBody("2026-07-21T05:45:00Z", "2026-07-21T15:00:00Z"), .created)
        try await api(app, context, .PUT, "plan/days/2026-07-24", ["mode": "home", "plannedStart": "08:00", "plannedEnd": "12:00"])
        try await api(app, context, .POST, "time/account/adjustments", ["kind": "opening", "date": "2026-01-01", "seconds": 3600, "reason": "Start"], .created)

        let week = try object(await api(app, context, .GET, "time/weeks/\(Self.week)"))
        let days = try XCTUnwrap(week["days"] as? [[String: Any]])
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.map { $0["mark"] as? String }, ["work", "work", "vacation", "sick", "work", "off", "off"])
        XCTAssertEqual((days[2]["absences"] as? [[String: Any]])?.first?["kind"] as? String, "vacation")
        XCTAssertEqual(days[1]["travelSeconds"] as? Int, 2700); XCTAssertEqual(days[0]["breakSeconds"] as? Int, 30 * 60)
        XCTAssertEqual(days[0]["segmentsCount"] as? Int, 2); XCTAssertEqual(days[4]["plannedSeconds"] as? Int, 4 * 3600)
        XCTAssertEqual(days[4]["planMode"] as? String, "home"); XCTAssertTrue(days[0]["plannedSeconds"] is NSNull)
        XCTAssertTrue(days[0]["firstStart"] is String)

        // The summary equals the sum of /time/days for the same week.
        let evaluated = try list(await api(app, context, .GET, "time/days?from=2026-07-20&to=2026-07-26"))
        let summary = try XCTUnwrap(week["summary"] as? [String: Any])
        func sum(_ key: String) -> Int { evaluated.reduce(0) { $0 + (intValue($1[key]) ?? 0) } }
        XCTAssertEqual(intValue(summary["workSeconds"]), sum("evaluatedWorkSeconds"))
        XCTAssertEqual(intValue(summary["targetSeconds"]), sum("targetSeconds"))
        XCTAssertEqual(intValue(summary["balanceSeconds"]), sum("deltaSeconds"))
        XCTAssertEqual(intValue(summary["creditSeconds"]), sum("creditSeconds"))
        XCTAssertEqual(days.compactMap { intValue($0["balanceSeconds"]) }, evaluated.compactMap { intValue($0["deltaSeconds"]) })
        XCTAssertEqual(summary["workDays"] as? Int, 2); XCTAssertEqual(summary["vacationDays"] as? Double, 1)
        XCTAssertEqual(summary["sickDays"] as? Int, 1); XCTAssertEqual(summary["holidayDays"] as? Int, 0)
        XCTAssertEqual(intValue(summary["travelSeconds"]), 2700); XCTAssertEqual(intValue(summary["plannedSeconds"]), 4 * 3600)
        XCTAssertEqual((summary["longestDay"] as? [String: Any])?["date"] as? String, "2026-07-21")
        XCTAssertNotNil(summary["averageStart"] as? String)

        // Account balance fields use the /time/account logic at the end of the previous week and of this week.
        let before = try object(await api(app, context, .GET, "time/account?asOf=2026-07-19"))
        let after = try object(await api(app, context, .GET, "time/account?asOf=2026-07-26"))
        XCTAssertEqual(intValue(summary["accountBalanceBeforeSeconds"]), intValue(before["balanceSeconds"]))
        XCTAssertEqual(intValue(summary["accountBalanceAfterSeconds"]), intValue(after["balanceSeconds"]))
        XCTAssertEqual(intValue(summary["accountBalanceAfterSeconds"])! - intValue(summary["accountBalanceBeforeSeconds"])!, intValue(summary["balanceSeconds"]))

        // Isolation: another account sees none of it.
        let member = try await second(app, auth, context)
        let foreign = try object(await api(app, member, .GET, "time/weeks/\(Self.week)"))
        XCTAssertEqual(intValue((foreign["summary"] as? [String: Any])?["workSeconds"]), 0)
        XCTAssertEqual((foreign["days"] as? [[String: Any]])?.map { $0["segmentsCount"] as? Int }, Array(repeating: 0, count: 7))
        try await eq(try errorCode(await api(app, context, .GET, "time/weeks/2026-W99", nil, .badRequest)), "invalid_week")

        // Running week: only days up to today carry a balance; the running day is provisional.
        try await api(app, context, .POST, "time/segments", segmentBody("2026-07-27T06:00:00Z"), .created)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-28T09:00:00Z"))
        let running = try await app.db.transaction { tx in
            try await TimeServices(accountId: context.account.requireID(), db: tx).weeks.week(ISOWeek("2026-W31"), now: now)
        }
        XCTAssertEqual(running.days.map(\.isFuture), [false, false, true, true, true, true, true])
        XCTAssertTrue(running.days[1].provisional); XCTAssertTrue(running.days[1].isToday); XCTAssertNil(running.days[4].balanceSeconds)
        XCTAssertTrue(running.summary.provisional)
        XCTAssertEqual(running.summary.targetToDateSeconds, 2 * 27_720)
        XCTAssertEqual(running.summary.targetSeconds, 138_600)
    }

    func scenarioWeekQueryBudget(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let accountId = try context.account.requireID()
        try await planningModel(app, context, from: "2025-01-01")
        func counted(_ body: @escaping @Sendable (TimeServices) async throws -> Void) async throws -> Int {
            let counter = StatementCounter()
            var logger = Logger(label: "k1-count") { _ in StatementCounter.Handler(counter: counter) }
            logger.logLevel = .info
            let db = try XCTUnwrap(app.databases.database(logger: logger, on: app.eventLoopGroup.next()))
            try await body(TimeServices(accountId: accountId, db: db))
            return counter.count
        }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-27T09:00:00Z"))
        let small = try await counted { _ = try await $0.weeks.week(ISOWeek(Self.week), now: now); _ = try await $0.plans.week(ISOWeek(Self.week)) }
        var rows: [SegmentRecord] = []
        var day = Date(timeIntervalSince1970: 1_735_714_800)   // 2025-01-01T07:00:00Z
        for _ in 0..<400 {
            let row = SegmentRecord(); row.id = UUID(); row.accountId = accountId; row.rawStartedAt = day; row.rawEndedAt = day.addingTimeInterval(28_800)
            row.startedAt = day; row.endedAt = day.addingTimeInterval(28_800); row.kind = "work"; row.source = "import"
            row.version = 1; row.needsReview = false; row.revisions = 0; row.running = nil
            rows.append(row); day = day.addingTimeInterval(86_400)
        }
        for row in rows { try await row.create(on: app.db) }
        for index in 0..<7 { try await api(app, context, .PUT, "plan/days/2026-07-2\(index)", ["mode": "office", "plannedStart": "08:00", "plannedEnd": "16:00"]) }
        let large = try await counted { _ = try await $0.weeks.week(ISOWeek(Self.week), now: now); _ = try await $0.plans.week(ISOWeek(Self.week)) }
        print("K1 week statements small/large:", small, large)
        XCTAssertGreaterThan(small, 3, "the statement counter must see the queries")
        XCTAssertEqual(large, small, "statements must not depend on history length or plan size")
        XCTAssertLessThanOrEqual(large, 30)
    }

    func scenarioWeekEndpointsRequireSession(_ app: Application, _ auth: AuthService) async throws {
        try await timeRequest(app, nil, .GET, "plan/weeks/\(Self.week)", status: .unauthorized)
        try await timeRequest(app, nil, .PUT, "plan/weeks/\(Self.week)", ["days": []], status: .unauthorized)
        try await timeRequest(app, nil, .GET, "time/weeks/\(Self.week)", status: .unauthorized)
    }

    func weekScenarios() -> [Scenario] {
        [scenarioPlanDayTimes, scenarioPlanBlocks, scenarioPlanWeek, scenarioPlanWeekIsolationAndShares, scenarioTimeWeek, scenarioWeekQueryBudget, scenarioWeekEndpointsRequireSession]
    }
    func testWeekPlanningSQLite() async throws {
        setenv("DB_SQL_LOG", "1", 1); defer { unsetenv("DB_SQL_LOG") }
        for scenario in weekScenarios() { try await withApp(scenario) }
    }
    func testPlanBlockMigrationSQLite() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            _ = try await api(app, context, .PUT, "plan/days/2026-07-20", ["mode": "office", "plannedStart": "08:00", "plannedEnd": "16:00", "plannedBreakMinutes": 30])
            _ = try await api(app, context, .PUT, "plan/days/2026-07-21", ["mode": "school", "plannedStart": "09:00", "plannedEnd": "12:00"])
            try await AddPlanBlocks().revert(on: app.db)
            try await AddPlanBlocks().prepare(on: app.db)
            let rows = try list(await api(app, context, .GET, "plan/days?from=2026-07-20&to=2026-07-21"))
            XCTAssertEqual(rows[0]["plannedSeconds"] as? Int, 27_000)
            XCTAssertEqual((rows[0]["blocks"] as? [[String: Any]])?.count, 2)
            XCTAssertEqual((rows[1]["blocks"] as? [[String: Any]])?.count, 1)
            XCTAssertEqual((rows[1]["blocks"] as? [[String: Any]])?.first?["kind"] as? String, "school")
        }
    }
    func testWeekPlanningMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"]
        setenv("DB_SQL_LOG", "1", 1); defer { unsetenv("DB_SQL_LOG") }
        for scenario in weekScenarios() { try await withApp(environment: environment, scenario) }
    }
}

final class StatementCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    struct Handler: LogHandler {
        let counter: StatementCounter
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .info
        subscript(metadataKey key: String) -> Logger.Metadata.Value? { get { metadata[key] } set { metadata[key] = newValue } }
        func log(event: LogEvent) { counter.add() }
        func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) { counter.add() }
    }
}
