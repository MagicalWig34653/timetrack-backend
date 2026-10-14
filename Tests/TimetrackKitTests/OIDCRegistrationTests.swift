import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

final class OIDCRegistrationTests: OIDCTestCase, @unchecked Sendable {
    private struct Registered { let status: HTTPStatus; let error: String?; let session: SessionDTO?; let cookie: String? }

    private func register(_ app: Application, _ b: TestBrowser, pending: String, handle: String, displayName: String = "New Person") async throws -> Registered {
        var out = Registered(status: .internalServerError, error: nil, session: nil, cookie: nil)
        try await app.test(.POST, "/api/v1/auth/oidc/register", headers: b.headers(csrf: true), beforeRequest: {
            try $0.content.encode(["pendingId": pending, "handle": handle, "displayName": displayName], as: .json)
        }, afterResponse: { res async throws in
            out = Registered(status: res.status, error: res.status == .created ? nil : try? res.content.decode([String: [String: String]].self)["error"]?["code"],
                             session: res.status == .created ? try res.content.decode(SessionDTO.self) : nil, cookie: res.headers.setCookie?["tt_session"]?.string)
        })
        return out
    }

    private func pendingID(_ location: String) throws -> String {
        let parts = try XCTUnwrap(URLComponents(string: "http://x" + location))
        return try XCTUnwrap(parts.queryItems?.first { $0.name == "oidc" }?.value)
    }

    func testRegisterWithInvitation() async throws {
        try await withOIDC { app, service, provider in
            let admin = try await makeAccount(service, app.db, handle: "admin", role: .admin)
            let invite = try await invitation(service, app.db, admin: admin)
            let b = browser()
            let callback = try await b.run(app, provider: provider, purpose: "register", inviteToken: invite.token, as: FakeIdentity(sub: "new-sub"))
            XCTAssertEqual(callback.status, .found)
            XCTAssertTrue(callback.location.hasPrefix("/invite/\(invite.token!)?oidc="), callback.location)
            // Nothing exists yet: the callback only stores a pending registration.
            let accounts = try await Account.query(on: app.db).count(), identities = try await ExternalIdentity.query(on: app.db).count()
            XCTAssertEqual(accounts, 1); XCTAssertEqual(identities, 0)
            let usedBefore = try await Invitation.find(invite.id, on: app.db)?.usedAt
            XCTAssertNil(usedBefore)
            let pending = try pendingID(callback.location)
            let created = try await register(app, b, pending: pending, handle: "new-person")
            XCTAssertEqual(created.status, .created)
            XCTAssertEqual(created.session?.account.handle, "new-person"); XCTAssertEqual(created.session?.account.role, .member); XCTAssertFalse(created.session?.recovery ?? true)
            XCTAssertNotNil(created.cookie)
            let identity = try await ExternalIdentity.query(on: app.db).first()
            XCTAssertEqual(identity?.subject, "new-sub"); XCTAssertEqual(identity?.accountId, created.session?.account.id)
            let used = try await Invitation.find(invite.id, on: app.db)
            XCTAssertNotNil(used?.usedAt); XCTAssertEqual(used?.usedBy, created.session?.account.id)
            let passkeys = try await Passkey.query(on: app.db).count()
            XCTAssertEqual(passkeys, 0)
            // Pending is single use; the invitation is gone.
            let again = try await register(app, b, pending: pending, handle: "other-name")
            XCTAssertEqual(again.status, .notFound)
            // The new account can log in with OIDC.
            same(try await browser().run(app, provider: provider, purpose: "login", as: FakeIdentity(sub: "new-sub")).location, "/")
            // The invitation cannot start another registration.
            let second = try await browser().start(app, purpose: "register", inviteToken: invite.token)
            XCTAssertEqual(second.status, .notFound)
        }
    }

    func testBootstrapInvitationKeepsAdminRole() async throws {
        try await withOIDC { app, service, provider in
            let invite = try await service.createInvitation(.init(), context: nil, bootstrap: true, on: app.db)
            let b = browser()
            let callback = try await b.run(app, provider: provider, purpose: "register", inviteToken: invite.token)
            let created = try await register(app, b, pending: try pendingID(callback.location), handle: "root")
            XCTAssertEqual(created.session?.account.role, .admin)
        }
    }

