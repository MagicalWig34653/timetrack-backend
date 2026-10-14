import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

extension AuthTests {
    func testHTTPManagementContract() async throws {
        try await withApp { app, service in
            let (context, _) = try await registered(service, db: app.db)
            try await app.test(.GET, "/api/v1/auth/session", headers: headers(context)) { response async throws in
                XCTAssertEqual(response.status, .ok)
                let body = try response.content.decode(SessionDTO.self)
                XCTAssertEqual(body.csrfToken, Secrets.csrf(context.token))
                XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
                let json = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as! [String: Any]
                XCTAssertNotNil(json["expiresAt"] as? String)
            }
            try await app.test(.GET, "/api/v1/auth/session") { response async throws in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertEqual(try response.content.decode([String: [String: String]].self)["error"]?["code"], "unauthorized")
            }
            try await app.test(.POST, "/api/v1/admin/invitations", headers: headers(context)) { response async throws in
                XCTAssertEqual(response.status, .created)
                let invite = try response.content.decode(InvitationDTO.self)
                XCTAssertNotNil(invite.token); XCTAssertEqual(invite.status, "open")
                XCTAssertEqual(invite.expiresAt.timeIntervalSince(invite.createdAt), 72 * 3600, accuracy: 1)
            }
            try await app.test(.GET, "/api/v1/admin/invitations", headers: headers(context)) { response async throws in
                XCTAssertEqual(response.status, .ok)
                let invites = try response.content.decode([InvitationDTO].self)
                XCTAssertEqual(invites.count, 1); XCTAssertNil(invites[0].token)
            }
            let invitation = try await service.createInvitation(.init(expiresInHours: 1, note: "Test"), context: context, on: app.db)
            try await app.test(.GET, "/api/v1/invitations/\(invitation.token!)") { response async throws in XCTAssertEqual(response.status, .ok) }
            try await app.test(.POST, "/api/v1/auth/register/options", beforeRequest: { req in
                try req.content.encode(RegisterInput(inviteToken: invitation.token!, handle: "new-user", displayName: "New", email: nil))
            }, afterResponse: { response async throws in
                XCTAssertEqual(response.status, .ok)
                let options = try response.content.decode(OptionsDTO.self)
                guard case .object(let fields) = options.publicKey else { return XCTFail("Expected object") }
                XCTAssertEqual(fields["authenticatorSelection"], .object(["residentKey": .string("required"), "requireResidentKey": .bool(true), "userVerification": .string("required")]))
            })
            try await app.test(.DELETE, "/api/v1/admin/invitations/\(invitation.id)", headers: headers(context)) { response async throws in XCTAssertEqual(response.status, .noContent) }
            try await app.test(.GET, "/api/v1/invitations/\(invitation.token!)") { response async throws in XCTAssertEqual(response.status, .notFound) }
            try await app.test(.POST, "/api/v1/me/recovery/recovery-codes", headers: headers(context)) { response async throws in
                XCTAssertEqual(response.status, .created)
                XCTAssertEqual(try response.content.decode([String: [String]].self)["codes"]?.count, 10)
            }
            try await app.test(.GET, "/api/v1/me/recovery", headers: headers(context)) { response async throws in
                let body = try response.content.decode(RecoveryStatusDTO.self)
                XCTAssertTrue(body.recoveryCodes.active); XCTAssertEqual(body.recoveryCodes.remaining, 10)
                XCTAssertFalse(body.email.available); XCTAssertFalse(body.email.active)
            }
            try await app.test(.PUT, "/api/v1/me/recovery/email", headers: headers(context), beforeRequest: { try $0.content.encode(["email": "test@example.test"]) }, afterResponse: { response async throws in
                XCTAssertEqual(response.status, .notImplemented)
                XCTAssertTrue(response.body.string.contains("not_implemented"))
            })
            let keys = try await service.passkeys(context, on: app.db)
            try await app.test(.PATCH, "/api/v1/me/passkeys/\(keys[0].id)", headers: headers(context), beforeRequest: { try $0.content.encode(["name": "Renamed"]) }, afterResponse: { response async throws in
                XCTAssertEqual(response.status, .ok); XCTAssertEqual(try response.content.decode(PasskeyDTO.self).name, "Renamed")
            })
            try await app.test(.DELETE, "/api/v1/me/passkeys/\(keys[0].id)", headers: headers(context)) { response async throws in XCTAssertEqual(response.status, .noContent) }
            try await app.test(.GET, "/api/v1/me/passkeys", headers: headers(context)) { response async throws in XCTAssertEqual(try response.content.decode([PasskeyDTO].self).count, 0) }
            try await app.test(.DELETE, "/api/v1/me/recovery/recovery-codes", headers: headers(context)) { response async throws in XCTAssertEqual(response.status, .noContent) }
        }
    }
    func testSecureCookieAndRestrictedLogout() async throws {
        try await withApp(environment: ["PUBLIC_BASE_URL": "https://example.test", "SESSION_TTL_HOURS": "2"]) { app, service in
            let (context, _) = try await registered(service, db: app.db)
            XCTAssertTrue(service.cookie(context).isSecure)
            XCTAssertEqual(context.session.expiresAt.timeIntervalSince(context.session.createdAt), 7200, accuracy: 1)
            let recovered = try await service.issueSession(for: context.account, recovery: true, on: app.db)
            try await app.test(.DELETE, "/api/v1/auth/session", headers: headers(recovered)) { response async throws in
                XCTAssertEqual(response.status, .noContent)
                XCTAssertTrue(response.headers.first(name: .setCookie)?.contains("Secure") == true)
            }
            await expect("unauthorized") { _ = try await service.authenticate(recovered.token, on: app.db) }
        }
    }
    func testChallengesExpireAndCannotBeTransferred() async throws {
        try await withApp { app, service in
            let (a, device) = try await registered(service, db: app.db)
            let (b, _) = try await registered(service, db: app.db, handle: "member", admin: a)
            let options = try await service.addOptions(a, on: app.db)
            let newDevice = SoftwareAuthenticator()
            await expect("not_found") { _ = try await service.addPasskey(newDevice.registration(options), context: b, on: app.db) }
            try await WebAuthnChallenge.query(on: app.db).filter(\.$id == options.challengeId).set(\.$expiresAt, to: Date().addingTimeInterval(-1)).update()
            await expect("bad_request") { _ = try await service.addPasskey(newDevice.registration(options), context: a, on: app.db) }
            let login = try await service.loginOptions(on: app.db)
            try await WebAuthnChallenge.query(on: app.db).filter(\.$id == login.challengeId).set(\.$expiresAt, to: Date().addingTimeInterval(-1)).update()
            await expect("unauthorized") { _ = try await service.login(device.assertion(login, accountID: a.account.requireID()), on: app.db) }
            let more = try await service.addOptions(a, on: app.db)
            _ = try await service.addPasskey(newDevice.registration(more), context: a, on: app.db)
            let keys = try await service.passkeys(a, on: app.db)
            _ = try await service.changePasskey(keys[0].id, name: nil, context: a, on: app.db)
            let freshLogin = try await service.loginOptions(on: app.db)
            await expect("unauthorized") { _ = try await service.login(device.assertion(freshLogin, accountID: a.account.requireID()), on: app.db) }
        }
    }
}

