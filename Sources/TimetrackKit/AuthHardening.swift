import Vapor
import Fluent
import FluentSQL

// SEC-A (security review 2026-11-01, SEC-02/03/04/08/15): recovery lockout with backoff, mail quotas, asynchronous mail
// delivery, security notices, credential revocation after recovery and the fallback-password policy.

// MARK: Models and migrations

/// Failed recovery proofs per handle or client address. Unlike `RateLimitEvent` (pruned after ten minutes) the row keeps
/// the failure count for 24 hours so the lock can grow (exponential backoff). Keys are hashes, never raw handles or addresses.
final class RecoveryLockout: Model, @unchecked Sendable {
    static let schema = "recovery_lockouts"
    @ID(key: .id) var id: UUID?
    @Field(key: "key") var key: String
    @Field(key: "failures") var failures: Int
    @Field(key: "last_failure_at") var lastFailureAt: Date
    @OptionalField(key: "locked_until") var lockedUntil: Date?
    init() {}
    init(key: String, failures: Int, lastFailureAt: Date, lockedUntil: Date?) {
        id = UUID(); self.key = key; self.failures = failures; self.lastFailureAt = lastFailureAt; self.lockedUntil = lockedUntil
    }
}

/// One row per mail that left (or was about to leave) the server through a quota-controlled path. Keys are hashes.
final class MailQuotaEvent: Model, @unchecked Sendable {
    static let schema = "mail_quota_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "key") var key: String
    @Field(key: "sent_at") var sentAt: Date
    init() {}
    init(key: String, sentAt: Date) { id = UUID(); self.key = key; self.sentAt = sentAt }
}

enum AuthHardeningSchema {
    static let migrations: [any Migration] = [CreateRecoveryLockouts(), CreateMailQuotaEvents(), AddRecoveryAttemptLockKey()]
}

struct CreateRecoveryLockouts: AsyncMigration {
    let name = "seca.create_recovery_lockouts"
    func prepare(on db: any Database) async throws {
        try await db.schema(RecoveryLockout.schema).ignoreExisting().id()
            .field("key", .string, .required)
            .field("failures", .int, .required)
            .field("last_failure_at", .datetime, .required)
            .field("locked_until", .datetime)
            .unique(on: "key").create()
    }
    func revert(on db: any Database) async throws { try await db.schema(RecoveryLockout.schema).delete() }
}

struct CreateMailQuotaEvents: AsyncMigration {
    let name = "seca.create_mail_quota_events"
    func prepare(on db: any Database) async throws {
        try await db.schema(MailQuotaEvent.schema).ignoreExisting().id()
            .field("key", .string, .required)
            .field("sent_at", .datetime, .required).create()
    }
    func revert(on db: any Database) async throws { try await db.schema(MailQuotaEvent.schema).delete() }
}

/// Hash of the handle the attempt was started for, also for unknown handles, so a lock cannot reveal whether a handle exists.
struct AddRecoveryAttemptLockKey: AsyncMigration {
    let name = "seca.add_recovery_attempt_lock_key"
    func prepare(on db: any Database) async throws {
        if !(await columnExists(db, table: RecoveryAttempt.schema, column: "lock_key")) {
            try await db.schema(RecoveryAttempt.schema).field("lock_key", .string).update()
        }
    }
    func revert(on db: any Database) async throws { try await db.schema(RecoveryAttempt.schema).deleteField("lock_key").update() }
}

// MARK: Mail outbox

/// Sends mail after the HTTP response is decided, so response time does not depend on the SMTP round trip (SEC-04).
/// `drain()` lets tests wait for everything that was queued.
actor MailOutbox {
    static let shared = MailOutbox()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    func submit(_ work: @escaping @Sendable () async -> Void) {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await work()
            await self?.finish(id)
        }
    }
    private func finish(_ id: UUID) { tasks[id] = nil }
    func drain() async {
        while let (id, task) = tasks.first { await task.value; tasks[id] = nil }
    }
}

// MARK: Security notices

public enum SecurityNotice: String, Sendable {
    /// A recovery proof was accepted (a recovery session was issued).
    case recoveryCompleted
    /// Repeated failed recovery proofs triggered a lock.
    case recoveryFailures
    /// A passkey was added from a recovery session; other sessions, OAuth grants and tokens were ended.
    case recoveryFinished
    /// A passkey was revoked; other sessions were ended.
    case passkeyRevoked
}

extension MailSender {
    /// Default: silent. `SMTPMailSender` sends the notice.
    public func sendNotice(_ notice: SecurityNotice, to address: String) async throws {}
}

