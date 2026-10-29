import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// C3 (ADR-0032): absence statuses per kind, balance without the running day, ICS marks, account e-mail as recovery address.
final class AbsenceSemanticsUnitTests: XCTestCase {
    func testNormalisationMatrix() throws {
        for status in [AbsenceStatus.planned, .requested, .approved, .taken, .recorded] {
            XCTAssertEqual(try AbsenceSemantics.normalise(kind: .sick, status: status), .recorded)
            XCTAssertEqual(try AbsenceSemantics.normalise(kind: .excused, status: status), .recorded)
        }
        XCTAssertEqual(try AbsenceSemantics.normalise(kind: .sick, status: .cancelled), .cancelled)
        XCTAssertEqual(try AbsenceSemantics.normalise(kind: .other, status: .requested), .planned)
        XCTAssertEqual(try AbsenceSemantics.normalise(kind: .other, status: .approved), .recorded)
        XCTAssertEqual(try AbsenceSemantics.normalise(kind: .other, status: .taken), .recorded)
        for status in [AbsenceStatus.planned, .requested, .approved, .rejected, .cancelled, .taken] {
            XCTAssertEqual(try AbsenceSemantics.normalise(kind: .vacation, status: status), status)
        }
        for kind in [AbsenceKind.sick, .excused, .other] {
            XCTAssertThrowsError(try AbsenceSemantics.normalise(kind: kind, status: .rejected))
        }
        XCTAssertThrowsError(try AbsenceSemantics.normalise(kind: .vacation, status: .recorded))
        XCTAssertTrue(AbsenceStatus.recorded.isBooked && AbsenceStatus.recorded.isActive)
    }

    func testIcsLabels() {
        XCTAssertEqual(CalendarFeedBuilder.absenceLabel(kind: "sick", status: "recorded"), "Krank")
        XCTAssertEqual(CalendarFeedBuilder.absenceLabel(kind: "sick", status: "approved"), "Krank")
        XCTAssertEqual(CalendarFeedBuilder.absenceLabel(kind: "excused", status: "recorded"), "Freigestellt")
        XCTAssertEqual(CalendarFeedBuilder.absenceLabel(kind: "vacation", status: "approved"), "Urlaub (genehmigt)")
    }
}