    func testInvalidInvitationsAreRejected() async throws {
        try await withOIDC { app, service, provider in
            let admin = try await makeAccount(service, app.db, handle: "admin", role: .admin)
            let missing = try await browser().start(app, purpose: "register")
            XCTAssertEqual(missing.status, .badRequest)
            let bogus = try await browser().start(app, purpose: "register", inviteToken: String(repeating: "a", count: 43))
            XCTAssertEqual(bogus.status, .notFound); XCTAssertEqual(bogus.error, "not_found")
            let expired = try await invitation(service, app.db, admin: admin)
            try await Invitation.query(on: app.db).filter(\.$id == expired.id).set(\.$expiresAt, to: Date().addingTimeInterval(-5)).update()
            same(try await browser().start(app, purpose: "register", inviteToken: expired.token).status, .notFound)
            let revoked = try await invitation(service, app.db, admin: admin)
            try await service.revokeInvitation(revoked.id, context: admin, on: app.db)
            same(try await browser().start(app, purpose: "register", inviteToken: revoked.token).status, .notFound)
            let used = try await invitation(service, app.db, admin: admin)
            try await Invitation.query(on: app.db).filter(\.$id == used.id).set(\.$usedAt, to: Date()).update()
            same(try await browser().start(app, purpose: "register", inviteToken: used.token).status, .notFound)
            // Invitation becomes unusable between start and callback.
            let racing = try await invitation(service, app.db, admin: admin)
            let b = browser()
            let started = try await b.start(app, purpose: "register", inviteToken: racing.token)
            try await service.revokeInvitation(racing.id, context: admin, on: app.db)
            let result = try await b.callback(app, path: provider.authorize(try XCTUnwrap(started.url)).path)
            XCTAssertEqual(result.location, "/login?oidc_error=oidc_invite_invalid")
            // ... and between callback and register: nothing is created.
            let late = try await invitation(service, app.db, admin: admin)
            let c = browser()
            let callback = try await c.run(app, provider: provider, purpose: "register", inviteToken: late.token)
            try await service.revokeInvitation(late.id, context: admin, on: app.db)
            let rejected = try await register(app, c, pending: try pendingID(callback.location), handle: "late-comer")
            XCTAssertEqual(rejected.status, .notFound)
            let accounts = try await Account.query(on: app.db).count(), identities = try await ExternalIdentity.query(on: app.db).count()
            XCTAssertEqual(accounts, 1); XCTAssertEqual(identities, 0)
        }
    }

    func testRegisterWithAlreadyLinkedIdentityIsRefused() async throws {
        try await withOIDC { app, service, provider in
            let admin = try await makeAccount(service, app.db, handle: "admin", role: .admin)
            same(try await link(app, provider, admin).location, "/settings/identities?linked=1")
            let invite = try await invitation(service, app.db, admin: admin)
            let result = try await browser().run(app, provider: provider, purpose: "register", inviteToken: invite.token)
            XCTAssertEqual(result.location, "/login?oidc_error=oidc_identity_taken")
            let pending = try await OIDCPendingRegistration.query(on: app.db).count()
            XCTAssertEqual(pending, 0)
        }
    }

    func testRegisterInputAndBindingChecks() async throws {
        try await withOIDC { app, service, provider in
            let admin = try await makeAccount(service, app.db, handle: "admin", role: .admin)
            _ = try await makeAccount(service, app.db, handle: "taken")
            let invite = try await invitation(service, app.db, admin: admin)
            let b = browser()
            let callback = try await b.run(app, provider: provider, purpose: "register", inviteToken: invite.token)
            let pending = try pendingID(callback.location)
            same(try await register(app, b, pending: pending, handle: "Bad Handle!").status, .badRequest)
            same(try await register(app, b, pending: pending, handle: "ok-name", displayName: "").status, .badRequest)
            same(try await register(app, b, pending: "not-a-uuid", handle: "ok-name").status, .notFound)
            same(try await register(app, b, pending: UUID().uuidString, handle: "ok-name").status, .notFound)
            // Browser without the binding cookie cannot complete someone else's pending registration.
            let thief = browser()
            same(try await register(app, thief, pending: pending, handle: "ok-name").status, .notFound)
            // A taken handle answers 409 and does not burn the pending registration or the invitation.
            let conflict = try await register(app, b, pending: pending, handle: "taken")
            XCTAssertEqual(conflict.status, .conflict); XCTAssertEqual(conflict.error, "handle_taken")
            let invitationUsed = try await Invitation.find(invite.id, on: app.db)?.usedAt
            XCTAssertNil(invitationUsed)
            same(try await register(app, b, pending: pending, handle: "fresh-name").status, .created)
        }
    }