extension MailTemplates {
    static func securityNotice(_ notice: SecurityNotice, brand: MailBrand) -> RenderedMail {
        let subject: String, title: String, paragraphs: [String], note: String
        switch notice {
        case .recoveryCompleted:
            subject = "Wiederherstellung deines Kontos"
            title = "Wiederherstellung durchgeführt"
            paragraphs = ["Für dein Konto in \(brand.productName) wurde soeben ein Nachweis zur Wiederherstellung akzeptiert. Damit kann ein neuer Passkey angelegt werden."]
            note = "Warst du das nicht, melde dich mit einem vorhandenen Passkey an und beende unter „Konto & Sicherheit“ alle anderen Sitzungen. Ändere danach die Wiederherstellungswege."
        case .recoveryFailures:
            subject = "Fehlgeschlagene Wiederherstellungsversuche"
            title = "Fehlgeschlagene Versuche"
            paragraphs = ["Für dein Konto in \(brand.productName) wurden mehrere falsche Nachweise zur Wiederherstellung eingegeben. Weitere Versuche sind für kurze Zeit gesperrt."]
            note = "Warst du das nicht, nutzt jemand möglicherweise deinen Benutzernamen. Prüfe deine Wiederherstellungswege unter „Konto & Sicherheit“ und ersetze ein Rückfallpasswort, falls du eines eingerichtet hast."
        case .recoveryFinished:
            subject = "Konto wiederhergestellt, andere Sitzungen beendet"
            title = "Konto wiederhergestellt"
            paragraphs = ["Nach der Wiederherstellung wurde für dein Konto in \(brand.productName) ein neuer Passkey angelegt.",
                          "Aus Sicherheitsgründen wurden alle anderen Sitzungen, verbundene KI-Zugänge (OAuth) und persönliche Zugriffstoken beendet. Auslöse-Links und Kalender-Abos bleiben bestehen; prüfe sie unter „Konto & Sicherheit“."]
            note = "Warst du das nicht, wende dich umgehend an die Betreiberin oder den Betreiber dieser Instanz."
        case .passkeyRevoked:
            subject = "Ein Passkey wurde widerrufen"
            title = "Passkey widerrufen"
            paragraphs = ["In deinem Konto in \(brand.productName) wurde ein Passkey widerrufen. Alle anderen Sitzungen wurden beendet; auf anderen Geräten musst du dich neu anmelden."]
            note = "Warst du das nicht, melde dich neu an und prüfe deine Passkeys und Wiederherstellungswege unter „Konto & Sicherheit“."
        }
        var blocks = paragraphs.map { MailBlock.paragraph($0) }
        if let base = brand.baseURL?.absoluteString { blocks.append(.button(label: "\(brand.productName) öffnen", url: base)) }
        let document = MailDocument(title: title, preheader: subject, blocks: blocks, securityNote: note)
        let text = ([title] + paragraphs + [note]).joined(separator: "\n\n")
        return RenderedMail(subject: subject, text: text, html: html(document, brand: brand))
    }
}

// MARK: Mail quota (SEC-04, SEC-08)

enum MailQuota {
    static let globalPerHour = 500
    /// Recovery codes: at most one per minute per account, so a flood against a third party stays small.
    static let recoveryCooldown: TimeInterval = 60
    static let perAddressPerHour = 5, perAddressPerDay = 20
    static let perAccountPerHour = 5, perAccountPerDay = 20
    static let noticesPerAccountPerHour = 3, noticesPerAccountPerDay = 10
}

extension AuthService {
    enum MailScope: Sendable { case code, recovery, notice }

