import Foundation
import Fluent
import Vapor

/// Anything that can send the fixed diagnostic test message (ADR-0022). `SMTPMailSender` is the production implementation.
protocol MailTestSender: Sendable {
    func sendTest(subject: String, body: String, to address: String) async throws
}
extension SMTPMailSender: MailTestSender {}

enum MailDiagnosis {
    static let checkLimit = 6, checkWindow: TimeInterval = 600
    static let testLimit = 3, testWindow: TimeInterval = 600
    static let recipientLimit = 3, recipientWindow: TimeInterval = 3600
    static let subject = "Timetrack: Testnachricht"

    /// Charges every key or none; false once one of them is exhausted.
    static func allow(_ auth: AuthService, db: any Database, _ keys: [(key: String, limit: Int, window: TimeInterval)]) async throws -> Bool {
        try await auth.transaction(on: db) { tx in
            let now = Date()
            for item in keys {
                let used = try await RateLimitEvent.query(on: tx).filter(\.$key == item.key).filter(\.$occurredAt > now.addingTimeInterval(-item.window)).count()
                if used >= item.limit { return false }
            }
            for item in keys { try await RateLimitEvent(key: item.key, occurredAt: now).create(on: tx) }
            return true
        }
    }

    static func body(by account: Account, at date: Date, baseURL: URL) -> String {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let local = DateFormatter()
        local.locale = Locale(identifier: "de_DE"); local.timeZone = TimeZone(secondsFromGMT: 0); local.dateFormat = "dd.MM.yyyy HH:mm 'Uhr (UTC)'"
        return """
        Dies ist eine Testnachricht von Timetrack.

        Ausgelöst von: \(account.displayName.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(String.init).joined())
        Zeitpunkt: \(local.string(from: date)) (\(iso.string(from: date)))
        Server: \(baseURL.absoluteString)

        Wenn du diese Nachricht lesen kannst, funktioniert der E-Mail-Versand dieses Servers. Du musst nichts weiter tun.
        """
    }

    static func apiError(_ kind: MailFailureKind) -> APIError {
        switch kind {
        case .auth: APIError(.badGateway, "mail_auth_failed")
        case .tls: APIError(.badGateway, "mail_tls_failed")
        case .sender: APIError(.badGateway, "mail_sender_rejected")
        case .recipient: APIError(.unprocessableEntity, "mail_recipient_rejected")
        case .timeout: APIError(.gatewayTimeout, "mail_timeout")
        case .connect: APIError(.badGateway, "mail_connect_failed")
        case .other: APIError(.badGateway, "mail_failed")
        }
    }

    static let messages: [String: String] = [
        "mail_auth_failed": "Der Mailserver hat die Anmeldung abgelehnt. Prüfe SMTP_USER und SMTP_PASSWORD.",
        "mail_tls_failed": "Die verschlüsselte Verbindung zum Mailserver ist fehlgeschlagen. Führe „Verbindung prüfen“ aus, um die Ursache zu sehen.",
        "mail_sender_rejected": "Der Mailserver lehnt die Absenderadresse (SMTP_FROM) ab oder verlangt eine Anmeldung.",
        "mail_recipient_rejected": "Der Mailserver nimmt die Empfängeradresse nicht an. Das kann bedeuten, dass der Server keine fremden Adressen weiterleitet (Relay verweigert).",
        "mail_timeout": "Der Mailserver hat nicht rechtzeitig geantwortet.",
        "mail_connect_failed": "Die Verbindung zum Mailserver konnte nicht aufgebaut werden. Führe „Verbindung prüfen“ aus.",
        "mail_failed": "Der Mailserver hat die Nachricht nicht angenommen. Führe „Verbindung prüfen“ aus.",
        "no_recipient": "Es ist keine Empfängeradresse angegeben und dein Konto hat keine bestätigte E-Mail-Adresse.",
    ]
}

/// Mail diagnosis for administrators (ADR-0022): status, live check and test mail. Settings stay environment-only.
func registerMailRoutes(_ app: Application, auth: AuthService) {
    let api = app.grouped("api", "v1").grouped(SessionMiddleware(service: auth))

    api.get("admin", "mail") { req async throws -> Response in
        try req.authContext.admin()
        return try timeResponse(MailStatusDTO.make(configuration: auth.configuration))
    }

    api.post("admin", "mail", "check") { req async throws -> Response in
        let context = try req.authContext; try context.admin()
        guard let smtp = auth.configuration.smtp else { throw APIError(.notImplemented, "not_implemented") }
        let id = try context.account.requireID()
        guard try await MailDiagnosis.allow(auth, db: req.db, [("mailcheck:" + id.uuidString, MailDiagnosis.checkLimit, MailDiagnosis.checkWindow)]) else {
            throw APIError(.tooManyRequests, "too_many_requests")
        }
        let overrides = req.application.storage[MailCheckOverridesKey.self]
        let result = await MailCheckRunner(configuration: smtp, group: req.application.eventLoopGroup, tls: overrides?.tls,
                                           limits: overrides?.limits ?? MailCheckLimits()).run()
        _ = try? await AccountAuditRecord(action: "mail.checked", actor: id, target: id).create(on: req.db)
        return try timeResponse(result)
    }

    api.post("admin", "mail", "test") { req async throws -> Response in
        let context = try req.authContext; try context.admin(); try context.fresh()
        let input = (req.body.data == nil) ? MailTestInput(to: nil) : try timeDecode(MailTestInput.self, request: req)
        guard auth.configuration.smtp != nil, let sender = auth.mailSender as? any MailTestSender else { throw APIError(.notImplemented, "not_implemented") }
        let id = try context.account.requireID()
        let recipient: String
        if let raw = input.to?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let normalized = AuthService.normalizedEmail(raw), SMTPConfiguration.validAddress(normalized) else { throw APIError.invalid }
            recipient = normalized
        } else if let own = context.account.email, context.account.emailVerifiedAt != nil {
            recipient = own
        } else { throw APIError(.badRequest, "no_recipient") }
        let hash = Secrets.hash("mail-test:" + recipient)
        guard try await MailDiagnosis.allow(auth, db: req.db, [
            ("mailtest:" + id.uuidString, MailDiagnosis.testLimit, MailDiagnosis.testWindow),
            ("mailtestto:" + hash, MailDiagnosis.recipientLimit, MailDiagnosis.recipientWindow)]) else { throw APIError(.tooManyRequests, "too_many_requests") }
        let started = ContinuousClock.now
        let now = Date()
        do {
            try await sender.sendTest(subject: MailDiagnosis.subject, body: MailDiagnosis.body(by: context.account, at: now, baseURL: auth.configuration.publicBaseURL), to: recipient)
        } catch SMTPError.failed(let kind) {
            throw MailDiagnosis.apiError(kind)
        } catch { throw MailDiagnosis.apiError(.other) }
        let elapsed = ContinuousClock.now - started
        _ = try? await AccountAuditRecord(action: "mail.test_sent", actor: id, target: id, detail: String(hash.prefix(16))).create(on: req.db)
        return try timeResponse(MailTestResult(sent: true, to: recipient, durationMs: MailCheckRunner.milliseconds(elapsed)))
    }
}
