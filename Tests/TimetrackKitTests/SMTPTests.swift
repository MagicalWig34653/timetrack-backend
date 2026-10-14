import XCTVapor
import NIOCore
import NIOEmbedded
import NIOSSL
import NIOTLS
@testable import TimetrackKit

final class SMTPTests: XCTestCase {
    func testConfigurationValidation() throws {
        XCTAssertNil(try Configuration(environment: [:]).smtp)
        let base = ["SMTP_HOST": "smtp.example.test", "SMTP_FROM": "sender@example.test"]
        let defaults = try XCTUnwrap(Configuration(environment: base).smtp)
        XCTAssertEqual(defaults.port, 587); XCTAssertEqual(defaults.tls, .starttls)
        for patch in [["SMTP_FROM": ""], ["SMTP_FROM": "a@example.test\r\nBcc: b@example.test"],
                      ["SMTP_FROM": "a<>@example.test"], ["SMTP_FROM_NAME": "Name\nBcc:"], ["SMTP_FROM_NAME": "Name\r\nBcc:"],
                      ["SMTP_TLS": "off"], ["SMTP_TLS": "invalid"], ["SMTP_PORT": "0"],
                      ["SMTP_USER": "user"], ["SMTP_PASSWORD": "password"], ["SMTP_HOST": "bad\nhost"]] {
            XCTAssertThrowsError(try Configuration(environment: base.merging(patch) { _, new in new }))
        }
        XCTAssertThrowsError(try Configuration(environment: ["SMTP_HOST": "localhost"]))
        for host in ["localhost", "127.0.0.1", "::1", "mailpit"] {
            let env = base.merging(["SMTP_HOST": host, "SMTP_TLS": "off"]) { _, new in new }
            XCTAssertNoThrow(try Configuration(environment: env))
            XCTAssertThrowsError(try Configuration(environment: env.merging(["SMTP_USER": "user", "SMTP_PASSWORD": "password"]) { _, new in new }))
        }
    }

