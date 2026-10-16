import Fluent
import XCTVapor
@testable import TimetrackKit

/// Package P2: per-account appearance preferences (ADR-0020).
extension AuthTests {
    func prefs(_ app: Application, _ context: AuthContext) async throws -> [String: Any] {
        try object(await api(app, context, .GET, "me/preferences"))
    }

    func scenarioPreferences(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, admin)

        // Defaults without any stored row; the session carries them too.
        let defaults = try await prefs(app, member)
        XCTAssertEqual(defaults["accent"] as? String, "blue"); XCTAssertEqual(defaults["colorScheme"] as? String, "system")
        XCTAssertNil(defaults["accentCustomHex"] as? String); XCTAssertNil(defaults["updatedAt"] as? String)
        let session0 = try object(await api(app, member, .GET, "auth/session"))
        XCTAssertEqual(((session0["account"] as? [String: Any])?["preferences"] as? [String: Any])?["accent"] as? String, "blue")

        // Merge patch: a preset, then the scheme alone keeps the accent.
        let teal = try object(await api(app, member, .PATCH, "me/preferences", ["accent": "teal"]))
        XCTAssertEqual(teal["accent"] as? String, "teal"); XCTAssertEqual(teal["colorScheme"] as? String, "system"); XCTAssertNotNil(teal["updatedAt"] as? String)
        let dark = try object(await api(app, member, .PATCH, "me/preferences", ["colorScheme": "dark"]))
        XCTAssertEqual(dark["accent"] as? String, "teal"); XCTAssertEqual(dark["colorScheme"] as? String, "dark")

        // Custom colour: needs a strict #RRGGBB, is stored upper case, and is cleared by switching to a preset.
        for bad in ["#12345", "#1234567", "123456", "#GGGGGG", "red", "#12 456", "#12345é", ""] {
            try await api(app, member, .PATCH, "me/preferences", ["accent": "custom", "accentCustomHex": bad], .badRequest)
        }
        try await api(app, member, .PATCH, "me/preferences", ["accent": "custom"], .badRequest)               // colour missing
        try await api(app, member, .PATCH, "me/preferences", ["accent": "custom", "accentCustomHex": NSNull()], .badRequest)
        try await api(app, member, .PATCH, "me/preferences", ["accentCustomHex": "#112233"], .badRequest)      // accent is teal
        try await api(app, member, .PATCH, "me/preferences", ["accent": "green", "accentCustomHex": "#112233"], .badRequest)
        try await eq((try await prefs(app, member))["accent"] as? String, "teal")                              // failed patches changed nothing
        let custom = try object(await api(app, member, .PATCH, "me/preferences", ["accent": "custom", "accentCustomHex": "#12ab9f"]))
        XCTAssertEqual(custom["accentCustomHex"] as? String, "#12AB9F"); XCTAssertEqual(custom["colorScheme"] as? String, "dark")
        let recolored = try object(await api(app, member, .PATCH, "me/preferences", ["accentCustomHex": "#000000"]))
        XCTAssertEqual(recolored["accentCustomHex"] as? String, "#000000")
        let sessionCustom = try object(await api(app, member, .GET, "auth/session"))
        XCTAssertEqual(((sessionCustom["account"] as? [String: Any])?["preferences"] as? [String: Any])?["accentCustomHex"] as? String, "#000000")
        let preset = try object(await api(app, member, .PATCH, "me/preferences", ["accent": "orange"]))
        XCTAssertEqual(preset["accent"] as? String, "orange"); XCTAssertNil(preset["accentCustomHex"] as? String)
        for accent in AccountPreferences.accents where accent != "custom" {
            try await eq((try object(await api(app, member, .PATCH, "me/preferences", ["accent": accent])))["accent"] as? String, accent)
        }

        // Strict validation: unknown keys, wrong types, unknown values, empty body.
        try await api(app, member, .PATCH, "me/preferences", [:], .badRequest)
        try await api(app, member, .PATCH, "me/preferences", ["accent": "red"], .badRequest)
        try await api(app, member, .PATCH, "me/preferences", ["accent": 3], .badRequest)
        try await api(app, member, .PATCH, "me/preferences", ["colorScheme": "auto"], .badRequest)
        try await api(app, member, .PATCH, "me/preferences", ["colorScheme": NSNull()], .badRequest)
        try await api(app, member, .PATCH, "me/preferences", ["accent": "blue", "theme": "x"], .badRequest)
        try await api(app, member, .PATCH, "me/preferences", ["updatedAt": "2020-01-01T00:00:00Z"], .badRequest)
        try await api(app, member, .PATCH, "me/preferences", ["appIcon": "dark"], .badRequest)
        let large = try await api(app, member, .PATCH, "me/preferences", ["accent": "blue", "pad": String(repeating: "x", count: 2000)], .payloadTooLarge)
        XCTAssertEqual(try errorCode(large), "payload_too_large")

        // Isolation: the other account still has the defaults; both can change independently.
        let adminPrefs = try await prefs(app, admin)
        XCTAssertEqual(adminPrefs["accent"] as? String, "blue"); XCTAssertNil(adminPrefs["updatedAt"] as? String)
        try await api(app, admin, .PATCH, "me/preferences", ["colorScheme": "light"])
        try await eq((try await prefs(app, member))["colorScheme"] as? String, "dark")

        // Needs a normal session; no preferences for anonymous callers or recovery sessions. CSRF is enforced for writes.
        let recovery = try await auth.issueSession(for: member.account, recovery: true, on: app.db)
        for (method, body) in [(HTTPMethod.GET, nil), (.PATCH, ["accent": "pink"])] as [(HTTPMethod, [String: Any]?)] {
            try await api(app, recovery, method, "me/preferences", body, .forbidden)
            try await timeRequest(app, nil, method, "me/preferences", body, status: .unauthorized)
        }
        var noCSRF = headers(member, csrf: false); noCSRF.contentType = .json
        let rejected = try await app.testable().sendRequest(.PATCH, "/api/v1/me/preferences", headers: noCSRF, body: ByteBuffer(string: #"{"accent":"pink"}"#))
        XCTAssertEqual(rejected.status, .forbidden)
        try await eq((try await prefs(app, member))["accent"] as? String, "graphite")

        // Export carries the preferences; the other account's export does not mix them up.
        let export = try await api(app, member, .GET, "me/export")
        let files = try entries(Data(export.body.readableBytesView))
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(files["preferences.json"])) as? [String: Any])
        XCTAssertEqual(exported["accent"] as? String, "graphite"); XCTAssertEqual(exported["colorScheme"] as? String, "dark")

        // Deleting the account removes the preferences with it (they live on the account row).
        try await del(app, member, "me", confirm: "member")
        try await eq(try await Account.query(on: app.db).filter(\.$handle == "member").count(), 0)
    }
    func testP2PreferencesSQLite() async throws { try await withApp(scenarioPreferences) }

    /// Accounts that existed before the migration have NULL and read as the defaults.
    func testP2LegacyAccountsReadAsDefaults() async throws {
        try await withApp { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            let account = try await Account.find(admin.account.requireID(), on: app.db)
            XCTAssertNotNil(account); XCTAssertNil(account?.preferences)
            let prefs = try await self.prefs(app, admin)
            XCTAssertEqual(prefs["accent"] as? String, "blue")
            let export = try await self.api(app, admin, .GET, "me/export")
            let files = try self.entries(Data(export.body.readableBytesView))
            XCTAssertNotNil(files["preferences.json"])
        }
    }

    func testP2PreferencesMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_p2", "DB_TLS": "off"]
        try await withApp(environment: environment, scenarioPreferences)
    }
}
