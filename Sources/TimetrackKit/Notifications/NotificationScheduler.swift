import Foundation
import Fluent
import Vapor

/// Time zone handling for one account: the zone of the effective work model, else Europe/Berlin (ADR-0010).
struct LocalClock: Sendable {
    let timeZone: TimeZone
    var gregorian: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = timeZone; return c }
    var iso: Calendar { var c = Calendar(identifier: .iso8601); c.timeZone = timeZone; c.locale = Locale(identifier: "en_US_POSIX"); return c }

    func dateString(_ date: Date) -> String {
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    func time(_ date: Date) -> String {
        let c = gregorian.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
    func minutesOfDay(_ date: Date) -> Int {
        let c = gregorian.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    /// 1 = Monday ... 7 = Sunday.
    func isoWeekday(_ date: Date) -> Int { (gregorian.component(.weekday, from: date) + 5) % 7 + 1 }
    /// ISO year, week and the seven local dates (Monday first).
    func isoWeek(_ date: Date) -> (year: Int, week: Int, days: [String]) {
        let calendar = iso
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let start = calendar.date(from: c) ?? date
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.map(dateString)
        return (c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0, days)
    }
    func inQuietHours(_ date: Date, start: String?, end: String?) -> Bool {
        guard let start, let end, let from = NotificationSettingsDTO.minutes(start), let to = NotificationSettingsDTO.minutes(end), from != to else { return false }
        let now = minutesOfDay(date)
        return from < to ? (now >= from && now < to) : (now >= from || now < to)
    }
    /// The next local `end` time after `date` (DST safe: nonexistent local times move forward).
    func quietEnd(after date: Date, end: String) -> Date {
        guard let minutes = NotificationSettingsDTO.minutes(end) else { return date }
        return gregorian.nextDate(after: date, matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0), matchingPolicy: .nextTime) ?? date.addingTimeInterval(8 * 3600)
    }
    static func resolve(account: UUID, now: Date, on db: any Database) async throws -> LocalClock {
        let fallback = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        var utc = Calendar(identifier: .gregorian); utc.timeZone = .gmt
        let c = utc.dateComponents([.year, .month, .day], from: now)
        let today = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let models = try await WorkModelRecord.query(on: db).filter(\.$accountId == account).filter(\.$validFrom <= today).sort(\.$validFrom, .descending).all()
        let model = models.first { $0.validTo == nil || ($0.validTo ?? "") >= today }
        let zone = model?.payload.timezone.flatMap { TimeZone(identifier: $0) } ?? fallback
        return LocalClock(timeZone: zone)
    }
}

/// Creates reminders, enqueues push messages and delivers the outbox. All state lives in the database, so `runOnce` is idempotent.
struct NotificationScheduler: Sendable {
    let auth: AuthService
    let db: any Database
    let vapid: VapidConfiguration?
    let transport: any PushTransport
    let logger: Logger

    func runOnce(now: Date = Date()) async {
        let accounts: [UUID]
        do { accounts = try await Account.query(on: db).filter(\.$disabledAt == nil).all().compactMap(\.id) }
        catch { logger.warning("notification scheduler: account lookup failed (\(type(of: error)))"); return }
        for account in accounts {
            do { try await auth.transaction(on: db) { tx in try await Self.remind(account, now: now, vapid: vapid != nil, on: tx) } }
            catch { logger.warning("notification scheduler: reminders failed for one account (\(type(of: error)))") }
        }
        if let vapid {
            do { try await PushDispatcher(db: db, sender: .init(vapid: vapid, transport: transport)).deliverDue(now: now) }
            catch { logger.warning("notification scheduler: push delivery failed (\(type(of: error)))") }
        }
    }

    // MARK: Reminders

    private struct Context {
        let account: UUID, now: Date, clock: LocalClock, settings: NotificationSettingsDTO, pushAvailable: Bool, db: any Database
    }

    static func remind(_ account: UUID, now: Date, vapid: Bool, on db: any Database) async throws {
        let settings = try await NotificationService.effectiveSettings(account, on: db)
        let context = Context(account: account, now: now, clock: try await LocalClock.resolve(account: account, now: now, on: db),
                              settings: settings, pushAvailable: vapid, db: db)
        for kind in NotificationKind.reminders {
            guard let category = settings.categories[kind], category.inApp || category.push else { continue }
            switch kind {
            case "running_timer": try await runningTimer(context, category)
            case "pending_suggestions": try await pendingSuggestions(context, category)
            case "report_gap": try await reportGap(context, category)
            default: try await documentSubmission(context, category)
            }
        }
    }

    private static func runningTimer(_ c: Context, _ category: NotificationCategorySettings) async throws {
        let threshold = TimeInterval((category.thresholdMinutes ?? 600) * 60)
        let rows = try await SegmentRecord.query(on: c.db).filter(\.$accountId == c.account).filter(\.$endedAt == nil).filter(\.$voidedAt == nil).all()
        for row in rows where c.now.timeIntervalSince(row.startedAt) >= threshold {
            let minutes = Int(c.now.timeIntervalSince(row.startedAt) / 60)
            try await emit(c, kind: "running_timer", key: "running_timer:" + (row.id?.uuidString ?? ""), category: category,
                           title: "Timer läuft noch",
                           body: "Dein Timer läuft seit \(c.clock.time(row.startedAt)) Uhr (\(minutes / 60) Std. \(String(format: "%02d", minutes % 60)) Min.). Hast du vergessen, ihn zu stoppen?",
                           url: "/")
        }
    }

    private static func pendingSuggestions(_ c: Context, _ category: NotificationCategorySettings) async throws {
        let rows = try await SuggestionRecord.query(on: c.db).filter(\.$accountId == c.account).filter(\.$resolvedAt == nil).all()
        let open = rows.filter { c.now.timeIntervalSince($0.payload.createdAt) >= 30 * 60 }
        guard !open.isEmpty else { return }
        let recent = try await NotificationRecord.query(on: c.db).filter(\.$accountId == c.account).filter(\.$kind == "pending_suggestions")
            .filter(\.$createdAt > c.now.addingTimeInterval(-6 * 3600)).count()
        guard recent == 0 else { return }
        let body = open.count == 1 ? "Ein Vorschlag wartet auf deine Entscheidung." : "\(open.count) Vorschläge warten auf deine Entscheidung."
        try await emit(c, kind: "pending_suggestions", key: "pending_suggestions:\(Int(c.now.timeIntervalSince1970))", category: category,
                       title: "Offene Vorschläge", body: body, url: "/")
    }

    private static func reportGap(_ c: Context, _ category: NotificationCategorySettings) async throws {
        let weekday = category.weekday ?? 5, minutes = NotificationSettingsDTO.minutes(category.time ?? "15:00") ?? 900
        let today = c.clock.isoWeekday(c.now)
        guard today > weekday || (today == weekday && c.clock.minutesOfDay(c.now) >= minutes) else { return }
        let week = c.clock.isoWeek(c.now)
        if let status = try await ReportWeekStatusRecord.query(on: c.db).filter(\.$accountId == c.account).filter(\.$isoYear == week.year).filter(\.$isoWeek == week.week).first(),
           status.status == "done" { return }
        let entries = try await ReportEntryRecord.query(on: c.db).filter(\.$accountId == c.account).filter(\.$date >= week.days[0]).filter(\.$date <= week.days[6]).count()
        guard entries == 0 else { return }
        try await emit(c, kind: "report_gap", key: String(format: "report_gap:%04d-W%02d", week.year, week.week), category: category,
                       title: "Berichtsheft-Erinnerung",
                       body: "Für die Kalenderwoche \(week.week) hast du noch keine Berichtsheft-Einträge.", url: "/reports")
    }

    private static func documentSubmission(_ c: Context, _ category: NotificationCategorySettings) async throws {
        let rows = try await AbsenceRecord.query(on: c.db).filter(\.$accountId == c.account).filter(\.$documentStatus == "pending")
            .filter(\.$createdAt <= c.now.addingTimeInterval(-3 * 86400)).all()
        let day = c.clock.dateString(c.now)
        for row in rows {
            guard AbsenceStatus(rawValue: row.status)?.isActive ?? true else { continue }
            try await emit(c, kind: "document_submission", key: "document_submission:\(row.id?.uuidString ?? ""):\(day)", category: category,
                           title: "Unterlagen offen",
                           body: "Für deine Abwesenheit vom \(german(row.startDate)) bis \(german(row.endDate)) fehlt noch der Nachweis.", url: "/absences")
        }
    }

    private static func german(_ iso: String) -> String {
        let p = iso.split(separator: "-"); return p.count == 3 ? "\(p[2]).\(p[1]).\(p[0])" : iso
    }

    /// Creates the notification once per dedup key; `inApp=false` stores it hidden (soft-deleted) to anchor push and dedup.
    private static func emit(_ c: Context, kind: String, key: String, category: NotificationCategorySettings, title: String, body: String, url: String) async throws {
        guard try await NotificationRecord.query(on: c.db).filter(\.$accountId == c.account).filter(\.$dedupKey == key).count() == 0 else { return }
        let row = NotificationRecord()
        row.accountId = c.account; row.kind = kind; row.title = title; row.body = body; row.url = url; row.dedupKey = key
        row.createdAt = c.now; row.deletedAt = category.inApp ? nil : c.now
        try await row.create(on: c.db)
        guard category.push, c.pushAvailable else { return }
        let deferUntil = c.clock.inQuietHours(c.now, start: c.settings.quietStart, end: c.settings.quietEnd)
            ? c.settings.quietEnd.map { c.clock.quietEnd(after: c.now, end: $0) } : nil
        for subscription in try await PushSubscriptionRecord.query(on: c.db).filter(\.$accountId == c.account).all() {
            let item = PushOutboxRecord()
            item.notificationId = try row.requireID(); item.subscriptionId = try subscription.requireID()
            item.status = deferUntil == nil ? "pending" : "deferred"; item.attempts = 0; item.nextAttemptAt = deferUntil ?? c.now; item.createdAt = c.now
            try await item.create(on: c.db)
        }
    }
}

/// Delivers due outbox rows: 404/410 remove the subscription, 429/5xx retry with backoff (3 attempts), everything else fails.
struct PushDispatcher: Sendable {
    static let maxAttempts = 3
    let db: any Database
    let sender: PushSender

    func deliverDue(now: Date) async throws {
        let due = try await PushOutboxRecord.query(on: db).filter(\.$status ~~ ["pending", "deferred"]).filter(\.$nextAttemptAt <= now)
            .sort(\.$nextAttemptAt).limit(100).all()
        for item in due {
            guard let subscription = try await PushSubscriptionRecord.find(item.subscriptionId, on: db),
                  let notification = try await NotificationRecord.find(item.notificationId, on: db) else {
                item.status = "failed"; item.errorCode = "subscription_removed"; try await item.update(on: db); continue
            }
            let message = PushMessage(kind: notification.kind, url: notification.url ?? "/", tag: notification.dedupKey)
            let outcome = await sender.deliver(message, endpoint: subscription.endpoint, p256dh: subscription.p256dh, auth: subscription.auth, now: now)
            item.attempts += 1
            switch outcome {
            case .delivered: item.status = "sent"; item.errorCode = nil
            case .gone: item.status = "failed"; item.errorCode = "gone"
            case .failed(let code): item.status = "failed"; item.errorCode = code
            case .retry(let code):
                item.errorCode = code
                if item.attempts >= Self.maxAttempts { item.status = "failed" }
                else { item.status = "pending"; item.nextAttemptAt = now.addingTimeInterval(60 * pow(5, Double(item.attempts - 1))) }
            }
            if outcome != .gone { try await item.update(on: db) }
            try await Self.record(outcome, subscription: subscription.requireID(), now: now, on: db)
        }
    }

    static func record(_ outcome: PushOutcome, subscription id: UUID, now: Date, on db: any Database) async throws {
        guard let row = try await PushSubscriptionRecord.find(id, on: db) else { return }
        switch outcome {
        case .delivered: row.lastSuccessAt = now; row.failureCount = 0; try await row.update(on: db)
        case .gone: try await NotificationService.remove(row, on: db)
        case .retry, .failed: row.failureCount += 1; try await row.update(on: db)
        }
    }
}