    func testMessageEncodingAndInjectionRejection() throws {
        let config = try XCTUnwrap(Configuration(environment: ["SMTP_HOST": "localhost", "SMTP_FROM": "sender@example.test", "SMTP_FROM_NAME": "Jörg Beispiel"]).smtp)
        for address in ["a@example.test\r\nBcc: b@example.test", "a@example.test\n.", "a@example.test> X", "ä@example.test"] {
            XCTAssertThrowsError(try SMTPMailSender.message(configuration: config, address: address, subject: "Subject", body: "Body"))
        }
        XCTAssertThrowsError(try SMTPMailSender.message(configuration: config, address: "a@example.test", subject: "Subject\r\nX: y", body: "Body"))
        let message = try SMTPMailSender.message(configuration: config, address: "a@example.test", subject: "Grüße", body: ".first\n..second\nÄ =\n" + String(repeating: "ü", count: 100))
        XCTAssertTrue(message.contains("\r\n..first\r\n...second\r\n=C3=84=20=3D\r\n"))
        XCTAssertTrue(message.contains("Subject: =?UTF-8?B?\(Data("Grüße".utf8).base64EncodedString())?="))
        XCTAssertTrue(message.contains("Content-Type: text/plain; charset=UTF-8"))
        XCTAssertTrue(message.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count < 998 })
        XCTAssertTrue(message.hasSuffix("\r\n.\r\n"))
    }

    func testCleartextDialogAndDotStuffing() throws {
        let transcript = try runDialog(mode: .off)
        XCTAssertEqual(Array(transcript.prefix(4)), ["EHLO localhost", "MAIL FROM:<sender@example.test>", "RCPT TO:<recipient@example.test>", "DATA"])
        XCTAssertFalse(transcript.contains(where: { $0.hasPrefix("AUTH") || $0 == "STARTTLS" }))
        XCTAssertTrue(transcript.contains("..test-code"))
        XCTAssertTrue(transcript.contains("Content-Transfer-Encoding: quoted-printable"))
        XCTAssertTrue(transcript.contains(where: { $0.contains("zehn=20Minuten=20g=C3=BCltig") }))
    }

    func testSTARTTLSAndAuthentication() throws {
        let transcript = try runDialog(mode: .starttls)
        XCTAssertEqual(Array(transcript.prefix(4)), ["EHLO localhost", "STARTTLS", "EHLO localhost", "AUTH PLAIN \(Data("\0test-user\0test-password".utf8).base64EncodedString())"])
    }

    func testImplicitTLSAndAuthenticationChallenge() throws {
        let transcript = try runDialog(mode: .implicit, challenge: true)
        XCTAssertEqual(transcript[0], "EHLO localhost")
        XCTAssertTrue(transcript[1].hasPrefix("AUTH PLAIN "))
        XCTAssertEqual(transcript[2], Data("\0test-user\0test-password".utf8).base64EncodedString())
        XCTAssertFalse(transcript.contains("STARTTLS"))
    }

    func testMissingSTARTTLSFailsClosed() throws {
        _ = try runDialog(mode: .starttls, failure: .missingTLS)
    }

    func testUntrustedCertificateFailsClosed() throws {
        _ = try runDialog(mode: .starttls, failure: .untrusted)
    }

    func testNegativeReplyAndTimeout() throws {
        _ = try runDialog(mode: .off, failure: .rejected)
        _ = try runDialog(mode: .off, failure: .silent)
        _ = try runDialog(mode: .starttls, failure: .authentication)
        _ = try runDialog(mode: .off, failure: .recipient)
    }

    private enum Failure { case missingTLS, untrusted, rejected, silent, authentication, recipient }
    private func runDialog(mode: SMTPConfiguration.TLS, challenge: Bool = false, failure: Failure? = nil) throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var serverTLS: NIOSSLContext?
        var clientTLS = TLSConfiguration.makeClientConfiguration()
        clientTLS.minimumTLSVersion = .tlsv12
        if mode != .off {
            // Generate ephemeral test-only credentials; never persist private keys in the repository.
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", directory.appendingPathComponent("key.pem").path,
                "-out", directory.appendingPathComponent("cert.pem").path, "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
            let cert = try NIOSSLCertificate.fromPEMFile(directory.appendingPathComponent("cert.pem").path)
            let key = try NIOSSLPrivateKey(file: directory.appendingPathComponent("key.pem").path, format: .pem)
            serverTLS = try NIOSSLContext(configuration: .makeServerConfiguration(certificateChain: cert.map { .certificate($0) }, privateKey: .privateKey(key)))
            if failure != .untrusted { clientTLS.trustRoots = .certificates(cert) }
        }
        let loop = EmbeddedEventLoop()
        let record = loop.makePromise(of: [String].self)
        let completion = loop.makePromise(of: Void.self)
        let server = EmbeddedChannel(loop: loop), client = EmbeddedChannel(loop: loop)
        defer {
            _ = try? client.finish(); _ = try? server.finish()
        }
        if mode == .implicit, let serverTLS {
            try server.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: serverTLS))
        }
        try server.pipeline.syncOperations.addHandler(FakeSMTP(tls: serverTLS, record: record,
            advertiseTLS: failure != .missingTLS, challenge: challenge, rejected: failure == .rejected, silent: failure == .silent, rejectAuth: failure == .authentication, rejectRecipient: failure == .recipient))
        var environment = ["SMTP_HOST": "localhost", "SMTP_TLS": mode.rawValue, "SMTP_FROM": "sender@example.test"]
        if mode != .off { environment["SMTP_USER"] = "test-user"; environment["SMTP_PASSWORD"] = "test-password" }
        let config = try XCTUnwrap(Configuration(environment: environment).smtp)
        let sender = try SMTPMailSender(configuration: config, group: loop, tlsConfiguration: clientTLS)
        let context = try NIOSSLContext(configuration: clientTLS)
        try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1025)).wait()
        if mode == .implicit {
            try client.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: config.host))
        }
        try client.pipeline.syncOperations.addHandler(SMTPDialog(configuration: config, tlsContext: context,
            recipient: "recipient@example.test", message: sender.makeMessage(code: ".test-code", address: "recipient@example.test"),
            completion: completion, timeout: .seconds(1)))
        try server.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1025)).wait()
        for _ in 0..<100 {
            var moved = false
            while let bytes = try client.readOutbound(as: ByteBuffer.self) {
                _ = try? server.writeInbound(bytes); moved = true
            }
            while let bytes = try server.readOutbound(as: ByteBuffer.self) {
                _ = try? client.writeInbound(bytes); moved = true
            }
            loop.run()
            if !moved { break }
        }
        loop.advanceTime(by: .seconds(2))
        do { try completion.futureResult.wait(); XCTAssertNil(failure) }
        catch { XCTAssertNotNil(failure) }
        _ = try? client.finish(); _ = try? server.finish()
        let transcript = try record.futureResult.wait()
        if failure == .authentication || failure == .recipient {
            XCTAssertFalse(transcript.contains("DATA"))
        } else if failure != nil {
            XCTAssertFalse(transcript.contains(where: { $0.hasPrefix("AUTH") || $0.hasPrefix("RCPT") }))
        }
        return transcript
    }
}

