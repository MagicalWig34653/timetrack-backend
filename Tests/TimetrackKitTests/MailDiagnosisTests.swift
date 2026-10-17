import Foundation
import Fluent
import NIOCore
import NIOPosix
import NIOSSL
import XCTVapor
@testable import TimetrackKit

/// Package MAIL1 (ADR-0022): status, live check and test mail of the SMTP configuration.
final class FakeMailServer: @unchecked Sendable {
    struct Options: Sendable {
        var advertiseStartTLS = true
        var authMechanisms = "PLAIN"
        var authOK = true
        var mailFromReply = "250 ok"
        var rcptReply = "250 ok"
        var silent = false
        var implicitTLS = false
    }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    var options: Options
    var tls: NIOSSLContext?
    private let lock = NSLock()
    private var commands: [String] = [], subjects: [String] = []
    private var channel: (any Channel)?
    var port: Int { channel?.localAddress?.port ?? 0 }
    var received: [String] { lock.withLock { commands } }
    var receivedSubjects: [String] { lock.withLock { subjects } }
    fileprivate func record(_ line: String) { lock.withLock { commands.append(line) } }
    fileprivate func recordSubject(_ line: String) { lock.withLock { subjects.append(line) } }

    init(_ options: Options = Options(), tls: NIOSSLContext? = nil) { self.options = options; self.tls = tls }

    func start() throws {
        let server = self
        channel = try ServerBootstrap(group: group).serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if server.options.implicitTLS, let tls = server.tls { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
                    try channel.pipeline.syncOperations.addHandler(FakeMailConnection(server))
                }
            }.bind(host: "127.0.0.1", port: 0).wait()
    }
    func stop() { try? channel?.close().wait(); try? group.syncShutdownGracefully() }
}

private final class FakeMailConnection: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let server: FakeMailServer
    var buffer = "", dataMode = false
    init(_ server: FakeMailServer) { self.server = server }
    func reply(_ context: ChannelHandlerContext, _ value: String) {
        var bytes = context.channel.allocator.buffer(capacity: value.utf8.count); bytes.writeString(value + "\r\n")
        context.writeAndFlush(wrapOutboundOut(bytes), promise: nil)
    }
    func channelActive(context: ChannelHandlerContext) { if !server.options.silent && !server.options.implicitTLS { reply(context, "220 fake ESMTP") } }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case NIOTLS.TLSUserEvent.handshakeCompleted = event, server.options.implicitTLS { reply(context, "220 fake ESMTP") }
        context.fireUserInboundEventTriggered(event)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data); buffer += bytes.readString(length: bytes.readableBytes) ?? ""
        while let end = buffer.range(of: "\r\n") {
            let line = String(buffer[..<end.lowerBound]); buffer.removeSubrange(..<end.upperBound)
            let options = server.options
            if dataMode {
                if line.hasPrefix("Subject:") { server.recordSubject(line) }
                if line == "." { dataMode = false; reply(context, "250 queued") }
                continue
            }
            server.record(line.hasPrefix("AUTH") ? "AUTH" : line)
            if line.hasPrefix("EHLO") {
                var lines = ["fake.example.test", "SIZE 10485760"]
                if options.advertiseStartTLS && !options.implicitTLS && server.tls != nil { lines.append("STARTTLS") }
                if !options.authMechanisms.isEmpty { lines.append("AUTH " + options.authMechanisms) }
                for (index, value) in lines.enumerated() { reply(context, "250" + (index == lines.count - 1 ? " " : "-") + value) }
            } else if line == "STARTTLS", let tls = server.tls {
                reply(context, "220 go ahead")
                do { try context.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls), position: .first) } catch { context.close(promise: nil) }
            } else if line.hasPrefix("AUTH") { reply(context, options.authOK ? "235 ok" : "535 5.7.8 bad credentials for secret-user") }
            else if line.hasPrefix("MAIL FROM:") { reply(context, options.mailFromReply) }
            else if line.hasPrefix("RCPT TO:") { reply(context, options.rcptReply) }
            else if line == "DATA" { dataMode = true; reply(context, "354 go") }
            else if line == "RSET" { reply(context, "250 ok") }
            else if line == "QUIT" { reply(context, "221 bye"); context.close(promise: nil) }
            else { reply(context, "500 what") }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}

import NIOTLS

extension AuthTests {
    static let mailPassword = "very-secret-pw-12345"

