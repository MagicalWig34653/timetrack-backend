import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// N2: the ICS calendar subscription feed and the holiday visibility in the week overview.
final class ICSWriterTests: XCTestCase {
    func testEscapeAndFold() {
        XCTAssertEqual(ICSWriter.escape("a,b;c\\d\ne"), "a\\,b\\;c\\\\d\\ne")
        let long = "SUMMARY:" + String(repeating: "Überstunden äöü ", count: 20)
        let folded = ICSWriter.fold(long)
        let lines = folded.components(separatedBy: "\r\n")
        XCTAssertGreaterThan(lines.count, 1)
        for (index, line) in lines.enumerated() {
            XCTAssertLessThanOrEqual(line.utf8.count, 75)
            if index > 0 { XCTAssertTrue(line.hasPrefix(" ")) }
        }
        // Unfolding restores the original text (no split UTF-8 sequence, no lost character).
        XCTAssertEqual(folded.replacingOccurrences(of: "\r\n ", with: ""), long)
        XCTAssertEqual(ICSWriter.fold("short"), "short")
    }

    func testStampAndScrubber() {
        XCTAssertEqual(ICSWriter.stamp(Date(timeIntervalSince1970: 0)), "19700101T000000Z")
        XCTAssertEqual(ICSWriter.httpDate(Date(timeIntervalSince1970: 0)), "Thu, 01 Jan 1970 00:00:00 GMT")
        let token = Secrets.token()
        XCTAssertEqual(TriggerTokenScrubber.scrub("GET /ics/\(token).ics HTTP/1.1"), "GET /ics/[redacted].ics HTTP/1.1")
    }
}

extension AuthTests {
    // MARK: Helpers

