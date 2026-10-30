import Foundation
import Fluent
import Vapor

// APNs diagnosis for administrators (package P14e, ADR-0030 addendum): status without secrets and a live check that proves the
// provider credentials with Apple without delivering anything (a probe to a made-up device token).

struct ApnsHint: Content, Equatable {
    /// `info` or `warning`.
    let severity: String
    let code: String
    let message: String
}

struct ApnsStatusDTO: Content {
    let configured: Bool
    let keyId: String?
    let teamId: String?
    let bundleIds: [String]
    /// Names of the APNS_* variables that are missing or invalid while at least one of them is set.
    let problems: [String]
    /// Registered Apple devices of all accounts (a count, no tokens).
    let deviceCount: Int
    let source: String
    let hints: [ApnsHint]
}

struct ApnsProbeDTO: Content {
    let bundleId: String
    /// `production` or `sandbox`.
    let environment: String
    /// `ok` or `failed`.
    let status: String
    let httpStatus: Int?
    let reason: String?
    let advice: String?
}

struct ApnsCheckResult: Content {
    let ok: Bool
    let summary: String
    let checkedAt: Date
    let totalMs: Int
    let probes: [ApnsProbeDTO]
}

enum ApnsDiagnosis {
    static let checkLimit = 6, checkWindow: TimeInterval = 600
    /// A syntactically valid token that no device owns: Apple answers 400 BadDeviceToken after it accepted the credentials.
    static let probeToken = String(repeating: "00", count: 32)

    static func problems(_ environment: [String: String]) -> [String] {
        guard ApnsConfiguration.anyConfigured(environment), ApnsConfiguration(environment: environment) == nil else { return [] }
        var result: [String] = []
        if ApnsConfiguration(environment: environment.filter { $0.key == "APNS_PRIVATE_KEY" }.merging(["APNS_KEY_ID": "ABCDE12345", "APNS_TEAM_ID": "ABCDE12345", "APNS_BUNDLE_IDS": "a.b"]) { a, _ in a }) == nil { result.append("APNS_PRIVATE_KEY") }
        if !ApnsConfiguration.validIdentifier((environment["APNS_KEY_ID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) { result.append("APNS_KEY_ID") }
        if !ApnsConfiguration.validIdentifier((environment["APNS_TEAM_ID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) { result.append("APNS_TEAM_ID") }
        let ids = (environment["APNS_BUNDLE_IDS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if ids.isEmpty || !ids.allSatisfy(ApnsDeviceRules.validBundleId) { result.append("APNS_BUNDLE_IDS") }
        return result
    }

    static func status(configuration: ApnsConfiguration?, environment: [String: String], deviceCount: Int) -> ApnsStatusDTO {
        let problems = problems(environment)
        var hints: [ApnsHint] = []
        if configuration == nil {
            if problems.isEmpty {
                hints.append(ApnsHint(severity: "info", code: "not_configured", message: "Auf diesem Server ist APNs nicht eingerichtet. Setze APNS_PRIVATE_KEY (oder das Secret tt_apns_private_key), APNS_KEY_ID, APNS_TEAM_ID und APNS_BUNDLE_IDS und starte den Server neu (docs/DEPLOYMENT.md)."))
            } else {
                hints.append(ApnsHint(severity: "warning", code: "incomplete", message: "Die APNs-Einstellungen sind unvollständig oder ungültig: \(problems.joined(separator: ", ")). Bis dahin bleibt APNs ausgeschaltet."))
            }
        } else if deviceCount == 0 {
            hints.append(ApnsHint(severity: "info", code: "no_devices", message: "Es ist noch kein Apple-Gerät registriert. Öffne die App auf dem iPhone oder Mac, erlaube Mitteilungen und melde dich an; danach erscheint das Gerät unter „Benachrichtigungen“."))
        }
        return ApnsStatusDTO(configured: configuration != nil, keyId: configuration?.keyId, teamId: configuration?.teamId,
                             bundleIds: (configuration?.bundleIds ?? []).sorted(), problems: problems, deviceCount: deviceCount, source: "environment", hints: hints)
    }

    static func advice(status: Int, reason: String) -> String? {
        switch (status, reason) {
        case (403, "InvalidProviderToken"): "Apple lehnt den Schlüssel ab. Prüfe, ob APNS_KEY_ID zur .p8-Datei und APNS_TEAM_ID zu deinem Team gehört und ob der Schlüssel für APNs freigeschaltet ist."
        case (403, "ExpiredProviderToken"): "Apple hält das Token für abgelaufen. Prüfe die Uhrzeit des Servers."
        case (403, "TopicDisallowed"): "Der Schlüssel darf für diese Bundle-ID nicht senden. Prüfe APNS_BUNDLE_IDS und die Schlüsselberechtigung im Apple-Developer-Konto."
        case (400, "BadTopic"), (400, "MissingTopic"): "Apple kennt diese Bundle-ID nicht. Prüfe APNS_BUNDLE_IDS."
        case (429, _): "Apple drosselt Anfragen. Versuche es später erneut."
        case (500...599, _): "Apple meldet einen Serverfehler. Versuche es später erneut."
        default: "Unerwartete Antwort von Apple."
        }
    }

    /// Statuses that prove Apple accepted the provider token and topic (the made-up device token itself is rejected).
    static func accepted(status: Int, reason: String) -> Bool {
        ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered", "BadMessageId"].contains(reason) || status == 200 || status == 410
    }

    static func run(_ sender: ApnsSender, now: Date = Date()) async -> ApnsCheckResult {
        let started = ContinuousClock.now
        var probes: [ApnsProbeDTO] = []
        for bundleId in sender.configuration.bundleIds.sorted() {
            for environment in ["production", "sandbox"] {
                let request = ApnsRequest(deviceToken: probeToken, environment: environment, topic: bundleId, pushType: "alert", priority: 10, collapseId: "diagnosis",
                                          expiration: 0, authorization: ApnsTokenProvider.make(sender.configuration, now: now), body: Data(#"{"aps":{"alert":"x"}}"#.utf8))
                do {
                    let response = try await sender.transport.send(request)
                    let reason = response.reason ?? ""
                    if accepted(status: response.status, reason: reason) {
                        probes.append(ApnsProbeDTO(bundleId: bundleId, environment: environment, status: "ok", httpStatus: response.status, reason: response.reason, advice: nil))
                    } else {
                        probes.append(ApnsProbeDTO(bundleId: bundleId, environment: environment, status: "failed", httpStatus: response.status,
                                                   reason: response.reason.map { String($0.filter { $0.isLetter || $0.isNumber || $0 == "_" }.prefix(40)) }, advice: advice(status: response.status, reason: reason)))
                    }
                } catch {
                    probes.append(ApnsProbeDTO(bundleId: bundleId, environment: environment, status: "failed", httpStatus: nil, reason: "network",
                                               advice: "Die Verbindung zu Apple (api.push.apple.com, Port 443, HTTP/2) ist fehlgeschlagen. Prüfe ausgehende Verbindungen und DNS des Servers."))
                }
            }
        }
        let failed = probes.filter { $0.status == "failed" }
        let elapsed = ContinuousClock.now - started
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let summary = failed.isEmpty ? "Apple akzeptiert den Schlüssel für alle Bundle-IDs (Produktion und Sandbox). Es wurde nichts zugestellt."
            : "Bei \(failed.count) von \(probes.count) Prüfungen hat Apple die Anfrage abgelehnt oder war nicht erreichbar."
        return ApnsCheckResult(ok: failed.isEmpty, summary: summary, checkedAt: now, totalMs: ms, probes: probes)
    }
}