    func tlsFixture(_ name: String = "localhost") throws -> (server: NIOSSLContext, client: TLSConfiguration, untrusted: TLSConfiguration) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", directory.appendingPathComponent("key.pem").path,
            "-out", directory.appendingPathComponent("cert.pem").path, "-days", "30", "-subj", "/CN=\(name)", "-addext", "subjectAltName=DNS:\(name)"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let cert = try NIOSSLCertificate.fromPEMFile(directory.appendingPathComponent("cert.pem").path)
        let key = try NIOSSLPrivateKey(file: directory.appendingPathComponent("key.pem").path, format: .pem)
        let server = try NIOSSLContext(configuration: .makeServerConfiguration(certificateChain: cert.map { .certificate($0) }, privateKey: .privateKey(key)))
        var trusted = TLSConfiguration.makeClientConfiguration(); trusted.trustRoots = .certificates(cert)
        return (server, trusted, TLSConfiguration.makeClientConfiguration())
    }

    func smtp(host: String = "127.0.0.1", port: Int, tls: String = "off", auth: Bool = false) throws -> SMTPConfiguration {
        var env = ["SMTP_HOST": host, "SMTP_PORT": String(port), "SMTP_TLS": tls, "SMTP_FROM": "timetrack@example.test"]
        if auth { env["SMTP_USER"] = "secret-user"; env["SMTP_PASSWORD"] = Self.mailPassword }
        return try XCTUnwrap(Configuration(environment: env).smtp)
    }

    func runCheck(_ config: SMTPConfiguration, tls: TLSConfiguration? = nil, limits: MailCheckLimits = MailCheckLimits()) async -> MailCheckResult {
        await MailCheckRunner(configuration: config, group: MultiThreadedEventLoopGroup.singleton, tls: tls, limits: limits).run()
    }

    func statuses(_ result: MailCheckResult) -> [String] { result.steps.map { "\($0.id):\($0.status)" } }

    func testMailCheckStepsAgainstFakeServer() async throws {
        let (serverTLS, trusted, untrusted) = try tlsFixture()
        // Cleartext (local test setup): TLS and auth are skipped, the dialog ends with RSET and never sends a message.
        let plain = FakeMailServer(); try plain.start(); defer { plain.stop() }
        let ok = await runCheck(try smtp(port: plain.port))
        XCTAssertTrue(ok.ok, ok.summary)
        XCTAssertEqual(statuses(ok), ["dns:ok", "tcp:ok", "tls:skipped", "ehlo:ok", "auth:skipped", "mailFrom:ok"])
        XCTAssertTrue(plain.received.contains("RSET")); XCTAssertFalse(plain.received.contains("DATA"))
        XCTAssertTrue(ok.steps.allSatisfy { $0.durationMs >= 0 }); XCTAssertLessThan(ok.totalMs, 20_000)

        // STARTTLS with a trusted certificate and authentication.
        let secure = FakeMailServer(tls: serverTLS); try secure.start(); defer { secure.stop() }
        let full = await runCheck(try smtp(host: "localhost", port: secure.port, tls: "starttls", auth: true), tls: trusted)
        XCTAssertTrue(full.ok, full.summary)
        XCTAssertEqual(statuses(full), ["dns:ok", "tcp:ok", "tls:ok", "ehlo:ok", "auth:ok", "mailFrom:ok"])
        let certificate = try XCTUnwrap(full.steps.first { $0.id == "tls" }?.certificate)
        XCTAssertTrue(certificate.hostnameMatches); XCTAssertTrue((28...30).contains(certificate.daysLeft))
        let json = String(decoding: try JSONEncoder().encode(full), as: UTF8.self)
        XCTAssertFalse(json.contains(Self.mailPassword)); XCTAssertFalse(json.contains("secret-user"))

        // Implicit TLS.
        let implicit = FakeMailServer(FakeMailServer.Options(implicitTLS: true), tls: serverTLS); try implicit.start(); defer { implicit.stop() }
        let viaImplicit = await runCheck(try smtp(host: "localhost", port: implicit.port, tls: "implicit", auth: true), tls: trusted)
        XCTAssertTrue(viaImplicit.ok, viaImplicit.summary)

        // Wrong credentials: the server's text (which may echo the account) is not passed on.
        let denied = FakeMailServer(FakeMailServer.Options(authOK: false), tls: serverTLS); try denied.start(); defer { denied.stop() }
        let badAuth = await runCheck(try smtp(host: "localhost", port: denied.port, tls: "starttls", auth: true), tls: trusted)
        XCTAssertFalse(badAuth.ok)
        XCTAssertEqual(statuses(badAuth), ["dns:ok", "tcp:ok", "tls:ok", "ehlo:ok", "auth:failed", "mailFrom:skipped"])
        XCTAssertEqual(badAuth.steps[4].problem?.code, "auth_rejected")
        let badJSON = String(decoding: try JSONEncoder().encode(badAuth), as: UTF8.self)
        XCTAssertFalse(badJSON.contains(Self.mailPassword)); XCTAssertFalse(badJSON.contains("secret-user"))

        // Sender rejected.
        let rejecting = FakeMailServer(FakeMailServer.Options(mailFromReply: "550 sender not allowed")); try rejecting.start(); defer { rejecting.stop() }
        let sender = await runCheck(try smtp(port: rejecting.port))
        XCTAssertEqual(sender.steps.last?.problem?.code, "sender_rejected"); XCTAssertEqual(sender.steps.last?.status, "failed")

        // STARTTLS configured but not offered.
        let noTLS = FakeMailServer(FakeMailServer.Options(advertiseStartTLS: false), tls: serverTLS); try noTLS.start(); defer { noTLS.stop() }
        let missing = await runCheck(try smtp(host: "localhost", port: noTLS.port, tls: "starttls"), tls: trusted)
        XCTAssertEqual(missing.steps[2].problem?.code, "starttls_missing")
        XCTAssertEqual(statuses(missing), ["dns:ok", "tcp:ok", "tls:failed", "ehlo:skipped", "auth:skipped", "mailFrom:skipped"])

        // Certificate classes.
        let untrustedRun = await runCheck(try smtp(host: "localhost", port: secure.port, tls: "starttls"), tls: untrusted)
        XCTAssertEqual(untrustedRun.steps[2].problem?.code, "certificate_untrusted")
        XCTAssertEqual(untrustedRun.steps[2].certificate?.issuer, "localhost")
        let ipHost = await runCheck(try smtp(host: "127.0.0.1", port: secure.port, tls: "starttls"), tls: trusted)
        XCTAssertEqual(ipHost.steps[2].problem?.code, "tls_needs_hostname")
        let (otherTLS, otherTrusted, _) = try tlsFixture("other.example.test")
        let wrongName = FakeMailServer(tls: otherTLS); try wrongName.start(); defer { wrongName.stop() }
        let mismatch = await runCheck(try smtp(host: "localhost", port: wrongName.port, tls: "starttls"), tls: otherTrusted)
        XCTAssertEqual(mismatch.steps[2].problem?.code, "certificate_hostname_mismatch")

        // Nothing listens: refused, the rest skipped.
        let closed = FakeMailServer(); try closed.start(); let closedPort = closed.port; closed.stop()
        let refused = await runCheck(try smtp(port: closedPort))
        XCTAssertEqual(refused.steps[1].problem?.code, "connection_refused")
        XCTAssertEqual(statuses(refused), ["dns:ok", "tcp:failed", "tls:skipped", "ehlo:skipped", "auth:skipped", "mailFrom:skipped"])

        // A server that never answers hits the step timeout instead of hanging.
        let silent = FakeMailServer(FakeMailServer.Options(silent: true)); try silent.start(); defer { silent.stop() }
        var limits = MailCheckLimits(); limits.step = .milliseconds(400)
        let started = Date()
        let hung = await runCheck(try smtp(port: silent.port), limits: limits)
        XCTAssertEqual(hung.steps[1].problem?.code, "reply_timeout"); XCTAssertLessThan(Date().timeIntervalSince(started), 3)

        // Unknown host.
        let unknown = await runCheck(try smtp(host: "no-such-host.invalid", port: 25, tls: "starttls"))
        XCTAssertEqual(unknown.steps[0].problem?.code, "host_not_found")
    }

    func testMailHostnameMatchingAndHints() throws {
        XCTAssertTrue(MailCheckRunner.hostnameMatches("smtp.example.org", pattern: "*.example.org"))
        XCTAssertFalse(MailCheckRunner.hostnameMatches("a.smtp.example.org", pattern: "*.example.org"))
        XCTAssertFalse(MailCheckRunner.hostnameMatches("example.org", pattern: "*.example.org"))
        XCTAssertTrue(MailCheckRunner.hostnameMatches("SMTP.example.org", pattern: "smtp.example.org"))
        func hints(_ env: [String: String]) throws -> Set<String> {
            let config = try Configuration(environment: ["SMTP_FROM": "t@example.org"].merging(env) { _, new in new })
            return Set(MailStatusDTO.make(configuration: config).hints.map(\.code))
        }
        XCTAssertTrue(try hints(["SMTP_HOST": "smtp.example.org", "SMTP_PORT": "465"]).contains("port_465_needs_implicit"))
        XCTAssertTrue(try hints(["SMTP_HOST": "smtp.example.org", "SMTP_PORT": "587", "SMTP_TLS": "implicit"]).contains("port_587_needs_starttls"))
        XCTAssertTrue(try hints(["SMTP_HOST": "smtp.other.net"]).contains("from_domain_differs_from_server"))
        XCTAssertTrue(try hints(["SMTP_HOST": "smtp.example.org"]).contains("no_authentication"))
        XCTAssertTrue(try hints(["SMTP_HOST": "localhost", "SMTP_TLS": "off"]).contains("tls_off_local_only"))
        XCTAssertEqual(try hints(["SMTP_HOST": "smtp.example.org", "SMTP_USER": "u", "SMTP_PASSWORD": "p", "PUBLIC_BASE_URL": "https://time.example.org"]), [])
    }

    func testMailStatusEndpointAndGuards() async throws {
        try await withApp { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            let member = try await self.second(app, auth, admin)
            let status = try self.object(await self.api(app, admin, .GET, "admin/mail"))
            XCTAssertEqual(status["configured"] as? Bool, false); XCTAssertNil(status["host"]); XCTAssertEqual(status["source"] as? String, "environment")
            XCTAssertEqual(((status["hints"] as? [[String: Any]])?.first)?["code"] as? String, "not_configured")
            try await self.api(app, admin, .POST, "admin/mail/check", nil, .notImplemented)
            try await self.api(app, admin, .POST, "admin/mail/test", ["to": "a@example.test"], .notImplemented)
            for (method, path) in [(HTTPMethod.GET, "admin/mail"), (.POST, "admin/mail/check"), (.POST, "admin/mail/test")] {
                try await self.api(app, member, method, path, nil, .forbidden)
                let recovery = try await auth.issueSession(for: admin.account, recovery: true, on: app.db)
                try await self.api(app, recovery, method, path, nil, .forbidden)
                let response = try await app.testable().sendRequest(method, "/api/v1/" + path)
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
        let env = ["SMTP_HOST": "smtp.example.org", "SMTP_PORT": "587", "SMTP_FROM": "timetrack@example.org", "SMTP_FROM_NAME": "Timetrack",
                   "SMTP_USER": "secret-user", "SMTP_PASSWORD": Self.mailPassword]
        try await withApp(environment: env) { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            let response = try await self.api(app, admin, .GET, "admin/mail")
            let body = response.body.string
            XCTAssertFalse(body.contains(Self.mailPassword)); XCTAssertFalse(body.contains("secret-user"))
            let status = try self.object(response)
            XCTAssertEqual(status["configured"] as? Bool, true); XCTAssertEqual(status["host"] as? String, "smtp.example.org")
            XCTAssertEqual(status["tls"] as? String, "starttls"); XCTAssertEqual(status["authConfigured"] as? Bool, true)
            XCTAssertEqual(status["fromAddress"] as? String, "timetrack@example.org")
        }
    }

    func testMailCheckEndpointAuditAndRateLimit() async throws {
        let server = FakeMailServer(); try server.start(); defer { server.stop() }
        try await withApp(environment: ["SMTP_HOST": "127.0.0.1", "SMTP_PORT": String(server.port), "SMTP_TLS": "off", "SMTP_FROM": "timetrack@example.test"]) { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            // No fresh session needed for the check.
            try await self.stale(admin, on: app.db)
            let result = try self.object(await self.api(app, admin, .POST, "admin/mail/check"))
            XCTAssertEqual(result["ok"] as? Bool, true); XCTAssertEqual((result["steps"] as? [Any])?.count, 6)
            for _ in 0..<5 { try await self.api(app, admin, .POST, "admin/mail/check") }
            let limited = try await self.api(app, admin, .POST, "admin/mail/check", nil, .tooManyRequests)
            XCTAssertEqual(try self.errorCode(limited), "too_many_requests")
            let audit = try await AccountAuditRecord.query(on: app.db).filter(\.$action == "mail.checked").all()
            XCTAssertEqual(audit.count, 6); XCTAssertTrue(audit.allSatisfy { $0.detail == nil })
            // Rate limit is per admin: a second admin is unaffected.
            let other = try await self.second(app, auth, admin, handle: "admin2")
            other.account.role = .admin; try await other.account.update(on: app.db)
            try await self.api(app, other, .POST, "admin/mail/check")
        }
    }

    func testMailTestSendAndErrorMapping() async throws {
        let server = FakeMailServer(); try server.start(); defer { server.stop() }
        let env = ["SMTP_HOST": "127.0.0.1", "SMTP_PORT": String(server.port), "SMTP_TLS": "off", "SMTP_FROM": "timetrack@example.test"]
        try await withApp(environment: env) { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            let member = try await self.second(app, auth, admin)
            try await self.api(app, member, .POST, "admin/mail/test", ["to": "x@example.test"], .forbidden)
            // No recipient and no verified own address.
            let none = try await self.api(app, admin, .POST, "admin/mail/test", nil, .badRequest)
            XCTAssertEqual(try self.errorCode(none), "no_recipient")
            try await self.api(app, admin, .POST, "admin/mail/test", ["to": "not-an-address"], .badRequest)
            // Own verified address is the default.
            admin.account.email = "own@example.test"; admin.account.emailVerifiedAt = Date(); try await admin.account.update(on: app.db)
            let own = try self.object(await self.api(app, admin, .POST, "admin/mail/test"))
            XCTAssertEqual(own["sent"] as? Bool, true); XCTAssertEqual(own["to"] as? String, "own@example.test"); XCTAssertNotNil(own["durationMs"] as? Int)
            XCTAssertTrue(server.receivedSubjects.contains { $0.contains("=?UTF-8?B?") })
            let explicit = try self.object(await self.api(app, admin, .POST, "admin/mail/test", ["to": " Other@Example.test "]))
            XCTAssertEqual(explicit["to"] as? String, "other@example.test")
            let rcpt = server.received.filter { $0.hasPrefix("RCPT TO:") }
            XCTAssertEqual(rcpt, ["RCPT TO:<own@example.test>", "RCPT TO:<other@example.test>"])
            // Audit holds a hash prefix, never the address.
            let audit = try await AccountAuditRecord.query(on: app.db).filter(\.$action == "mail.test_sent").all()
            XCTAssertEqual(audit.count, 2)
            XCTAssertTrue(audit.allSatisfy { ($0.detail?.count ?? 0) == 16 && !($0.detail ?? "").contains("example") })
            // A stale session may not send mail to arbitrary addresses.
            try await self.stale(admin, on: app.db)
            let stale = try await self.api(app, admin, .POST, "admin/mail/test", ["to": "third@example.test"], .forbidden)
            XCTAssertEqual(try self.errorCode(stale), "reauth_required")
            let fresh = try await self.freshSession(app, auth, "admin")
            // Admin limit: three per ten minutes (two used).
            try await self.api(app, fresh, .POST, "admin/mail/test", ["to": "third@example.test"])
            let limited = try await self.api(app, fresh, .POST, "admin/mail/test", ["to": "fourth@example.test"], .tooManyRequests)
            XCTAssertEqual(try self.errorCode(limited), "too_many_requests")
            // Failure classes.
            try await RateLimitEvent.query(on: app.db).delete()
            server.options.rcptReply = "554 5.7.1 relay access denied"
            let relay = try await self.api(app, fresh, .POST, "admin/mail/test", ["to": "denied@example.test"], .unprocessableEntity)
            XCTAssertEqual(try self.errorCode(relay), "mail_recipient_rejected")
            XCTAssertFalse(relay.body.string.contains("554"))
            server.options.rcptReply = "250 ok"; server.options.mailFromReply = "550 no"
            let senderDenied = try await self.api(app, fresh, .POST, "admin/mail/test", ["to": "a@example.test"], .badGateway)
            XCTAssertEqual(try self.errorCode(senderDenied), "mail_sender_rejected")
            // Per recipient: three per hour.
            try await RateLimitEvent.query(on: app.db).delete()
            server.options.mailFromReply = "250 ok"
            for _ in 0..<3 {
                try await self.api(app, fresh, .POST, "admin/mail/test", ["to": "same@example.test"])
                for event in try await RateLimitEvent.query(on: app.db).all() where event.key.hasPrefix("mailtest:") { try await event.delete(on: app.db) }
            }
            try await self.api(app, fresh, .POST, "admin/mail/test", ["to": "same@example.test"], .tooManyRequests)
        }
        // Server down: connect failure.
        let closed = FakeMailServer(); try closed.start(); let port = closed.port; closed.stop()
        try await withApp(environment: env.merging(["SMTP_PORT": String(port)]) { _, new in new }) { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            let down = try await self.api(app, admin, .POST, "admin/mail/test", ["to": "a@example.test"], .badGateway)
            XCTAssertEqual(try self.errorCode(down), "mail_connect_failed")
        }
    }

    func testMailEndpointsMatchContract() async throws {
        let server = FakeMailServer(); try server.start(); defer { server.stop() }
        let document = try Contract.load()
        var problems: [String] = []
        try await withApp(environment: ["SMTP_HOST": "127.0.0.1", "SMTP_PORT": String(server.port), "SMTP_TLS": "off", "SMTP_FROM": "timetrack@example.test"]) { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            try await self.contractCheck(app, admin, document, .GET, template: "admin/mail", path: "admin/mail", problems: &problems)
            try await self.contractCheck(app, admin, document, .POST, template: "admin/mail/check", path: "admin/mail/check", problems: &problems)
            try await self.contractCheck(app, admin, document, .POST, template: "admin/mail/test", path: "admin/mail/test", body: ["to": "a@example.test"], problems: &problems)
            try await self.contractCheck(app, admin, document, .POST, template: "admin/mail/test", path: "admin/mail/test", body: ["to": "b@example.test"], problems: &problems)
            try await self.contractCheck(app, admin, document, .POST, template: "admin/mail/test", path: "admin/mail/test", body: ["to": "c@example.test"], problems: &problems)
            server.options.rcptReply = "550 no"
            try await RateLimitEvent.query(on: app.db).delete()
            try await self.contractCheck(app, admin, document, .POST, template: "admin/mail/test", path: "admin/mail/test", body: ["to": "d@example.test"], status: .unprocessableEntity, problems: &problems)
        }
        try await withApp { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            try await self.contractCheck(app, admin, document, .GET, template: "admin/mail", path: "admin/mail", problems: &problems)
        }
        XCTAssertEqual(problems, [])
    }

    func testMailDiagnosisMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let server = FakeMailServer(); try server.start(); defer { server.stop() }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_mail1", "DB_TLS": "off",
            "SMTP_HOST": "127.0.0.1", "SMTP_PORT": String(server.port), "SMTP_TLS": "off", "SMTP_FROM": "timetrack@example.test"]
        try await withApp(environment: environment) { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            try await self.api(app, admin, .POST, "admin/mail/check")
            try await self.api(app, admin, .POST, "admin/mail/test", ["to": "a@example.test"])
            for _ in 0..<5 { try await self.api(app, admin, .POST, "admin/mail/check") }
            try await self.api(app, admin, .POST, "admin/mail/check", nil, .tooManyRequests)
            let actions = try await AccountAuditRecord.query(on: app.db).all().map(\.action).filter { $0.hasPrefix("mail.") }.sorted()
            XCTAssertEqual(actions.count, 7)
        }
    }

    /// Manual check against a running Mailpit (docs/TESTUMGEBUNGEN.md): `MAILPIT_SMTP_PORT=11025 swift test --filter testMailCheckAgainstMailpit`.
    func testMailCheckAgainstMailpit() async throws {
        guard let port = ProcessInfo.processInfo.environment["MAILPIT_SMTP_PORT"].flatMap(Int.init) else { throw XCTSkip("MAILPIT_SMTP_PORT not set") }
        let result = await runCheck(try smtp(host: "localhost", port: port))
        for step in result.steps { print("MAILPIT-STEP \(step.id) \(step.status) \(step.durationMs)ms \(step.details.joined(separator: " | "))") }
        print("MAILPIT-RESULT ok=\(result.ok) total=\(result.totalMs)ms")
        XCTAssertTrue(result.ok)
    }
}
