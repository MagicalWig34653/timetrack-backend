import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

// Errors deliberately exclude server responses, addresses, credentials and message content.
enum SMTPError: Error { case invalidMessage, protocolFailure, deliveryFailed, timeout, failed(MailFailureKind) }

/// Coarse failure classes (ADR-0022). They carry no server text, so they are safe to map to user messages.
enum MailFailureKind: String, Sendable { case connect, tls, auth, sender, recipient, timeout, other }

struct RecoveryMailText: Decodable, Sendable {
    let subject: String
    let body: String
}

public struct SMTPMailSender: MailSender {
    private let configuration: SMTPConfiguration
    private let group: any EventLoopGroup
    private let tlsContext: NIOSSLContext
    private let text: RecoveryMailText
    private let timeout: TimeAmount
    let brand: MailBrand

    public init(configuration: SMTPConfiguration, group: any EventLoopGroup, brand: MailBrand = MailBrand()) throws {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        try self.init(configuration: configuration, group: group, tlsConfiguration: tls, brand: brand)
    }

    // Internal trust configuration permits local certificate fixtures without weakening production verification.
    init(configuration: SMTPConfiguration, group: any EventLoopGroup,
         tlsConfiguration: TLSConfiguration, timeout: TimeAmount = .seconds(30), brand: MailBrand = MailBrand()) throws {
        self.configuration = configuration; self.group = group; self.timeout = timeout; self.brand = brand
        tlsContext = try NIOSSLContext(configuration: tlsConfiguration)
        guard let url = Bundle.module.url(forResource: "RecoveryMail.de", withExtension: "json") else { throw SMTPError.invalidMessage }
        text = try JSONDecoder().decode(RecoveryMailText.self, from: Data(contentsOf: url))
    }

    public func sendCode(_ code: String, to address: String) async throws {
        do { try await deliver(try makeMessage(code: code, address: address), to: address) }
        catch { throw SMTPError.deliveryFailed }
    }

    /// Sends the fixed test message of the mail diagnosis (ADR-0022); the failure class is the only detail that leaves.
    func sendTest(_ mail: RenderedMail, to address: String) async throws {
        let message = try Self.message(configuration: configuration, address: address, subject: mail.subject, body: mail.text, html: mail.html)
        try await deliver(message, to: address)
    }