extension AuthTests {
    private func c3Today(_ offset: Int = 0) -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return LocalDate.local(Date(), calendar: calendar).addingDays(offset)
    }

    func testAbsenceStatusPerKindOverREST() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-01-01"), status: .created)
            // Legacy client: approved for sick is accepted and stored as recorded.
            let sick = try object(await timeRequest(app, context, .POST, "absences", absenceBody("2031-03-03", kind: "sick", status: "approved"), status: .created))
            XCTAssertEqual(sick["status"] as? String, "recorded")
            // No status at all: recorded for sick, planned for vacation.
            let noStatus: [String: Any] = ["kind": "sick", "startDate": "2031-03-05", "endDate": "2031-03-05"]
            let noStatusResult = try object(await timeRequest(app, context, .POST, "absences", noStatus, status: .created))
            XCTAssertEqual(noStatusResult["status"] as? String, "recorded")
            let vac: [String: Any] = ["kind": "vacation", "startDate": "2031-03-10", "endDate": "2031-03-10"]
            let vacResult = try object(await timeRequest(app, context, .POST, "absences", vac, status: .created))
            XCTAssertEqual(vacResult["status"] as? String, "planned")
            let excused = try object(await timeRequest(app, context, .POST, "absences", absenceBody("2031-03-12", kind: "excused", status: "requested"), status: .created))
            XCTAssertEqual(excused["status"] as? String, "recorded")
            let other = try object(await timeRequest(app, context, .POST, "absences", absenceBody("2031-03-14", kind: "other", status: "requested"), status: .created))
            XCTAssertEqual(other["status"] as? String, "planned")
            // Invalid combinations are 400 with a clear code.
            for body in [absenceBody("2031-04-01", kind: "sick", status: "rejected"), absenceBody("2031-04-02", kind: "vacation", status: "recorded"),
                         absenceBody("2031-04-03", kind: "other", status: "rejected")] {
                let response = try await timeRequest(app, context, .POST, "absences", body, status: .badRequest)
                XCTAssertTrue(response.body.string.contains("absence_status_invalid_for_kind"), response.body.string)
            }
            // Vacation keeps the full workflow.
            for status in ["planned", "requested", "approved", "rejected", "cancelled", "taken"] {
                try await timeRequest(app, context, .POST, "absences", absenceBody("2032-05-03", kind: "vacation", status: status), status: .created)
                let items = try list(await api(app, context, .GET, "absences?from=2032-05-01&to=2032-05-31"))
                XCTAssertEqual(items.first?["status"] as? String, status)
                for item in items { try await timeRequest(app, context, .DELETE, "absences/" + (item["id"] as! String), status: .noContent) }
            }
            // Update of an existing sick entry with a legacy status is normalised too.
            let id = try XCTUnwrap(sick["id"] as? String), version = try XCTUnwrap(sick["version"] as? Int)
            let updated = try object(await timeRequest(app, context, .PUT, "absences/" + id, absenceBody("2031-03-03", kind: "sick", status: "taken"), extra: ["If-Match": "\(version)"]))
            XCTAssertEqual(updated["status"] as? String, "recorded")
            try await AbsenceRecord.query(on: app.db).delete() // the revert of the kind migration cannot copy excused rows
        }
    }

    func testRecordedSickDayActsLikeBookedSickAndMigrationNormalisesRows() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-01-01"), status: .created)
            try await timeRequest(app, context, .POST, "absences", absenceBody("2031-03-03", kind: "sick", status: "requested"), status: .created)
            let day = try object(await timeRequest(app, context, .GET, "time/days/2031-03-03"))
            XCTAssertEqual(day["mark"] as? String, "sick")
            // Rows written by an older build are normalised by the migration, keeping the old status.
            let id = UUID(), accountId = try context.account.requireID()
            let row = AbsenceRecord(); row.id = id; row.accountId = accountId; row.kind = "sick"; row.startDate = "2031-05-05"; row.endDate = "2031-05-05"
            row.halfDayStart = false; row.halfDayEnd = false; row.status = "approved"; row.documentStatus = "not_needed"; row.version = 1
            row.createdAt = Date(); row.updatedAt = Date()
            try await row.create(on: app.db)
            let oldOther = AbsenceRecord(); oldOther.id = UUID(); oldOther.accountId = accountId; oldOther.kind = "other"; oldOther.startDate = "2031-06-05"
            oldOther.endDate = "2031-06-05"; oldOther.halfDayStart = false; oldOther.halfDayEnd = false; oldOther.status = "approved"
            oldOther.documentStatus = "not_needed"; oldOther.version = 1; oldOther.createdAt = Date(); oldOther.updatedAt = Date()
            try await oldOther.create(on: app.db)
            let vacation = AbsenceRecord(); vacation.id = UUID(); vacation.accountId = accountId; vacation.kind = "vacation"; vacation.startDate = "2031-07-07"
            vacation.endDate = "2031-07-07"; vacation.halfDayStart = false; vacation.halfDayEnd = false; vacation.status = "approved"
            vacation.documentStatus = "not_needed"; vacation.version = 1; vacation.createdAt = Date(); vacation.updatedAt = Date()
            try await vacation.create(on: app.db)
            // Re-run the data part of the migration (the schema part already ran at startup).
            try await app.db.schema("absences").deleteField("legacy_status").update()
            try await NormaliseAbsenceStatuses().prepare(on: app.db)
            let migratedRow = try await AbsenceRecord.find(id, on: app.db)
            let migrated = try XCTUnwrap(migratedRow)
            XCTAssertEqual(migrated.status, "recorded"); XCTAssertEqual(migrated.legacyStatus, "approved")
            let migratedOther = try await AbsenceRecord.find(oldOther.id!, on: app.db)
            XCTAssertEqual(migratedOther?.status, "recorded")
            let untouchedRow = try await AbsenceRecord.find(vacation.id!, on: app.db)
            let untouched = try XCTUnwrap(untouchedRow)
            XCTAssertEqual(untouched.status, "approved"); XCTAssertNil(untouched.legacyStatus)
        }
    }

    func testAccountBalanceExcludesTheRunningDay() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let yesterday = c3Today(-1), today = c3Today()
            try await timeRequest(app, context, .POST, "work-models", modelBody(c3Today(-14).description), status: .created)
            let before = try object(await timeRequest(app, context, .GET, "time/account"))
            XCTAssertEqual(before["includesToday"] as? Bool, false)
            // A weekday today has a Soll; the balance must not contain it.
            let balance = try XCTUnwrap(before["balanceSeconds"] as? Int)
            let past = try object(await timeRequest(app, context, .GET, "time/account?asOf=\(yesterday)"))
            XCTAssertEqual(past["balanceSeconds"] as? Int, balance, "balance through today equals balance through yesterday")
            XCTAssertTrue(past["todayDeltaSeconds"] is NSNull || past["todayDeltaSeconds"] == nil)
            if today.isoWeekday <= 5 {
                let delta = try XCTUnwrap(before["todayDeltaSeconds"] as? Int)
                XCTAssertLessThan(delta, 0, "today's Soll is shown separately")
            }
            // An adjustment dated today counts at once.
            try await timeRequest(app, context, .POST, "time/account/adjustments", ["kind": "correction", "date": today.description, "seconds": 600, "reason": "test"], status: .created)
            let adjusted = try object(await timeRequest(app, context, .GET, "time/account"))
            XCTAssertEqual(adjusted["balanceSeconds"] as? Int, balance + 600)
            // Week and statistics carry the same fields.
            let week = try object(await timeRequest(app, context, .GET, "time/weeks/\(isoWeekLabel(today))"))
            let summary = try XCTUnwrap(week["summary"] as? [String: Any])
            XCTAssertEqual(summary["includesToday"] as? Bool, false)
            XCTAssertEqual(summary["accountBalanceAfterSeconds"] as? Int, balance + 600)
            let stats = try object(await timeRequest(app, context, .GET, "time/statistics?from=\(c3Today(-7))&to=\(today)&granularity=day"))
            XCTAssertEqual(stats["includesToday"] as? Bool, false)
            let buckets = try XCTUnwrap(stats["buckets"] as? [[String: Any]])
            XCTAssertEqual(buckets.last?["balanceSeconds"] as? Int, balance + 600)
        }
    }

    private func isoWeekLabel(_ date: LocalDate) -> String {
        let thursday = date.addingDays(-(date.isoWeekday - 1) + 3)
        let newYear = try! LocalDate(year: thursday.year, month: 1, day: 1)
        return String(format: "%04d-W%02d", thursday.year, newYear.distance(to: thursday) / 7 + 1)
    }

    func testCalendarFeedShowsSickExemptSchoolAndDayMarks() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            try await timeRequest(app, context, .POST, "work-models", modelBody("2026-01-01"), status: .created)
            let d = { (offset: Int) in self.c3Today(offset).description }
            try await timeRequest(app, context, .POST, "absences", absenceBody(d(3), kind: "sick", status: "approved", extra: ["note": "secret-sick-note"]), status: .created)
            try await timeRequest(app, context, .POST, "absences", absenceBody(d(5), d(6), kind: "excused", status: "requested"), status: .created)
            try await timeRequest(app, context, .POST, "absences", absenceBody(d(8), kind: "other", status: "planned"), status: .created)
            try await timeRequest(app, context, .PUT, "time/days/" + d(12), ["mark": "school_credit", "note": "secret-day-note"])
            try await timeRequest(app, context, .PUT, "time/days/" + d(20), ["mark": "sick"])
            try await timeRequest(app, context, .PUT, "plan/days/" + d(14), ["mode": "school"])
            try await timeRequest(app, context, .PUT, "plan/days/" + d(15), ["mode": "off"])
            let created = try object(await timeRequest(app, context, .POST, "me/calendar-feeds", ["label": "c3", "include": ["absences", "plan"]], status: .created))
            let token = try XCTUnwrap(created["token"] as? String)
            let response = try await app.testable().sendRequest(.GET, "/ics/" + token + ".ics")
            XCTAssertEqual(response.status, .ok)
            let text = response.body.string.replacingOccurrences(of: "\r\n ", with: "")
            let events = text.components(separatedBy: "BEGIN:VEVENT").dropFirst()
            func event(_ summary: String) -> String? { events.first { $0.contains("SUMMARY:\(summary)\r\n") } }
            XCTAssertNotNil(event("Krank")); XCTAssertFalse(text.contains("Krank ("))
            let excused = try XCTUnwrap(event("Freigestellt"))
            XCTAssertTrue(excused.contains("DTSTART;VALUE=DATE:\(c3Today(5).description.replacingOccurrences(of: "-", with: ""))"))
            XCTAssertTrue(excused.contains("DTEND;VALUE=DATE:\(c3Today(7).description.replacingOccurrences(of: "-", with: ""))"))
            XCTAssertNotNil(event("Abwesenheit (geplant)"))
            XCTAssertNotNil(event("Berufsschule"), "school day mark")
            XCTAssertEqual(events.filter { $0.contains("SUMMARY:Krank\r\n") }.count, 2, "sick absence and explicit sick day mark")
            XCTAssertNotNil(event("Plan: Berufsschule")); XCTAssertNotNil(event("Plan: Frei"))
            XCTAssertFalse(text.contains("secret-sick-note")); XCTAssertFalse(text.contains("secret-day-note"))
            // Revert of the kind migration cannot copy excused rows; leave no absences behind.
            try await AbsenceRecord.query(on: app.db).delete()
        }
    }

    func testRecoveryUsesTheAccountEmail() async throws {
        let sender = RecordingMailSender()
        try await withApp(environment: ["SMTP_HOST": "mail.test", "SMTP_FROM": "sender@example.test"], mail: sender) { app, service in
            let (context, _) = try await registered(service, db: app.db)
            // No account e-mail and no body: nothing to use.
            await expect("account_email_missing") { try await service.enableEmail(nil, context: context, on: app.db) }
            // Legacy body with an address: it is verified and becomes the account e-mail.
            let immediate = try await service.enableEmail("Mix@Example.test", context: context, on: app.db)
            XCTAssertFalse(immediate)
            try await service.verifyEmail(await sender.lastCode(), context: context, on: app.db)
            let accountRow = try await Account.find(context.account.requireID(), on: app.db)
            let account = try XCTUnwrap(accountRow)
            XCTAssertEqual(account.email, "mix@example.test"); XCTAssertNotNil(account.emailVerifiedAt)
            let refreshed = try await service.recoveryStatus(AuthContext(session: context.session, account: account, token: context.token), on: app.db)
            XCTAssertTrue(refreshed.email.active); XCTAssertTrue(refreshed.email.usesAccountEmail); XCTAssertEqual(refreshed.email.accountEmail, "mix@example.test")
            // Recovery codes go to the account address.
            let start = try await service.recoveryStart(.init(method: .email, identifier: account.handle), on: app.db)
            let code = await sender.lastCode()
            let address = await sender.lastAddress()
            XCTAssertEqual(address, "mix@example.test")
            _ = try await service.recoveryComplete(.init(recoveryId: start.recoveryId, proof: code), on: app.db)
            // A different address is refused while the account e-mail is verified; no body switches on at once.
            await expect("recovery_email_must_be_account_email") { try await service.enableEmail("other@example.test", context: context, on: app.db) }
            try await service.disableEmail(context, on: app.db)
            let active = try await service.enableEmail(nil, context: context, on: app.db)
            XCTAssertTrue(active)
            let rows = try await EmailRecovery.query(on: app.db).filter(\.$accountId == account.requireID()).count()
            XCTAssertEqual(rows, 1)
        }
    }

    func testMigrationFoldsSeparateRecoveryAddress() async throws {
        try await withApp { app, service in
            let (context, _) = try await registered(service, db: app.db)
            let id = try context.account.requireID()
            let accountRow = try await Account.find(id, on: app.db)
            let account = try XCTUnwrap(accountRow)
            // Unverified account e-mail plus verified recovery address: the verified one is adopted.
            account.email = "unverified@example.test"; account.emailVerifiedAt = nil; try await account.update(on: app.db)
            try await EmailRecovery(accountId: id, email: "verified@example.test", verifiedAt: Date(), active: true).create(on: app.db)
            try await UnifyRecoveryEmail().prepare(on: app.db)
            let adoptedRow = try await Account.find(id, on: app.db)
            let adopted = try XCTUnwrap(adoptedRow)
            XCTAssertEqual(adopted.email, "verified@example.test"); XCTAssertNotNil(adopted.emailVerifiedAt)
            // Verified account e-mail plus a different active recovery address: the account address wins.
            try await EmailRecovery.query(on: app.db).delete()
            try await EmailRecovery(accountId: id, email: "separate@example.test", verifiedAt: Date(), active: true).create(on: app.db)
            try await UnifyRecoveryEmail().prepare(on: app.db)
            let kept = try await EmailRecovery.query(on: app.db).first()
            XCTAssertEqual(kept?.email, "verified@example.test")
            // An unverified leftover is dropped.
            try await EmailRecovery.query(on: app.db).delete()
            try await EmailRecovery(accountId: id, email: "pending@example.test", active: false).create(on: app.db)
            try await UnifyRecoveryEmail().prepare(on: app.db)
            let left = try await EmailRecovery.query(on: app.db).count()
            XCTAssertEqual(left, 0)
        }
    }
}