    private func berlinToday(offset: Int = 0) -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return LocalDate.local(Date(), calendar: calendar).addingDays(offset)
    }
    private func compact(_ date: LocalDate) -> String { date.description.replacingOccurrences(of: "-", with: "") }

    private func createFeed(_ app: Application, _ context: AuthContext, label: String = "Phone", include: [String]? = nil) async throws -> (id: String, token: String) {
        var body: [String: Any] = ["label": label]
        if let include { body["include"] = include }
        let created = try object(await timeRequest(app, context, .POST, "me/calendar-feeds", body, status: .created))
        let token = try XCTUnwrap(created["token"] as? String)
        XCTAssertEqual(created["path"] as? String, "/ics/" + token + ".ics")
        return (try XCTUnwrap(created["id"] as? String), token)
    }
    @discardableResult
    private func fetchFeed(_ app: Application, _ token: String, suffix: String = ".ics", headers: HTTPHeaders = [:], status: HTTPStatus = .ok,
                           file: StaticString = #filePath, line: UInt = #line) async throws -> XCTHTTPResponse {
        let response = try await app.testable().sendRequest(.GET, "/ics/" + token + suffix, headers: headers)
        XCTAssertEqual(response.status, status, response.body.string, file: file, line: line)
        return response
    }
    private func lines(_ response: XCTHTTPResponse) -> [String] {
        response.body.string.components(separatedBy: "\r\n")
    }

    /// Structural RFC 5545 checks: CRLF only, folding, balanced components, unique UIDs, all-day dates with exclusive end.
    private func assertValidCalendar(_ response: XCTHTTPResponse, file: StaticString = #filePath, line: UInt = #line) {
        let text = response.body.string
        XCTAssertTrue(text.hasSuffix("END:VCALENDAR\r\n"), file: file, line: line)
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "bare LF", file: file, line: line)
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\r"), "bare CR", file: file, line: line)
        XCTAssertEqual(response.headers.first(name: .contentType), "text/calendar; charset=utf-8", file: file, line: line)
        let physical = text.components(separatedBy: "\r\n").dropLast()
        XCTAssertTrue(physical.allSatisfy { $0.utf8.count <= 75 }, file: file, line: line)
        // Unfold, then check the logical lines.
        let logical = text.replacingOccurrences(of: "\r\n ", with: "").components(separatedBy: "\r\n").dropLast()
        XCTAssertEqual(logical.first, "BEGIN:VCALENDAR", file: file, line: line)
        XCTAssertTrue(logical.contains("VERSION:2.0"), file: file, line: line)
        XCTAssertTrue(logical.contains { $0.hasPrefix("PRODID:") }, file: file, line: line)
        XCTAssertEqual(logical.filter { $0 == "BEGIN:VEVENT" }.count, logical.filter { $0 == "END:VEVENT" }.count, file: file, line: line)
        var uids: [String] = []
        var current: [String] = []
        for entry in logical {
            if entry == "BEGIN:VEVENT" { current = [] }
            current.append(entry)
            if entry == "END:VEVENT" {
                let uid = current.first { $0.hasPrefix("UID:") }
                XCTAssertNotNil(uid)
                uids.append(uid ?? "")
                XCTAssertTrue(current.contains { $0.range(of: #"^DTSTAMP:\d{8}T\d{6}Z$"#, options: .regularExpression) != nil }, "DTSTAMP")
                let start = current.first { $0.hasPrefix("DTSTART;VALUE=DATE:") }.map { String($0.suffix(8)) }
                let end = current.first { $0.hasPrefix("DTEND;VALUE=DATE:") }.map { String($0.suffix(8)) }
                XCTAssertNotNil(start); XCTAssertNotNil(end)
                if let start, let end { XCTAssertLessThan(start, end, "DTEND is exclusive") }
                XCTAssertTrue(current.contains { $0.hasPrefix("SUMMARY:") })
            }
        }
        XCTAssertEqual(Set(uids).count, uids.count, "UIDs are unique", file: file, line: line)
    }

    // MARK: Management

    func testCalendarFeedManagementStoresOnlyHash() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let feed = try await createFeed(app, context)
            let rows = try await CalendarFeedRecord.query(on: app.db).all()
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].tokenHash, Secrets.hash(feed.token)); XCTAssertNotEqual(rows[0].tokenHash, feed.token)
            XCTAssertEqual(rows[0].options, ["absences", "holidays"])
            let list = try await timeRequest(app, context, .GET, "me/calendar-feeds")
            XCTAssertFalse(list.body.string.contains(feed.token)); XCTAssertFalse(list.body.string.contains(rows[0].tokenHash))
            // Validation, authentication and CSRF.
            try await timeRequest(app, context, .POST, "me/calendar-feeds", ["label": " "], status: .badRequest)
            try await timeRequest(app, context, .POST, "me/calendar-feeds", ["label": "x", "include": []], status: .badRequest)
            try await timeRequest(app, context, .POST, "me/calendar-feeds", ["label": "x", "include": ["everything"]], status: .badRequest)
            try await timeRequest(app, context, .POST, "me/calendar-feeds", ["label": "x", "include": ["plan", "plan"]], status: .badRequest)
            try await timeRequest(app, nil, .GET, "me/calendar-feeds", status: .unauthorized)
            try await timeRequest(app, context, .POST, "me/calendar-feeds", ["label": "x"], status: .forbidden, extra: ["X-CSRF-Token": "wrong"])
            for index in 1..<CalendarFeedRules.maxActiveFeeds { _ = try await createFeed(app, context, label: "F\(index)") }
            let over = try await timeRequest(app, context, .POST, "me/calendar-feeds", ["label": "over"], status: .conflict)
            XCTAssertEqual(try errorCode(over), "too_many_calendar_feeds")
            // Revocation: idempotent, other accounts cannot revoke or see it.
            let other = try await second(app, auth, context)
            try await timeRequest(app, other, .DELETE, "me/calendar-feeds/" + feed.id, status: .notFound)
            let otherList = try JSONSerialization.jsonObject(with: Data(try await timeRequest(app, other, .GET, "me/calendar-feeds").body.readableBytesView)) as? [Any]
            XCTAssertEqual(otherList?.count, 0)
            try await timeRequest(app, context, .DELETE, "me/calendar-feeds/" + feed.id, status: .noContent)
            try await timeRequest(app, context, .DELETE, "me/calendar-feeds/" + feed.id, status: .noContent)
            try await fetchFeed(app, feed.token, status: .notFound)
        }
    }

    // MARK: Content

    /// Regression: with the PWA bundle mounted the static middleware must not answer /ics/... with the SPA shell
    /// (the browser then showed "page not found" and calendar clients received HTML).
    func testFeedIsNotShadowedByThePWAShell() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pwa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "<!doctype html><title>shell</title>".write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withApp(environment: ["PWA_STATIC_DIR": directory.path]) { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-01-01"), status: .created)
            let feed = try await createFeed(app, context)
            let response = try await fetchFeed(app, feed.token)
            XCTAssertEqual(response.status, .ok)
            XCTAssertTrue(response.headers.first(name: .contentType)?.hasPrefix("text/calendar") == true, response.headers.description)
            assertValidCalendar(response)
            // An unknown token stays a real 404 (not the SPA shell with 200).
            let unknown = try await app.testable().sendRequest(.GET, "/ics/" + Secrets.token() + ".ics")
            XCTAssertEqual(unknown.status, .notFound)
            XCTAssertFalse(unknown.body.string.contains("<title>shell</title>"))
        }
    }

    func testCalendarFeedContentIsValidAndIsolatedPerAccount() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let other = try await second(app, auth, context)
            for account in [context, other] { try await timeRequest(app, account, .POST, "work-models", modelBody("2026-01-01"), status: .created) }
            let start = berlinToday(offset: 10), end = berlinToday(offset: 12)
            try await timeRequest(app, context, .POST, "absences", absenceBody(start.description, end.description, status: "approved", extra: ["note": "alpha-private-note"]), status: .created)
            try await timeRequest(app, context, .POST, "absences", absenceBody(berlinToday(offset: 30).description, kind: "vacation", status: "requested"), status: .created)
            try await timeRequest(app, context, .POST, "absences", absenceBody(berlinToday(offset: 40).description, kind: "vacation", status: "rejected"), status: .created)
            try await timeRequest(app, context, .POST, "absences", absenceBody(berlinToday(offset: 50).description, kind: "other", status: "planned"), status: .created)
            try await timeRequest(app, other, .POST, "absences", absenceBody(berlinToday(offset: 20).description, status: "approved", extra: ["note": "bravo-private-note"]), status: .created)
            try await timeRequest(app, other, .PUT, "plan/days/" + berlinToday(offset: 5).description, ["mode": "office"])
            try await timeRequest(app, other, .POST, "calendar/custom-days", ["startDate": berlinToday(offset: 6).description, "endDate": berlinToday(offset: 6).description, "name": "Bravo Betriebsfest", "kind": "holiday"], status: .created)

            let feed = try await createFeed(app, context)
            let response = try await fetchFeed(app, feed.token)
            assertValidCalendar(response)
            let unfolded = response.body.string.replacingOccurrences(of: "\r\n ", with: "")
            // Approved range: all-day, exclusive end, status in the title.
            XCTAssertTrue(unfolded.contains("DTSTART;VALUE=DATE:\(compact(start))\r\nDTEND;VALUE=DATE:\(compact(end.addingDays(1)))\r\nSUMMARY:Urlaub (genehmigt)"), unfolded)
            XCTAssertTrue(unfolded.contains("DTSTART;VALUE=DATE:\(compact(berlinToday(offset: 30)))\r\nDTEND;VALUE=DATE:\(compact(berlinToday(offset: 31)))\r\nSUMMARY:Urlaub (beantragt)"))
            XCTAssertTrue(unfolded.contains("SUMMARY:Abwesenheit (geplant)"))
            XCTAssertEqual(unfolded.components(separatedBy: "SUMMARY:Urlaub").count - 1, 2, "rejected absence is not published")
            XCTAssertTrue(unfolded.contains("STATUS:TENTATIVE")); XCTAssertTrue(unfolded.contains("STATUS:CONFIRMED"))
            // Public holidays: the next 25.12. inside the window, with the exclusive end.
            let today = berlinToday()
            let christmasYear = today > (try LocalDate(year: today.year, month: 12, day: 25)) ? today.year + 1 : today.year
            let christmas = try LocalDate(year: christmasYear, month: 12, day: 25)
            XCTAssertTrue(unfolded.contains("DTSTART;VALUE=DATE:\(compact(christmas))\r\nDTEND;VALUE=DATE:\(compact(christmas.addingDays(1)))\r\nSUMMARY:1. Weihnachtstag"), unfolded)
            XCTAssertTrue(unfolded.contains("SUMMARY:2. Weihnachtstag"))
            // Only the owning account's data: no notes, nothing of the other account.
            XCTAssertFalse(unfolded.contains("alpha-private-note")); XCTAssertFalse(unfolded.contains("bravo-private-note"))
            XCTAssertFalse(unfolded.contains("Bravo")); XCTAssertFalse(unfolded.contains(compact(berlinToday(offset: 20)) + "\r\n"))
            // Default content has neither plan nor tracked time.
            XCTAssertFalse(unfolded.contains("SUMMARY:Plan:")); XCTAssertFalse(unfolded.contains("SUMMARY:Erfasst:"))
            // Window: nothing older than 60 days or beyond 400 days.
            let dates = unfolded.components(separatedBy: "\r\n").filter { $0.hasPrefix("DTSTART;VALUE=DATE:") }.map { String($0.suffix(8)) }
            let lowest = compact(berlinToday(offset: -CalendarFeedRules.pastDays - 366)), highest = compact(berlinToday(offset: CalendarFeedRules.futureDays + 366))
            XCTAssertTrue(dates.allSatisfy { $0 > lowest && $0 < highest })
            // The other account's feed shows its own data only.
            let otherFeed = try await createFeed(app, other, include: ["absences", "holidays", "plan"])
            let otherText = try await fetchFeed(app, otherFeed.token).body.string.replacingOccurrences(of: "\r\n ", with: "")
            XCTAssertTrue(otherText.contains("SUMMARY:Urlaub (genehmigt)")); XCTAssertTrue(otherText.contains("SUMMARY:Plan: Büro"))
            XCTAssertTrue(otherText.contains("SUMMARY:Bravo Betriebsfest"))
            XCTAssertFalse(otherText.contains(compact(start)))
            // The token of one account never yields another account's data: swapping a character is a plain 404.
            var forged = Array(feed.token); forged[5] = forged[5] == "a" ? "b" : "a"
            try await fetchFeed(app, String(forged), status: .notFound)
        }
    }

    func testCalendarFeedListsPlanBlocksWithoutPlacesOrNotes() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-01-01"), status: .created)
            let planDay = berlinToday(offset: 3)
            try await timeRequest(app, context, .PUT, "plan/days/" + planDay.description, ["mode": "office", "blocks": [
                ["start": "08:00", "end": "12:00", "kind": "school", "note": "block-private-note"],
                ["start": "13:00", "end": "17:00", "kind": "work"]]])
            let feed = try await createFeed(app, context, include: ["plan"])
            let text = try await fetchFeed(app, feed.token).body.string.replacingOccurrences(of: "\r\n ", with: "")
            XCTAssertTrue(text.contains("Blöcke: 08:00-12:00 Berufsschule\\; 13:00-17:00 Arbeit"), text)
            XCTAssertFalse(text.contains("block-private-note"))
        }
    }

    func testCalendarFeedPlanAndTrackedOptionsAndModules() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-01-01"), status: .created)
            let planDay = berlinToday(offset: 3)
            try await timeRequest(app, context, .PUT, "plan/days/" + planDay.description,
                                  ["mode": "home", "plannedStart": "08:00", "plannedEnd": "16:30", "plannedBreakMinutes": 30, "note": "plan-private-note"])
            let yesterday = berlinToday(offset: -1)
            try await timeRequest(app, context, .POST, "time/segments", segmentBody("\(yesterday)T07:00:00Z", "\(yesterday)T11:00:00Z"), status: .created)
            let feed = try await createFeed(app, context, include: ["plan", "tracked"])
            let text = try await fetchFeed(app, feed.token).body.string.replacingOccurrences(of: "\r\n ", with: "")
            assertValidCalendar(try await fetchFeed(app, feed.token))
            XCTAssertTrue(text.contains("DTSTART;VALUE=DATE:\(compact(planDay))\r\nDTEND;VALUE=DATE:\(compact(planDay.addingDays(1)))\r\nSUMMARY:Plan: Homeoffice"), text)
            XCTAssertTrue(text.contains("DESCRIPTION:Geplant 08:00-16:30\\, Pause 30 min"))
            XCTAssertFalse(text.contains("plan-private-note"))
            XCTAssertTrue(text.contains("UID:tracked-\(yesterday)@"))
            XCTAssertTrue(text.contains("SUMMARY:Erfasst: "))
            XCTAssertFalse(text.contains("SUMMARY:Urlaub")); XCTAssertFalse(text.contains("Weihnachtstag"))
            // With the planning module off, planning data (plan, absences, holidays) disappears; tracked time stays.
            try await setModules(app, context, ["planning": false])
            let off = try await fetchFeed(app, feed.token).body.string
            XCTAssertFalse(off.contains("SUMMARY:Plan:")); XCTAssertTrue(off.contains("SUMMARY:Erfasst: "))
        }
    }

    // MARK: HTTP behaviour

    func testCalendarFeedCachingHeadersAndConditionalGet() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let feed = try await createFeed(app, context)
            let first = try await fetchFeed(app, feed.token)
            let etag = try XCTUnwrap(first.headers.first(name: .eTag))
            XCTAssertTrue(etag.hasPrefix("\"") && etag.hasSuffix("\""))
            XCTAssertNotNil(first.headers.first(name: .lastModified))
            let cache = try XCTUnwrap(first.headers.first(name: .cacheControl))
            XCTAssertTrue(cache.contains("private")); XCTAssertFalse(cache.contains("no-store")); XCTAssertTrue(cache.contains("max-age="))
            XCTAssertEqual(first.headers.first(name: "Referrer-Policy"), "no-referrer")
            XCTAssertEqual(first.headers.first(name: "X-Robots-Tag"), "noindex, nofollow")
            XCTAssertEqual(first.headers.first(name: "X-Content-Type-Options"), "nosniff")
            let second = try await fetchFeed(app, feed.token)
            XCTAssertEqual(second.headers.first(name: .eTag), etag, "stable output gives a stable ETag")
            XCTAssertEqual(second.body.string, first.body.string)
            let conditional = try await fetchFeed(app, feed.token, headers: ["If-None-Match": etag], status: .notModified)
            XCTAssertEqual(conditional.headers.first(name: .eTag), etag)
            XCTAssertEqual(conditional.body.readableBytes, 0)
            try await fetchFeed(app, feed.token, headers: ["If-None-Match": "\"stale\""])
            // A change of the content changes the validator.
            try await timeRequest(app, context, .POST, "calendar/custom-days", ["startDate": berlinToday(offset: 4).description, "endDate": berlinToday(offset: 4).description, "name": "Betriebsfest", "kind": "holiday"], status: .created)
            let changed = try await fetchFeed(app, feed.token, headers: ["If-None-Match": etag])
            XCTAssertNotEqual(changed.headers.first(name: .eTag), etag)
        }
    }

    func testCalendarFeedUnknownRevokedExpiredAndNoOracle() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let feed = try await createFeed(app, context)
            let unknown = try await fetchFeed(app, Secrets.token(), status: .notFound)
            XCTAssertEqual(unknown.headers.first(name: .cacheControl), "no-store")
            let malformed = try await fetchFeed(app, "short", status: .notFound)
            let noSuffix = try await fetchFeed(app, feed.token, suffix: "", status: .notFound)
            let wrongSuffix = try await fetchFeed(app, feed.token, suffix: ".ical", status: .notFound)
            for response in [malformed, noSuffix, wrongSuffix] { XCTAssertEqual(response.body.string, unknown.body.string) }
            // Revoked, expired and disabled accounts are indistinguishable from unknown.
            try await timeRequest(app, context, .DELETE, "me/calendar-feeds/" + feed.id, status: .noContent)
            let gone_feed = try await fetchFeed(app, feed.token, status: .notFound).body.string
            XCTAssertEqual(gone_feed, unknown.body.string)
            let expiring = try await createFeed(app, context, label: "Expiring")
            let row = try await XCTUnwrapAsync(try await CalendarFeedRecord.find(UUID(uuidString: expiring.id), on: app.db))
            row.expiresAt = Date().addingTimeInterval(-1); try await row.update(on: app.db)
            let gone_expiring = try await fetchFeed(app, expiring.token, status: .notFound).body.string
            XCTAssertEqual(gone_expiring, unknown.body.string)
            let alive = try await createFeed(app, context, label: "Alive")
            try await fetchFeed(app, alive.token)
            let account = try await XCTUnwrapAsync(try await Account.find(context.account.requireID(), on: app.db))
            account.disabledAt = Date(); try await account.update(on: app.db)
            let gone_alive = try await fetchFeed(app, alive.token, status: .notFound).body.string
            XCTAssertEqual(gone_alive, unknown.body.string)
        }
    }

    func testCalendarFeedRateLimits() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let feed = try await createFeed(app, context)
            let now = Date()
            for _ in 0..<CalendarFeedRules.feedLimit { try await RateLimitEvent(key: "ics:" + feed.id.uppercased(), occurredAt: now).create(on: app.db) }
            let limited = try await fetchFeed(app, feed.token, status: .tooManyRequests)
            XCTAssertNotNil(limited.headers.first(name: .retryAfter))
        }
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let feed = try await createFeed(app, context)
            for _ in 0..<CalendarFeedRules.missLimit { try await fetchFeed(app, Secrets.token(), status: .notFound) }
            try await fetchFeed(app, Secrets.token(), status: .tooManyRequests)
            try await fetchFeed(app, feed.token, status: .tooManyRequests)
        }
    }

    func testCalendarFeedIsNotAnMCPToolAndIsErasedWithTheAccount() async throws {
        XCTAssertFalse(McpTools.all.map(\.name).contains { $0.contains("calendar") && !$0.contains("holiday") || $0.contains("feed") || $0.contains("ics") })
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let feed = try await createFeed(app, context)
            let export = try await timeRequest(app, context, .GET, "me/export")
            XCTAssertFalse(export.body.string.contains(feed.token))
            let credentialsRevoked = try await CalendarFeedRecord.query(on: app.db).filter(\.$revokedAt == nil).count()
            XCTAssertEqual(credentialsRevoked, 1)
            try await AccountEraser.revokeCredentials(of: context.account.requireID(), on: app.db)
            try await fetchFeed(app, feed.token, status: .notFound)
        }
    }

    // MARK: Holidays in the week overview

    func testWeekOverviewNamesHolidaysOnWeekendsAndOutsideModels() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-01-01"), status: .created)
            let week = try object(await timeRequest(app, context, .GET, "time/weeks/2026-W52"))
            let days = try XCTUnwrap(week["days"] as? [[String: Any]])
            let byDate = Dictionary(uniqueKeysWithValues: days.map { ($0["date"] as! String, $0) })
            XCTAssertEqual(byDate["2026-12-25"]?["holidayName"] as? String, "1. Weihnachtstag")
            XCTAssertEqual(byDate["2026-12-25"]?["mark"] as? String, "holiday")
            // 26.12.2026 is a Saturday: no consumed day (mark off) but the holiday stays visible.
            XCTAssertEqual(byDate["2026-12-26"]?["holidayName"] as? String, "2. Weihnachtstag")
            XCTAssertEqual(byDate["2026-12-26"]?["mark"] as? String, "off")
            XCTAssertTrue(byDate["2026-12-24"]?["holidayName"] is NSNull)
            XCTAssertTrue(byDate["2026-12-24"]?["holidayName"] != nil)
            // Before the first work model the day has no mark, but the holiday is still named.
            let early = try object(await timeRequest(app, context, .GET, "time/weeks/2025-W52"))
            let earlyDays = try XCTUnwrap(early["days"] as? [[String: Any]])
            XCTAssertTrue(earlyDays.contains { $0["holidayName"] as? String == "1. Weihnachtstag" })
            // Without the planning module there is no holiday information.
            try await setModules(app, context, ["planning": false])
            let offWeek = try object(await timeRequest(app, context, .GET, "time/weeks/2026-W52"))
            let off = try XCTUnwrap(offWeek["days"] as? [[String: Any]])
            XCTAssertTrue(off.allSatisfy { $0["holidayName"] is NSNull })
        }
    }
}