private final class FakeSMTP: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let tls: NIOSSLContext?
    let record: EventLoopPromise<[String]>
    let advertiseTLS: Bool
    let challenge: Bool
    let rejected: Bool
    let silent: Bool
    let rejectAuth: Bool
    let rejectRecipient: Bool
    var buffer = "", transcript: [String] = []
    var dataMode = false, waitingAuth = false, recorded = false
    init(tls: NIOSSLContext?, record: EventLoopPromise<[String]>, advertiseTLS: Bool, challenge: Bool, rejected: Bool, silent: Bool, rejectAuth: Bool, rejectRecipient: Bool) {
        self.tls = tls; self.record = record; self.advertiseTLS = advertiseTLS
        self.challenge = challenge; self.rejected = rejected; self.silent = silent
        self.rejectAuth = rejectAuth; self.rejectRecipient = rejectRecipient
    }
    func reply(_ context: ChannelHandlerContext, _ value: String) {
        var bytes = context.channel.allocator.buffer(capacity: value.utf8.count); bytes.writeString(value)
        context.writeAndFlush(wrapOutboundOut(bytes), promise: nil)
    }
    func channelActive(context: ChannelHandlerContext) {
        if !silent { reply(context, rejected ? "554 unavailable\r\n" : "220 fake SMTP\r\n") }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data); buffer += bytes.readString(length: bytes.readableBytes) ?? ""
        while let end = buffer.range(of: "\r\n") {
            let line = String(buffer[..<end.lowerBound]); buffer.removeSubrange(..<end.upperBound); transcript.append(line)
            if dataMode {
                if line == "." { dataMode = false; reply(context, "250 accepted\r\n") }
            } else if waitingAuth { waitingAuth = false; reply(context, "235 authenticated\r\n") }
            else if line.hasPrefix("EHLO") {
                reply(context, "250-fake\r\n" + (advertiseTLS ? "250-STARTTLS\r\n" : "") + "250 AUTH PLAIN\r\n")
            } else if line == "STARTTLS", let tls {
                reply(context, "220 ready\r\n")
                do { try context.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls), position: .first) }
                catch { context.close(promise: nil) }
            } else if line.hasPrefix("AUTH PLAIN") {
                waitingAuth = challenge; reply(context, rejectAuth ? "535 denied\r\n" : (challenge ? "334 \r\n" : "235 authenticated\r\n"))
            } else if line.hasPrefix("RCPT TO:"), rejectRecipient { reply(context, "550 denied\r\n") }
            else if line.hasPrefix("MAIL FROM:") || line.hasPrefix("RCPT TO:") { reply(context, "250 ok\r\n") }
            else if line == "DATA" { dataMode = true; reply(context, "354 send message\r\n") }
            else if line == "QUIT" { context.close(promise: nil) }
            else { reply(context, "500 unexpected\r\n") }
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !recorded { recorded = true; record.succeed(transcript) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}


extension AuthTests {
    func testConfiguredSMTPEnablesRecoveryWithoutInjectedSender() async throws {
        try await withApp(environment: ["SMTP_HOST": "localhost", "SMTP_TLS": "off", "SMTP_FROM": "sender@example.test"]) { app, service in
            let (context, _) = try await registered(service, db: app.db)
            try await app.test(.GET, "/api/v1/me/recovery", headers: headers(context)) { response async throws in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue(try response.content.decode(RecoveryStatusDTO.self).email.available)
            }
        }
    }
}
