import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

final class OIDCIdentityTests: OIDCTestCase, @unchecked Sendable {
    private func delete(_ app: Application, _ b: TestBrowser, _ id: UUID) async throws -> (HTTPStatus, String?) {
        var out: (HTTPStatus, String?) = (.internalServerError, nil)
        try await app.test(.DELETE, "/api/v1/me/identities/\(id)", headers: b.headers(csrf: true), afterResponse: { res async throws in
            out = (res.status, try? res.content.decode([String: [String: String]].self)["error"]?["code"])
        })
        return out
    }
    private func insert(_ db: any Database, _ account: AuthContext, sub: String) async throws -> ExternalIdentity {
        let identity = ExternalIdentity(accountId: try account.account.requireID(), issuer: "https://idp.example.test", subject: sub, emailHint: nil, linkedAt: Date())
        try await identity.create(on: db)
        return identity
    }

    func testLastLoginMethodIsProtected() async throws {
        try await withOIDC { app, service, _ in
            let context = try await makeAccount(service, app.db, handle: "alice")
            let first = try await insert(app.db, context, sub: "one")
            let b = browser(context)
            // Only login method (no passkey, no other identity): refused.
            let refused = try await delete(app, b, try first.requireID())
            XCTAssertEqual(refused.0, .conflict); XCTAssertEqual(refused.1, "last_login_method")
            // Recovery methods do not count as login methods.
            _ = try await service.recoveryCodes(context, generate: true, on: app.db)
            same(try await delete(app, b, try first.requireID()).0, .conflict)
            let second = try await insert(app.db, context, sub: "two")
            same(try await delete(app, b, try first.requireID()).0, .noContent)
            same(try await delete(app, b, try second.requireID()).1, "last_login_method")
            let remaining = try await ExternalIdentity.query(on: app.db).count()
            XCTAssertEqual(remaining, 1)
        }
    }

    func testRemovingIdentityIsAllowedWithPasskey() async throws {
        try await withOIDC { app, service, _ in
            let invite = try await service.createInvitation(.init(), context: nil, bootstrap: true, on: app.db)
            let options = try await service.registrationOptions(.init(inviteToken: invite.token!, handle: "keyed", displayName: "Keyed", email: nil), on: app.db)
            let context = try await service.register(SoftwareAuthenticator().registration(options), on: app.db)
            let identity = try await insert(app.db, context, sub: "one")
            same(try await delete(app, browser(context), try identity.requireID()).0, .noContent)
        }
    }

    func testPasskeyRevocationCountsIdentities() async throws {
        try await withOIDC { app, service, _ in
            let invite = try await service.createInvitation(.init(), context: nil, bootstrap: true, on: app.db)
            let options = try await service.registrationOptions(.init(inviteToken: invite.token!, handle: "keyed", displayName: "Keyed", email: nil), on: app.db)
            let context = try await service.register(SoftwareAuthenticator().registration(options), on: app.db)
            let key = try await service.passkeys(context, on: app.db)[0]
            // Last passkey, no recovery, no identity: refused (existing behaviour).
            await expect("last_passkey") { _ = try await service.changePasskey(key.id, name: nil, context: context, on: app.db) }
            _ = try await insert(app.db, context, sub: "one")
            // With an external identity the last passkey may be removed.
            _ = try await service.changePasskey(key.id, name: nil, context: context, on: app.db)
            let active = try await Passkey.query(on: app.db).filter(\.$revokedAt == nil).count()
            XCTAssertEqual(active, 0)
            // ... and now the identity is the last login method.
            let identity = try await ExternalIdentity.query(on: app.db).first()
            let refused = try await delete(app, browser(context), try XCTUnwrap(identity).requireID())
            XCTAssertEqual(refused.1, "last_login_method")
        }
    }

    func testIdentitiesAreIsolatedAndNeedFreshSession() async throws {
        try await withOIDC { app, service, _ in
            let alice = try await makeAccount(service, app.db, handle: "alice")
            let bob = try await makeAccount(service, app.db, handle: "bob")
            let mine = try await insert(app.db, alice, sub: "a1")
            _ = try await insert(app.db, alice, sub: "a2")
            let theirs = try await insert(app.db, bob, sub: "b1")
            try await app.test(.GET, "/api/v1/me/identities", headers: browser(alice).headers()) { res async throws in
                let list = try res.content.decode([ExternalIdentityDTO].self)
                XCTAssertEqual(list.count, 2); XCTAssertFalse(list.contains { $0.id == theirs.id })
            }
            try await app.test(.GET, "/api/v1/me/identities") { res async throws in XCTAssertEqual(res.status, .unauthorized) }
            let foreign = try await delete(app, browser(alice), try theirs.requireID())
            XCTAssertEqual(foreign.0, .notFound); XCTAssertEqual(foreign.1, "not_found")
            same(try await delete(app, browser(alice), UUID()).0, .notFound)
            let stillThere = try await ExternalIdentity.find(theirs.id, on: app.db)
            XCTAssertNotNil(stillThere)
            // No CSRF header -> rejected by the session middleware.
            try await app.test(.DELETE, "/api/v1/me/identities/\(try mine.requireID())", headers: browser(alice).headers(csrf: false)) { res async throws in XCTAssertEqual(res.status, .forbidden) }
            // Stale session needs reauthentication.
            try await Session.query(on: app.db).filter(\.$id == alice.session.requireID()).set(\.$createdAt, to: Date().addingTimeInterval(-1200)).update()
            let stale = try await delete(app, browser(alice), try mine.requireID())
            XCTAssertEqual(stale.0, .forbidden); XCTAssertEqual(stale.1, "reauth_required")
            same(try await delete(app, browser(alice), try mine.requireID()).0, .forbidden)
            let count = try await ExternalIdentity.query(on: app.db).filter(\.$accountId == alice.account.requireID()).count()
            XCTAssertEqual(count, 2)
        }
    }
}