    /// Throws `SMTPError.failed(kind)` for every delivery problem.
    private func deliver(_ message: String, to address: String) async throws {
        let loop = group.next()
        let config = configuration, tls = tlsContext, timeout = timeout
        do {
            // Pause reads until the connected channel has its complete protocol pipeline.
            // Each send owns one connection; DNS connection attempts cannot share dialog state.
            let channel = try await ClientBootstrap(group: loop).connectTimeout(.seconds(10))
                .channelOption(ChannelOptions.autoRead, value: false)
                .connect(host: config.host, port: config.port).get()
            let completion = loop.makePromise(of: Void.self)
            do {
                try await loop.submit {
                    if config.tls == .implicit {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: config.host))
                    }
                    try channel.pipeline.syncOperations.addHandler(SMTPDialog(configuration: config, tlsContext: tls,
                        recipient: address, message: message, completion: completion, timeout: timeout))
                }.get()
                try await channel.setOption(ChannelOptions.autoRead, value: true).get()
                try await completion.futureResult.get()
                try? await channel.close().get()
            } catch {
                completion.fail(SMTPError.failed(.other))
                try? await channel.close().get()
                throw error
            }
        } catch {
            // NIO/TLS errors may include endpoint details; expose only a fixed class.
            if case SMTPError.failed = error { throw error }
            throw SMTPError.failed(.connect)
        }
    }

    func makeMessage(code: String, address: String) throws -> String {
        let mail = MailTemplates.verificationCode(code, text: text, brand: brand)
        return try Self.message(configuration: configuration, address: address, subject: mail.subject, body: mail.text, html: mail.html)
    }

    static func encodedHeader(_ value: String) -> String {
        var words: [String] = [], chunk = ""
        for character in value.unicodeScalars {
            if chunk.utf8.count + String(character).utf8.count > 30 && !chunk.isEmpty {
                words.append("=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?="); chunk = ""
            }
            chunk.unicodeScalars.append(character)
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?=") }
        return words.joined(separator: "\r\n ")
    }

    /// Builds the SMTP DATA payload. Without `html` the message is a single quoted-printable text/plain part;
    /// with `html` it is multipart/alternative (text first, HTML last, as RFC 2046 prefers the last part).
    static func message(configuration: SMTPConfiguration, address: String, subject: String, body: String, html: String? = nil) throws -> String {
        guard SMTPConfiguration.validAddress(address), !subject.utf8.contains(13), !subject.utf8.contains(10) else { throw SMTPError.invalidMessage }
        let from = configuration.fromName.map { encodedHeader($0) + " " } ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var headers = ["From: \(from)<\(configuration.from)>", "To: <\(address)>",
            "Subject: \(encodedHeader(subject))", "Date: \(formatter.string(from: Date()))",
            "Message-ID: <\(UUID().uuidString)@\(configuration.from.split(separator: "@")[1])>",
            "MIME-Version: 1.0"]
        let content: String
        if let html {
            let boundary = "=_timetrack_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            headers.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
            let part = { (type: String, value: String) in
                "--\(boundary)\r\nContent-Type: \(type); charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n\(quotedPrintable(value))\r\n"
            }
            content = part("text/plain", body) + part("text/html", html) + "--\(boundary)--"
        } else {
            headers += ["Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: quoted-printable"]
            content = quotedPrintable(body)
        }
        return dotStuff(headers.joined(separator: "\r\n") + "\r\n\r\n" + content) + "\r\n.\r\n"
    }

    static func quotedPrintable(_ body: String) -> String {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").map { line in
            var output = "", length = 0
            for byte in line.utf8 {
                let token = (33...126).contains(byte) && byte != 61 ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
                if length + token.count > 72 { output += "=\r\n"; length = 0 }
                output += token; length += token.count
            }
            return output
        }.joined(separator: "\r\n")
    }

    static func dotStuff(_ value: String) -> String {
        value.components(separatedBy: "\r\n").map { $0.hasPrefix(".") ? "." + $0 : $0 }.joined(separator: "\r\n")
    }
}

