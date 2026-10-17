import Foundation
import Vapor

/// Read-only view of the SMTP configuration for administrators (ADR-0022). Never carries the user name or the password.
struct MailHint: Content, Equatable {
    /// `info` or `warning`.
    let severity: String
    let code: String
    let message: String
}

struct MailStatusDTO: Content {
    let configured: Bool
    let host: String?
    let port: Int?
    /// `starttls`, `implicit` or `off`.
    let tls: String?
    let fromAddress: String?
    let fromName: String?
    /// True when a user name and password are set. The values themselves are never returned.
    let authConfigured: Bool
    /// The settings only live in the environment (secrets); the API cannot change them.
    let source: String
    let hints: [MailHint]

    static func make(configuration: Configuration) -> MailStatusDTO {
        guard let smtp = configuration.smtp else {
            return MailStatusDTO(configured: false, host: nil, port: nil, tls: nil, fromAddress: nil, fromName: nil, authConfigured: false,
                                 source: "environment", hints: [MailHint(severity: "info", code: "not_configured",
                message: "Auf diesem Server ist kein E-Mail-Versand eingerichtet. Setze mindestens SMTP_HOST und SMTP_FROM in der Umgebung (SMTP_PORT, SMTP_TLS, SMTP_USER und SMTP_PASSWORD bzw. SMTP_PASSWORD_FILE sind optional) und starte den Server neu.")])
        }
        return MailStatusDTO(configured: true, host: smtp.host, port: smtp.port, tls: smtp.tls.rawValue, fromAddress: smtp.from,
                             fromName: smtp.fromName, authConfigured: smtp.user != nil, source: "environment",
                             hints: hints(smtp, publicHost: configuration.publicBaseURL.host))
    }

    /// Plain-German hints for settings that usually work badly together. They are advice, never errors.
    static func hints(_ smtp: SMTPConfiguration, publicHost: String?) -> [MailHint] {
        var result: [MailHint] = []
        if smtp.port == 465 && smtp.tls == .starttls {
            result.append(MailHint(severity: "warning", code: "port_465_needs_implicit",
                message: "Port 465 erwartet in der Regel sofortige Verschlüsselung (SMTP_TLS=implicit), eingestellt ist aber starttls."))
        }
        if smtp.port == 587 && smtp.tls == .implicit {
            result.append(MailHint(severity: "warning", code: "port_587_needs_starttls",
                message: "Port 587 erwartet in der Regel STARTTLS (SMTP_TLS=starttls), eingestellt ist aber implicit."))
        }
        if smtp.port == 25 && smtp.tls != .off {
            result.append(MailHint(severity: "info", code: "port_25_often_blocked",
                message: "Port 25 wird von vielen Netzbetreibern und Cloud-Anbietern für ausgehende Verbindungen gesperrt. Besser sind Port 587 (STARTTLS) oder 465 (implicit)."))
        }
        if smtp.tls == .off {
            result.append(MailHint(severity: "info", code: "tls_off_local_only",
                message: "Die Verbindung ist unverschlüsselt. Das ist nur für lokale Tests mit einem Mailpit-Dienst gedacht."))
        } else if smtp.user == nil {
            result.append(MailHint(severity: "info", code: "no_authentication",
                message: "Es ist keine Anmeldung eingerichtet (SMTP_USER und SMTP_PASSWORD). Die meisten Mailserver nehmen ohne Anmeldung nur Mails aus dem eigenen Netz an."))
        }
        let fromDomain = smtp.from.split(separator: "@").last.map { $0.lowercased() } ?? ""
        if !fromDomain.isEmpty, registrableDomain(smtp.host.lowercased()) != registrableDomain(fromDomain) {
            result.append(MailHint(severity: "info", code: "from_domain_differs_from_server",
                message: "Die Absenderadresse gehört zu einer anderen Domain als der Mailserver. Das ist erlaubt, aber SPF und DKIM der Absenderdomain müssen den Server zulassen, sonst landen Mails im Spam."))
        }
        if let publicHost, !fromDomain.isEmpty, !["localhost", "127.0.0.1", "::1", "[::1]"].contains(publicHost.lowercased()),
           registrableDomain(publicHost.lowercased()) != registrableDomain(fromDomain) {
            result.append(MailHint(severity: "info", code: "from_domain_differs_from_public_url",
                message: "Die Domain der Absenderadresse weicht von der Adresse ab, unter der Timetrack erreichbar ist (PUBLIC_BASE_URL). Empfänger erkennen die Mail dadurch schwerer als zugehörig."))
        }
        return result
    }

    /// Last two labels; good enough for a hint, no public-suffix list involved.
    static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".")
        return labels.count <= 2 ? host : labels.suffix(2).joined(separator: ".")
    }
}

/// Why a step failed, in plain German, plus what to do about it.
struct MailCheckProblem: Content, Equatable {
    let code: String
    let message: String
    let advice: String
}

struct MailCheckCertificate: Content, Equatable {
    let subject: String?
    let issuer: String?
    let validFrom: Date
    let validUntil: Date
    /// Whole days until expiry; negative once expired.
    let daysLeft: Int
    /// Whether the certificate names the configured host.
    let hostnameMatches: Bool
}

struct MailCheckStep: Content, Equatable {
    /// `dns`, `tcp`, `tls`, `ehlo`, `auth`, `mailFrom`.
    let id: String
    let title: String
    /// `ok`, `failed` or `skipped`.
    let status: String
    let durationMs: Int
    let details: [String]
    let warnings: [String]
    let certificate: MailCheckCertificate?
    let problem: MailCheckProblem?
}

struct MailCheckResult: Content {
    let ok: Bool
    let summary: String
    let checkedAt: Date
    let totalMs: Int
    let steps: [MailCheckStep]
}

struct MailTestInput: Decodable { let to: String? }

struct MailTestResult: Content {
    let sent: Bool
    let to: String
    let durationMs: Int
}
