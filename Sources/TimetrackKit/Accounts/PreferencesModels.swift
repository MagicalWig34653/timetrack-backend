import Foundation
import Fluent
import Vapor

/// Appearance preferences of one account, shared by the PWA and the native apps (ADR-0020). The app icon and the
/// transparency switch stay device-local and are deliberately not part of this.
///
/// Stored as one validated JSON document in `accounts.preferences`; a missing document means the defaults. New keys are
/// added as optional fields here (and in the patch whitelist below), never as free-form data.
struct AccountPreferences: Content, Equatable {
    static let accents = ["blue", "teal", "violet", "green", "orange", "pink", "graphite", "custom"]
    static let schemes = ["system", "light", "dark"]
    /// Upper bound of a PATCH body; the legitimate payload is below 150 bytes.
    static let maxBodyBytes = 1024
    static let defaults = AccountPreferences(accent: "blue", accentCustomHex: nil, colorScheme: "system", updatedAt: nil)

    var accent: String
    /// `#RRGGBB` (upper case) when `accent` is `custom`, otherwise nil.
    var accentCustomHex: String?
    var colorScheme: String
    /// Time of the last change; nil while the defaults apply. Clients use it to reconcile their local copy.
    var updatedAt: Date?

    static func validHex(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 7 && bytes[0] == UInt8(ascii: "#") && bytes.dropFirst().allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }
    }

    /// Applies a merge patch (only the given keys change; `accentCustomHex: null` clears) and validates the result strictly.
    func applying(_ patch: [String: JSONValue], at date: Date) throws -> AccountPreferences {
        let allowed: Set<String> = ["accent", "accentCustomHex", "colorScheme"]
        guard !patch.isEmpty, Set(patch.keys).isSubset(of: allowed) else { throw APIError.invalid }
        var next = self
        if let value = patch["accent"] {
            guard case .string(let accent) = value, Self.accents.contains(accent) else { throw APIError.invalid }
            next.accent = accent
            if accent != "custom", patch["accentCustomHex"] == nil { next.accentCustomHex = nil }
        }
        if let value = patch["colorScheme"] {
            guard case .string(let scheme) = value, Self.schemes.contains(scheme) else { throw APIError.invalid }
            next.colorScheme = scheme
        }
        if let value = patch["accentCustomHex"] {
            switch value {
            case .null: next.accentCustomHex = nil
            case .string(let hex) where Self.validHex(hex): next.accentCustomHex = hex.uppercased()
            default: throw APIError.invalid
            }
        }
        // The colour exists exactly for the custom accent.
        guard (next.accent == "custom") == (next.accentCustomHex != nil) else { throw APIError.invalid }
        next.updatedAt = date
        return next
    }
}

/// Adds the preferences document. Existing accounts keep NULL (= defaults); nothing is rewritten.
struct AddAccountPreferences: AsyncMigration {
    let name = "p2.add_account_preferences"
    func prepare(on db: any Database) async throws {
        try await db.schema(Account.schema).field("preferences", .json).update()
    }
    func revert(on db: any Database) async throws { try await db.schema(Account.schema).deleteField("preferences").update() }
}

extension AuthService {
    func preferences(_ context: AuthContext, on db: any Database) async throws -> AccountPreferences {
        try context.normal()
        guard let account = try await Account.find(context.account.requireID(), on: db) else { throw APIError.unauthorized }
        return account.preferences ?? .defaults
    }

    func updatePreferences(_ patch: [String: JSONValue], context: AuthContext, on db: any Database) async throws -> AccountPreferences {
        try context.normal()
        return try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.normal()
            let account = current.account
            let next = try (account.preferences ?? .defaults).applying(patch, at: Date())
            account.preferences = next
            try await account.update(on: tx)
            return next
        }
    }
}