final class SMTPDialog: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private enum State { case greeting, ehlo, startTLS, handshake, secureEHLO, auth, authChallenge, mail, recipient, data, body, finished }
    private var state: State = .greeting
    private let configuration: SMTPConfiguration
    private let tlsContext: NIOSSLContext
    private let recipient: String
    private let message: String
    private let completion: EventLoopPromise<Void>
    private let timeout: TimeAmount
    private var timer: Scheduled<Void>?
    private var buffer = ""
    private var response: [String] = []
    private var responseCode: Int?
    private var responseBytes = 0
    private var finished = false

    init(configuration: SMTPConfiguration, tlsContext: NIOSSLContext, recipient: String, message: String,
         completion: EventLoopPromise<Void>, timeout: TimeAmount) {
        self.configuration = configuration; self.tlsContext = tlsContext; self.recipient = recipient
        self.message = message; self.completion = completion; self.timeout = timeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { startTimer(context) }
    }

    private func startTimer(_ context: ChannelHandlerContext) {
        guard timer == nil else { return }
        let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        timer = context.eventLoop.scheduleTask(in: timeout) {
            bound.value.0.fail(bound.value.1, SMTPError.timeout)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        startTimer(context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        buffer += bytes.readString(length: bytes.readableBytes) ?? ""
        guard buffer.utf8.count <= 16384 else { fail(context); return }
        while let end = buffer.range(of: "\r\n"), !finished {
            let line = String(buffer[..<end.lowerBound]); buffer.removeSubrange(..<end.upperBound)
            let raw = Array(line.utf8)
            guard raw.count >= 4, raw.count <= 512, let code = Int(String(line.prefix(3))),
                  raw[3] == 32 || raw[3] == 45, responseCode == nil || responseCode == code else { fail(context); return }
            responseCode = code; responseBytes += raw.count
            guard responseBytes <= 16384 else { fail(context); return }
            response.append(String(line.dropFirst(4)))
            if raw[3] == 32 {
                let lines = response; response = []; responseCode = nil; responseBytes = 0
                advance(context, code: code, lines: lines)
            }
        }
    }

    private func write(_ context: ChannelHandlerContext, _ command: String) {
        var bytes = context.channel.allocator.buffer(capacity: command.utf8.count); bytes.writeString(command)
        context.writeAndFlush(wrapOutboundOut(bytes), promise: nil)
    }

    private func advance(_ context: ChannelHandlerContext, code: Int, lines: [String]) {
        switch state {
        case .greeting:
            guard code == 220 else { fail(context); return }
            state = configuration.tls == .implicit ? .secureEHLO : .ehlo
            write(context, "EHLO localhost\r\n")
        case .ehlo, .secureEHLO:
            guard code == 250 else { fail(context); return }
            let capabilities = lines.map { $0.uppercased().split(separator: " ").map(String.init) }
            if state == .ehlo && configuration.tls == .starttls {
                guard capabilities.contains(where: { $0.first == "STARTTLS" }) else { fail(context); return }
                state = .startTLS; write(context, "STARTTLS\r\n")
            } else if let user = configuration.user, let password = configuration.password {
                guard state == .secureEHLO,
                      capabilities.contains(where: { $0.first == "AUTH" && $0.dropFirst().contains("PLAIN") }) else { fail(context); return }
                state = .auth
                write(context, "AUTH PLAIN \(Data(("\0" + user + "\0" + password).utf8).base64EncodedString())\r\n")
            } else { startMail(context) }
        case .startTLS:
            guard code == 220, buffer.isEmpty else { fail(context); return }
            state = .handshake
            do {
                try context.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tlsContext, serverHostname: configuration.host), position: .first)
            } catch { fail(context) }
        case .auth:
            if code == 334, let user = configuration.user, let password = configuration.password {
                state = .authChallenge
                write(context, Data(("\0" + user + "\0" + password).utf8).base64EncodedString() + "\r\n")
            } else if code == 235 { startMail(context) } else { fail(context) }
        case .authChallenge:
            guard code == 235 else { fail(context); return }; startMail(context)
        case .mail:
            guard code == 250 else { fail(context); return }
            state = .recipient; write(context, "RCPT TO:<\(recipient)>\r\n")
        case .recipient:
            guard code == 250 || code == 251 else { fail(context); return }
            state = .data; write(context, "DATA\r\n")
        case .data:
            guard code == 354 else { fail(context); return }
            state = .body; write(context, message)
        case .body:
            guard code == 250 else { fail(context); return }
            // Acceptance is final; a lost QUIT reply must not cause a duplicate delivery retry.
            state = .finished; finished = true; timer?.cancel()
            write(context, "QUIT\r\n"); completion.succeed(())
        default: fail(context)
        }
    }

    private func startMail(_ context: ChannelHandlerContext) {
        state = .mail; write(context, "MAIL FROM:<\(configuration.from)>\r\n")
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event, state == .handshake {
            state = .secureEHLO; write(context, "EHLO localhost\r\n")
        }
        context.fireUserInboundEventTriggered(event)
    }

    private func fail(_ context: ChannelHandlerContext, _ error: SMTPError = .protocolFailure, tlsError: Bool = false) {
        guard !finished else { return }; finished = true; timer?.cancel()
        let kind: MailFailureKind
        if case .timeout = error { kind = .timeout } else if tlsError { kind = .tls } else {
            switch state {
            case .startTLS, .handshake: kind = .tls
            case .auth, .authChallenge: kind = .auth
            case .mail: kind = .sender
            case .recipient: kind = .recipient
            case .ehlo where configuration.tls == .starttls: kind = .tls
            default: kind = .other
            }
        }
        completion.fail(SMTPError.failed(kind)); context.close(promise: nil)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(context, tlsError: error is NIOSSLError || error is BoringSSLError || error is NIOSSLExtraError) }
    func channelInactive(context: ChannelHandlerContext) { fail(context); context.fireChannelInactive() }
}
