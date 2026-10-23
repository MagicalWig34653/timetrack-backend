import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// W3: cancelled segments (list, restore, permanent delete, bulk purge) and the statistics series.
extension AuthTests {
    private func items(_ response: XCTHTTPResponse) throws -> [[String: Any]] {
        try XCTUnwrap(object(response)["items"] as? [[String: Any]])
    }

    func testCancelledSegmentsListRestoreAndPurge() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let (other, _) = try await registered(auth, db: app.db, handle: "second", admin: context)
            let a = try resourceID(await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-12T06:00:00Z", "2026-10-12T08:00:00Z"), status: .created))
            let b = try resourceID(await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-13T06:00:00Z", "2026-10-13T08:00:00Z"), status: .created))
            let live = try resourceID(await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-14T06:00:00Z", "2026-10-14T08:00:00Z"), status: .created))
            try await timeRequest(app, context, .DELETE, "time/segments/\(a)?reason=Mistake", status: .noContent)
            try await timeRequest(app, context, .DELETE, "time/segments/\(b)?reason=Duplicate", status: .noContent)

            // Listing: newest start first, paged, range filtered; live segments and other accounts never appear.
            let page = try object(await timeRequest(app, context, .GET, "time/segments/cancelled"))
            XCTAssertEqual(page["total"] as? Int, 2)
            let all = try XCTUnwrap(page["items"] as? [[String: Any]])
            XCTAssertEqual(all.compactMap { ($0["segment"] as? [String: Any])?["id"] as? String }, [b, a])
            XCTAssertEqual(all.first?["cancelReason"] as? String, "Duplicate"); XCTAssertNotNil(all.first?["cancelledAt"] as? String)
            let second = try object(await timeRequest(app, context, .GET, "time/segments/cancelled?limit=1&offset=1"))
            XCTAssertEqual(second["total"] as? Int, 2); XCTAssertEqual((second["items"] as? [Any])?.count, 1)
            let ranged = try items(await timeRequest(app, context, .GET, "time/segments/cancelled?from=2026-10-13T00:00:00Z&to=2026-10-14T00:00:00Z"))
            XCTAssertEqual(ranged.count, 1)
            let otherItems = try items(await timeRequest(app, other, .GET, "time/segments/cancelled"))
            XCTAssertEqual(otherItems.count, 0)
            try await timeRequest(app, context, .GET, "time/segments/cancelled?limit=0", status: .badRequest)
            try await timeRequest(app, context, .GET, "time/segments/cancelled?from=bogus", status: .badRequest)

            // Permanent delete: never a live segment (409), never another account's (404).
            let notCancelled = try object(await timeRequest(app, context, .DELETE, "time/segments/\(live)?permanent=true", status: .conflict))
            XCTAssertEqual((notCancelled["error"] as? [String: String])?["code"], "segment_not_cancelled")
            try await timeRequest(app, other, .DELETE, "time/segments/\(a)?permanent=true", status: .notFound)
            try await timeRequest(app, context, .GET, "time/segments/\(live)")

            // Restore: overlap with a live segment is refused, a free slot works and records a revision.
            let overlap = try await resourceID(timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-12T07:00:00Z", "2026-10-12T09:00:00Z"), status: .created))
            let blocked = try object(await timeRequest(app, context, .POST, "time/segments/\(a)/restore", ["reason": "Oops"], status: .conflict))
            XCTAssertEqual((blocked["error"] as? [String: String])?["code"], "segment_overlap")
            try await timeRequest(app, context, .POST, "time/segments/\(live)/restore", [:], status: .conflict)
            try await timeRequest(app, other, .POST, "time/segments/\(a)/restore", [:], status: .notFound)
            try await timeRequest(app, context, .POST, "time/segments/\(b)/restore", [:], status: .preconditionFailed, extra: ["If-Match": "1"]) // version is 2 after the void
            try await timeRequest(app, context, .DELETE, "time/segments/\(overlap)?reason=Mistake", status: .noContent)
            let restored = try object(await timeRequest(app, context, .POST, "time/segments/\(b)/restore", ["reason": "Oops"]))
            XCTAssertEqual(restored["voided"] as? Bool, false); XCTAssertEqual(restored["version"] as? Int, 3)
            let revisions = try await RevisionRecord.query(on: app.db).filter(\.$segmentId == UUID(uuidString: b)!).sort(\.$createdAt).all()
            XCTAssertEqual(revisions.last?.reason, "Restored: Oops")
            try await timeRequest(app, context, .POST, "time/segments/\(b)/restore", [:], status: .conflict) // already live
            try await timeRequest(app, context, .DELETE, "time/segments/\(b)?reason=Again", status: .noContent)

            // Bulk purge: a scope is mandatory, a live id aborts everything, dryRun only counts.
            try await timeRequest(app, context, .DELETE, "time/segments/cancelled", status: .badRequest)
            try await timeRequest(app, context, .DELETE, "time/segments/cancelled?ids=\(a),\(live)", status: .conflict)
            try await timeRequest(app, context, .DELETE, "time/segments/cancelled?ids=nope", status: .badRequest)
            let before = try await SegmentRecord.query(on: app.db).count()
            let preview = try object(await timeRequest(app, context, .DELETE, "time/segments/cancelled?all=true&dryRun=true"))
            XCTAssertEqual(preview["dryRun"] as? Bool, true); XCTAssertEqual(preview["segments"] as? Int, 3)
            XCTAssertGreaterThanOrEqual(preview["revisions"] as? Int ?? 0, 3)
            let afterPreview = try await SegmentRecord.query(on: app.db).count()
            XCTAssertEqual(afterPreview, before)

            // Dependent data goes with the segment: revisions and end suggestions.
            let suggestion = SuggestionRecord(); suggestion.id = UUID(); suggestion.accountId = try context.account.requireID()
            suggestion.payload = .init(id: suggestion.id!, type: "end", placeId: nil, proposedStartedAt: nil, proposedEndedAt: Date(), segmentId: UUID(uuidString: a)!, createdAt: Date())
            try await suggestion.create(on: app.db)
            let single = try object(await timeRequest(app, context, .DELETE, "time/segments/\(a)?permanent=true"))
            XCTAssertEqual(single["dryRun"] as? Bool, false); XCTAssertEqual(single["segments"] as? Int, 1)
            XCTAssertEqual(single["suggestions"] as? Int, 1); XCTAssertEqual(single["revisions"] as? Int, 1)
            try await timeRequest(app, context, .GET, "time/segments/\(a)", status: .notFound)
            let leftover = try await RevisionRecord.query(on: app.db).filter(\.$segmentId == UUID(uuidString: a)!).count()
            XCTAssertEqual(leftover, 0)
            let gone = try await SuggestionRecord.find(suggestion.id, on: app.db)
            XCTAssertNil(gone)
            try await timeRequest(app, context, .DELETE, "time/segments/\(a)?permanent=true", status: .notFound)

            // Range purge removes only cancelled segments; the live one survives.
            let purged = try object(await timeRequest(app, context, .DELETE, "time/segments/cancelled?from=2026-10-01T00:00:00Z&to=2026-11-01T00:00:00Z"))
            XCTAssertEqual(purged["segments"] as? Int, 2) // b and the overlap helper
            try await timeRequest(app, context, .GET, "time/segments/\(live)")
            let remaining = try items(await timeRequest(app, context, .GET, "time/segments/cancelled"))
            XCTAssertEqual(remaining.count, 0)
        }
    }

    func testRestoreCancelledRunningTimerGuards() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let first = try object(await timeRequest(app, context, .POST, "time/timer/start", ["clientEventId": UUID().uuidString]))
            let firstId = try XCTUnwrap(first["id"] as? String)
            try await timeRequest(app, context, .DELETE, "time/segments/\(firstId)?reason=Mistake", status: .noContent)
            try await timeRequest(app, context, .POST, "time/timer/start", ["clientEventId": UUID().uuidString])
            let conflict = try object(await timeRequest(app, context, .POST, "time/segments/\(firstId)/restore", [:], status: .conflict))
            XCTAssertEqual((conflict["error"] as? [String: String])?["code"], "timer_already_running")
            try await timeRequest(app, context, .POST, "time/timer/stop", ["clientEventId": UUID().uuidString])
            // The cancelled timer started earlier and is open ended: it now overlaps the finished one.
            let overlap = try object(await timeRequest(app, context, .POST, "time/segments/\(firstId)/restore", [:], status: .conflict))
            XCTAssertEqual((overlap["error"] as? [String: String])?["code"], "segment_overlap")
        }
    }