    func testPendingRegistrationExpires() async throws {
        try await withOIDC { app, service, provider in
            let admin = try await makeAccount(service, app.db, handle: "admin", role: .admin)
            let invite = try await invitation(service, app.db, admin: admin)
            let b = browser()
            let callback = try await b.run(app, provider: provider, purpose: "register", inviteToken: invite.token)
            let pending = try pendingID(callback.location)
            let row = try await OIDCPendingRegistration.find(UUID(uuidString: pending), on: app.db)
            XCTAssertEqual(try XCTUnwrap(row).expiresAt.timeIntervalSince(row!.createdAt), 600, accuracy: 1)
            try await OIDCPendingRegistration.query(on: app.db).set(\.$expiresAt, to: Date().addingTimeInterval(-1)).update()
            same(try await register(app, b, pending: pending, handle: "too-late").status, .notFound)
            let accounts = try await Account.query(on: app.db).count()
            XCTAssertEqual(accounts, 1)
        }
    }

    func testParallelRedemptionsCreateExactlyOneAccount() async throws {
        try await withOIDC { app, service, provider in
            let admin = try await makeAccount(service, app.db, handle: "admin", role: .admin)
            let invite = try await invitation(service, app.db, admin: admin)
            // Several browsers each hold a verified pending registration for the same invitation.
            var browsers: [(TestBrowser, String)] = []
            for index in 0..<6 {
                let b = browser()
                let callback = try await b.run(app, provider: provider, purpose: "register", inviteToken: invite.token, as: FakeIdentity(sub: "parallel-\(index)"))
                browsers.append((b, try pendingID(callback.location)))
            }
            let work = browsers
            let created = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
                for (index, entry) in work.enumerated() {
                    group.addTask { try await self.register(app, entry.0, pending: entry.1, handle: "parallel-\(index)").status == .created ? 1 : 0 }
                }
                var total = 0; for try await value in group { total += value }; return total
            }
            XCTAssertEqual(created, 1)
            let accounts = try await Account.query(on: app.db).count(), identities = try await ExternalIdentity.query(on: app.db).count()
            XCTAssertEqual(accounts, 2); XCTAssertEqual(identities, 1)
            // The same pending registration redeemed in parallel also yields one account.
            let invite2 = try await invitation(service, app.db, admin: admin)
            let b = browser()
            let callback = try await b.run(app, provider: provider, purpose: "register", inviteToken: invite2.token, as: FakeIdentity(sub: "single"))
            let pending = try pendingID(callback.location)
            let again = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
                for index in 0..<4 { group.addTask { try await self.register(app, b, pending: pending, handle: "single-\(index)").status == .created ? 1 : 0 } }
                var total = 0; for try await value in group { total += value }; return total
            }
            XCTAssertEqual(again, 1)
            let finalAccounts = try await Account.query(on: app.db).count()
            XCTAssertEqual(finalAccounts, 3)
        }
    }

    /// Same scenarios on MariaDB (gated): migrations, unique constraints, row counts and parallel single use.
    func testLinkLoginAndParallelRegistrationOnMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let database = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
                        "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
                        "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"]
        try await withOIDC(extra: database) { app, service, provider in
            let admin = try await makeAccount(service, app.db, handle: "admin", role: .admin)
            same(try await link(app, provider, admin).location, "/settings/identities?linked=1")
            same(try await link(app, provider, try await makeAccount(service, app.db, handle: "other")).location, "/settings/identities?oidc_error=oidc_identity_taken")
            same(try await browser().run(app, provider: provider, purpose: "login").location, "/")
            same(errorCode(try await browser().run(app, provider: provider, purpose: "login", as: FakeIdentity(sub: "stranger")).location), "oidc_not_linked")
            let invite = try await invitation(service, app.db, admin: admin)
            var browsers: [(TestBrowser, String)] = []
            for index in 0..<4 {
                let b = browser()
                let callback = try await b.run(app, provider: provider, purpose: "register", inviteToken: invite.token, as: FakeIdentity(sub: "m-\(index)"))
                browsers.append((b, try pendingID(callback.location)))
            }
            let work = browsers
            let created = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
                for (index, entry) in work.enumerated() { group.addTask { try await self.register(app, entry.0, pending: entry.1, handle: "maria-\(index)").status == .created ? 1 : 0 } }
                var total = 0; for try await value in group { total += value }; return total
            }
            XCTAssertEqual(created, 1)
            let identities = try await ExternalIdentity.query(on: app.db).count()
            XCTAssertEqual(identities, 2)
            // Cleanup of rows that block the revert (accounts are referenced by restrict constraints).
            try await OIDCState.query(on: app.db).delete(); try await OIDCPendingRegistration.query(on: app.db).delete(); try await ExternalIdentity.query(on: app.db).delete()
        }
    }
}