    /// Charges the mail quota and tells whether the mail may be sent. Call inside the auth transaction (the auth lock
    /// serialises concurrent reservations). Code mails: 5 per hour and 20 per day per target address and per account
    /// (recovery codes additionally 1 per minute per account), 500 per hour for the whole server. Notices have their own, smaller account budget
    /// so they cannot be used to starve code mails.
    func reserveMail(to address: String?, account: UUID?, scope: MailScope = .code, on db: any Database) async throws -> Bool {
        let now = Date()
        // key, cooldown, hourly limit, daily limit
        var rules: [(String, TimeInterval?, Int, Int?)] = [("mail:global", nil, MailQuota.globalPerHour, nil)]
        switch scope {
        case .code, .recovery:
            if scope == .recovery, let account { rules.append(("mail:recovery:" + account.uuidString, MailQuota.recoveryCooldown, MailQuota.perAccountPerHour, nil)) }
            if let address { rules.append(("mail:addr:" + Secrets.hash(address.lowercased()), nil, MailQuota.perAddressPerHour, MailQuota.perAddressPerDay)) }
            if let account { rules.append(("mail:acct:" + account.uuidString, nil, MailQuota.perAccountPerHour, MailQuota.perAccountPerDay)) }
        case .notice:
            if let account { rules.append(("mail:notice:" + account.uuidString, nil, MailQuota.noticesPerAccountPerHour, MailQuota.noticesPerAccountPerDay)) }
        }
        for (key, cooldown, hourly, daily) in rules {
            let events = MailQuotaEvent.query(on: db).filter(\.$key == key)
            if let cooldown, try await events.copy().filter(\.$sentAt > now.addingTimeInterval(-cooldown)).count() >= 1 { return false }
            if try await events.copy().filter(\.$sentAt > now.addingTimeInterval(-3600)).count() >= hourly { return false }
            if let daily, try await events.copy().filter(\.$sentAt > now.addingTimeInterval(-86400)).count() >= daily { return false }
        }
        for (key, _, _, _) in rules { try await MailQuotaEvent(key: key, sentAt: now).create(on: db) }
        try await MailQuotaEvent.query(on: db).filter(\.$sentAt < now.addingTimeInterval(-90000)).delete()
        return true
    }

    /// Queues a notice for the verified account address, subject to the notice budget. Never throws: delivery is best effort.
    func notify(_ notice: SecurityNotice, account id: UUID, on db: any Database) async {
        guard mailAvailable, let mailSender else { return }
        guard let address: String = try? await transaction(on: db, { tx -> String? in
            guard let account = try await Account.find(id, on: tx), account.disabledAt == nil,
                  let mail = account.email, account.emailVerifiedAt != nil,
                  try await reserveMail(to: nil, account: id, scope: .notice, on: tx) else { return nil }
            return mail
        }) else { return }
        await MailOutbox.shared.submit { try? await mailSender.sendNotice(notice, to: address) }
    }
}

// MARK: Recovery lockout (SEC-03)

enum RecoveryLockPolicy {
    /// Failures per handle before the first lock; every further failure doubles the lock (1 minute, 2, 4, ... up to one hour).
    static let freeFailuresPerHandle = 5
    /// Failures per client address across all handles.
    static let freeFailuresPerAddress = 20
    static let window: TimeInterval = 86400
    static let maxLock: TimeInterval = 3600
    static func handleKey(_ handle: String) -> String { "h:" + Secrets.hash(handle.lowercased()) }
    static func addressKey(_ ip: String) -> String { "i:" + Secrets.hash(ip) }
}

extension AuthService {
    /// True when any of the keys is locked. Keys of unknown handles behave exactly like known ones.
    func recoveryLocked(_ keys: [String], on db: any Database) async throws -> Bool {
        let now = Date()
        for key in keys {
            if let row = try await RecoveryLockout.query(on: db).filter(\.$key == key).first(), let until = row.lockedUntil, until > now { return true }
        }
        return false
    }

    /// Records one failed proof for each key and returns the new failure counts (same order). Locks once a key
    /// exceeds its free failures; the failure window of 24 hours restarts the count.
    @discardableResult
    func recordRecoveryFailure(_ keys: [(key: String, free: Int)], on db: any Database) async throws -> [Int] {
        try await transaction(on: db) { tx in
            let now = Date()
            var counts: [Int] = []
            for (key, free) in keys {
                let row = try await RecoveryLockout.query(on: tx).filter(\.$key == key).first() ?? RecoveryLockout(key: key, failures: 0, lastFailureAt: now, lockedUntil: nil)
                if now.timeIntervalSince(row.lastFailureAt) > RecoveryLockPolicy.window { row.failures = 0; row.lockedUntil = nil }
                row.failures += 1; row.lastFailureAt = now
                if row.failures >= free {
                    let seconds = min(RecoveryLockPolicy.maxLock, 60 * pow(2, Double(min(row.failures - free, 12))))
                    row.lockedUntil = now.addingTimeInterval(seconds)
                }
                try await row.save(on: tx)
                counts.append(row.failures)
            }
            try await RecoveryLockout.query(on: tx).filter(\.$lastFailureAt < now.addingTimeInterval(-RecoveryLockPolicy.window)).delete()
            return counts
        }
    }

    func clearRecoveryFailures(_ key: String, on db: any Database) async throws {
        try await RecoveryLockout.query(on: db).filter(\.$key == key).delete()
    }
}