    func testStatisticsSeriesMatchesDaysAndAccount() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let (other, _) = try await registered(auth, db: app.db, handle: "second", admin: context)
            try await timeRequest(app, context, .POST, "work-models", modelBody(), status: .created)
            try await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-12T06:07:00Z", "2026-10-12T10:00:00Z"), status: .created)
            try await timeRequest(app, context, .POST, "time/segments", segmentBody("2026-10-12T11:00:00Z", "2026-10-12T14:02:00Z"), status: .created)
            try await timeRequest(app, context, .POST, "time/segments", ["kind": "school", "startedAt": "2026-10-13T06:00:00Z", "endedAt": "2026-10-13T12:00:00Z"], status: .created)
            try await timeRequest(app, context, .PUT, "time/days/2026-10-14", ["mark": "sick"])
            let weekly = try object(await timeRequest(app, context, .GET, "time/statistics?from=2026-10-01&to=2026-10-31"))
            XCTAssertEqual(weekly["granularity"] as? String, "week"); XCTAssertEqual(weekly["basis"] as? String, "evaluated")
            let buckets = try XCTUnwrap(weekly["buckets"] as? [[String: Any]])
            XCTAssertEqual(buckets.first?["label"] as? String, "2026-W40"); XCTAssertEqual(buckets.first?["from"] as? String, "2026-10-01")
            let week42 = try XCTUnwrap(buckets.first { $0["label"] as? String == "2026-W42" })
            XCTAssertEqual(week42["from"] as? String, "2026-10-12"); XCTAssertEqual(week42["days"] as? Int, 7)
            let kinds = try XCTUnwrap(week42["kindSeconds"] as? [String: Int])
            XCTAssertEqual(kinds["work"], 24900); XCTAssertEqual(kinds["school"], 21600); XCTAssertEqual(kinds["travel"], 0)
            XCTAssertEqual((week42["absences"] as? [String: Double])?["sick"], 1); XCTAssertEqual(week42["absenceDays"] as? Double, 1)
            // The week agrees with the week overview.
            let overview = try object(await timeRequest(app, context, .GET, "time/weeks/2026-W42"))
            let summary = try XCTUnwrap(overview["summary"] as? [String: Any])
            XCTAssertEqual(week42["targetSeconds"] as? Int, summary["targetSeconds"] as? Int)
            XCTAssertEqual(week42["evaluatedWorkSeconds"] as? Int, summary["workSeconds"] as? Int)
            XCTAssertEqual(week42["deltaSeconds"] as? Int, summary["balanceSeconds"] as? Int)
            XCTAssertEqual(week42["balanceSeconds"] as? Int, summary["accountBalanceAfterSeconds"] as? Int)
            // The last cumulative balance is the Zeitkonto of GET /time/account.
            let account = try object(await timeRequest(app, context, .GET, "time/account?asOf=2026-10-31"))
            XCTAssertEqual(buckets.last?["balanceSeconds"] as? Int, account["balanceSeconds"] as? Int)
            // Raw basis removes only the rounding adjustment; the official balance is unchanged.
            let raw = try object(await timeRequest(app, context, .GET, "time/statistics?from=2026-10-01&to=2026-10-31&basis=raw"))
            let rawWeek = try XCTUnwrap((raw["buckets"] as? [[String: Any]])?.first { $0["label"] as? String == "2026-W42" })
            let rounding = try XCTUnwrap(week42["roundingSeconds"] as? Int)
            XCTAssertGreaterThan(rounding, 0)
            XCTAssertEqual((week42["actualSeconds"] as? Int ?? 0) - (rawWeek["actualSeconds"] as? Int ?? 0), rounding)
            XCTAssertEqual(rawWeek["rawWorkSeconds"] as? Int, week42["rawWorkSeconds"] as? Int)
            XCTAssertEqual(rawWeek["balanceSeconds"] as? Int, week42["balanceSeconds"] as? Int)
            // Day and month granularity cover the same range; totals agree.
            let days = try object(await timeRequest(app, context, .GET, "time/statistics?from=2026-10-12&to=2026-10-18&granularity=day"))
            XCTAssertEqual((days["buckets"] as? [Any])?.count, 7)
            let month = try object(await timeRequest(app, context, .GET, "time/statistics?from=2026-09-15&to=2026-10-31&granularity=month"))
            XCTAssertEqual((month["buckets"] as? [[String: Any]])?.map { $0["label"] as? String }, ["2026-09", "2026-10"])
            let monthTotals = try XCTUnwrap(month["totals"] as? [String: Any])
            XCTAssertEqual(monthTotals["targetSeconds"] as? Int, (month["buckets"] as? [[String: Any]])?.reduce(0) { $0 + ($1["targetSeconds"] as? Int ?? 0) })
            // Validation and account separation.
            try await timeRequest(app, context, .GET, "time/statistics?from=2026-10-01&to=2026-10-31&granularity=year", status: .badRequest)
            try await timeRequest(app, context, .GET, "time/statistics?from=2026-10-01&to=2026-10-31&basis=x", status: .badRequest)
            try await timeRequest(app, context, .GET, "time/statistics?from=2026-10-31&to=2026-10-01", status: .badRequest)
            try await timeRequest(app, context, .GET, "time/statistics?from=2020-01-01&to=2026-10-01", status: .badRequest)
            let empty = try object(await timeRequest(app, other, .GET, "time/statistics?from=2026-10-12&to=2026-10-18&granularity=day"))
            XCTAssertEqual((empty["totals"] as? [String: Any])?["actualSeconds"] as? Int, 0)
            XCTAssertNil(empty["accountStart"] as? String)
        }
    }
}