extension AuthTests {
    func testDifferentAttemptsCannotConsumeSameRecoveryCode() async throws {
        try await withApp { app, service in
            let (context, _) = try await registered(service, db: app.db)
            let codes = try await service.recoveryCodes(context, generate: true, on: app.db)
            var attempts: [UUID] = []
            for _ in 0..<8 { attempts.append(try await service.recoveryStart(.init(method: .recoveryCode, identifier: "admin"), on: app.db).recoveryId) }
            let ids = attempts
            let count = await withTaskGroup(of: Bool.self) { group in
                for id in ids { group.addTask { (try? await service.recoveryComplete(.init(recoveryId: id, proof: codes[0]), on: app.db)) != nil } }
                var count = 0; for await success in group { if success { count += 1 } }; return count
            }
            XCTAssertEqual(count, 1)
            let status = try await service.recoveryStatus(context, on: app.db)
            XCTAssertEqual(status.recoveryCodes.remaining, 9)
        }
    }
    func testParallelRevocationsPreserveLastPasskey() async throws {
        try await withApp { app, service in
            let (context, _) = try await registered(service, db: app.db)
            let newDevice = SoftwareAuthenticator()
            let options = try await service.addOptions(context, on: app.db)
            _ = try await service.addPasskey(newDevice.registration(options), context: context, on: app.db)
            let keys = try await service.passkeys(context, on: app.db)
            let count = await withTaskGroup(of: Bool.self) { group in
                for key in keys { group.addTask { (try? await service.changePasskey(key.id, name: nil, context: context, on: app.db)) != nil } }
                var count = 0; for await success in group { if success { count += 1 } }; return count
            }
            XCTAssertEqual(count, 1)
            let remaining = try await service.passkeys(context, on: app.db)
            XCTAssertEqual(remaining.count, 1)
        }
    }
}