// MARK: Fallback password policy (SEC-03)

enum FallbackPasswordPolicy {
    static let minimumLength = 16
    static let maximumLength = 256
    /// Normalised (lower case, letters and digits only) common passwords and phrases. Not exhaustive: the length rule and the
    /// diversity checks carry most of the weight; the list catches the well-known 16+ character choices.
    static let common: Set<String> = [
        "correcthorsebatterystaple", "passwordpassword", "password12345678", "passwort1234567890", "passwortpasswort",
        "1234567890123456", "12345678901234567890", "qwertzuiopasdfghjkl", "qwertyuiopasdfghjkl", "qwertyuiopasdfgh",
        "qwertzuiopasdfgh", "abcdefghijklmnop", "abcdefghijklmnopqrstuvwxyz", "iloveyouiloveyou", "ichliebedichichliebedich",
        "letmeinletmein1234", "welcomewelcome1234", "willkommenwillkommen", "administratoradministrator", "timetracktimetrack",
        "timetrackpassword", "timetrackpasswort", "passwordpassword1234", "mypasswordismypassword", "thisisapassword123",
        "thisismypassword", "asdfghjklasdfghjkl", "zxcvbnmasdfghjkl", "1q2w3e4r5t6y7u8i", "1qaz2wsx3edc4rfv",
        "password1234567890", "passwort1234567890123", "aaaaaaaaaaaaaaaa", "0000000000000000", "1111111111111111",
    ]
    static func normalised(_ value: String) -> String { String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }

    /// Length, character variety, common choices, repetition and personal data (handle, name, e-mail local part).
    static func acceptable(_ password: String, handle: String, displayName: String, email: String?) -> Bool {
        guard (minimumLength...maximumLength).contains(password.count) else { return false }
        let characters = Array(password)
        guard Set(characters).count >= 8 else { return false }
        let plain = normalised(password)
        if common.contains(plain) { return false }
        // A short unit repeated over the whole password ("abcdabcdabcdabcd").
        let units = Array(plain)
        if units.count >= 8 {
            for size in 1...min(8, units.count / 2) where units.count % size == 0 {
                let unit = Array(units[0..<size])
                if stride(from: 0, to: units.count, by: size).allSatisfy({ Array(units[$0..<$0 + size]) == unit }) { return false }
            }
        }
        // Mostly a run of consecutive keys or characters ("abcdefghijklmnopqr", "1234567890123456").
        if units.count >= 8 {
            let ascending = zip(units, units.dropFirst()).filter { pair in
                guard let low = pair.0.asciiValue, let high = pair.1.asciiValue else { return false }
                return high == low &+ 1
            }.count
            if ascending >= units.count - 2 { return false }
        }
        var personal = [handle, displayName, email?.split(separator: "@").first.map(String.init) ?? ""].map(normalised).filter { $0.count >= 4 }
        personal.append(contentsOf: displayName.split(separator: " ").map { normalised(String($0)) }.filter { $0.count >= 4 })
        if personal.contains(where: { plain.contains($0) }) { return false }
        return true
    }
}

// MARK: Credential revocation (SEC-02)

extension AuthService {
    /// Ends every session except `keeping`, all OAuth grants with their tokens and codes, and all personal API tokens and
    /// device tokens of the account. Trigger links and calendar feeds stay (they are listed in "Konto & Sicherheit").
    static func revokeAccess(of account: UUID, keepingSession keeping: UUID, on db: any Database, now: Date = Date()) async throws {
        try await Session.query(on: db).filter(\.$accountId == account).filter(\.$id != keeping).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
        try await DeviceTokenRecord.query(on: db).filter(\.$accountId == account).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
        try await ApiTokenRecord.query(on: db).filter(\.$accountId == account).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
        let grants = try await OAuthGrant.query(on: db).filter(\.$accountId == account).all().compactMap(\.id)
        try await OAuthGrant.query(on: db).filter(\.$accountId == account).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
        for chunk in grants.chunked(AccountEraser.chunkSize) {
            try await OAuthToken.query(on: db).filter(\.$grantId ~~ chunk).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
        }
        try await OAuthCode.query(on: db).filter(\.$accountId == account).filter(\.$consumedAt == nil).set(\.$consumedAt, to: now).update()
    }

    /// Ends every other session of the account (used when a passkey is revoked).
    static func revokeOtherSessions(of account: UUID, keeping: UUID, on db: any Database, now: Date = Date()) async throws {
        try await Session.query(on: db).filter(\.$accountId == account).filter(\.$id != keeping).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
    }
}
