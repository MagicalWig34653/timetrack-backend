import Foundation
import Fluent
import Vapor

/// Input cleaning shared by polls, orders and catalogs. Everything that reaches the database is trimmed text without control
/// characters or bidirectional overrides; output is only ever JSON, CSV (formula-safe) or plain text.
enum GroupText {
    /// Trims, rejects control characters (also newlines) and bidi overrides, enforces the length in unicode scalars.
    static func line(_ value: String?, max: Int, required: Bool = true) throws -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            if required { throw APIError.invalid }
            return nil
        }
        guard raw.fitsColumn(max), !raw.unicodeScalars.contains(where: { isForbidden($0) }) else { throw APIError.invalid }
        return raw
    }
    static func requiredLine(_ value: String?, max: Int) throws -> String { try line(value, max: max)! }

    /// Multi-line text (descriptions): newlines and tabs are allowed, other control characters are not.
    static func block(_ value: String?, max: Int) throws -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard raw.fitsColumn(max), !raw.unicodeScalars.contains(where: { $0 != "\n" && $0 != "\t" && isForbidden($0) }) else { throw APIError.invalid }
        return raw
    }

    static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return true }
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x2028, 0x2029, 0xFEFF: return true
        default: return false
        }
    }

    /// Case- and whitespace-insensitive key for "same person" checks.
    static func key(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

enum GroupTokens {
    static func create() -> (token: String, hash: String) {
        let token = Secrets.token(bytes: 32)
        return (token, Secrets.hash(token))
    }
    /// Link tokens are exactly 43 base64url characters; anything else cannot exist and is rejected before a lookup.
    static func plausible(_ token: String) -> Bool {
        token.utf8.count == GroupLimits.tokenLength && token.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }
    static func matches(_ secret: String, hash: String) -> Bool { Secrets.equal(Secrets.hash(secret), hash) }
}

/// Fixed-window counters on top of `rate_limit_events` (cleaned up by the maintenance job).
enum GroupRateLimit {
    static let window: TimeInterval = 300
    static let ipRead = 300
    static let ipWrite = 40
    static let tokenWrite = 150
    static let miss = 30

    /// Records an event and answers whether it is within the limit. A rejected request is not recorded.
    static func hit(_ key: String, limit: Int, now: Date, on db: any Database) async throws -> Bool {
        let start = now.addingTimeInterval(-window)
        guard try await RateLimitEvent.query(on: db).filter(\.$key == key).filter(\.$occurredAt > start).count() < limit else { return false }
        try await RateLimitEvent(key: key, occurredAt: now).create(on: db)
        return true
    }
    static func exceeded(_ key: String, limit: Int, now: Date, on db: any Database) async throws -> Bool {
        try await RateLimitEvent.query(on: db).filter(\.$key == key).filter(\.$occurredAt > now.addingTimeInterval(-window)).count() >= limit
    }
    static func record(_ key: String, now: Date, on db: any Database) async throws {
        try await RateLimitEvent(key: key, occurredAt: now).create(on: db)
    }
}

enum GroupMessages {
    static let german: [String: String] = [
        "group_closed": "Diese Runde ist beendet. Änderungen sind nicht mehr möglich.",
        "group_full": "Die Höchstzahl an Teilnahmen ist erreicht.",
        "name_taken": "Dieser Name wird in dieser Umfrage schon verwendet. Bitte wähle einen anderen.",
        "answers_invalid": "Die Antworten passen nicht zu den Auswahlmöglichkeiten der Umfrage.",
        "edit_secret_invalid": "Du darfst diesen Eintrag nicht ändern (Bearbeitungsschlüssel fehlt oder ist ungültig).",
        "too_many_polls": "Du hast die Höchstzahl an Umfragen erreicht. Bitte lösche alte Umfragen.",
        "too_many_orders": "Du hast die Höchstzahl an Bestellrunden erreicht. Bitte lösche alte Runden.",
        "too_many_catalogs": "Du hast die Höchstzahl an Katalogen erreicht.",
        "poll_has_votes": "Die Auswahlmöglichkeiten lassen sich nach der ersten Stimme nicht mehr ändern.",
        "deadline_in_past": "Die Frist muss in der Zukunft liegen.",
        "too_many_requests": "Zu viele Anfragen. Bitte versuche es in ein paar Minuten erneut.",
    ]
}

extension Response {
    /// Headers for every response of the public groups surface: never cached, never indexed, never sniffed.
    func markGroupPublic() -> Response {
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "X-Robots-Tag", value: "noindex, nofollow")
        headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return self
    }
}
