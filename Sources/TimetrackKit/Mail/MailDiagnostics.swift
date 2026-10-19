import Foundation
import Vapor
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Time limits of one diagnostic run. Tests shorten them.
struct MailCheckLimits: Sendable {
    var connect: TimeAmount = .seconds(8)
    /// One reply or the TLS handshake.
    var step: TimeAmount = .seconds(8)
    /// The whole run, regardless of how many steps are left.
    var total: TimeAmount = .seconds(20)
}

/// Test hooks (trust roots of a local certificate, shorter limits). Production never sets them.
struct MailCheckOverrides: Sendable {
    var limits = MailCheckLimits()
    var tls: TLSConfiguration?
}
struct MailCheckOverridesKey: StorageKey { typealias Value = MailCheckOverrides }

enum SMTPProbeError: Error { case timeout, closed, protocolViolation, notFound }

struct SMTPReply: Sendable, Equatable {
    let code: Int
    let lines: [String]
    var text: String { lines.first ?? "" }
}

/// Reads SMTP replies and the TLS handshake result on the event loop. All members run on that loop only.
final class SMTPProbeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var buffer = ""
    private var lines: [String] = []
    private var code: Int?
    private var size = 0
    private var ready: [SMTPReply] = []
    private var failure: (any Error)?
    private var handshakeDone = false
    private var replyWaiter: (EventLoopPromise<SMTPReply>, Scheduled<Void>)?
    private var handshakeWaiter: (EventLoopPromise<Void>, Scheduled<Void>)?

    func nextReply(loop: any EventLoop, timeout: TimeAmount) -> EventLoopFuture<SMTPReply> {
        if !ready.isEmpty { return loop.makeSucceededFuture(ready.removeFirst()) }
        if let failure { return loop.makeFailedFuture(failure) }
        let promise = loop.makePromise(of: SMTPReply.self)
        let timer = loop.scheduleTask(in: timeout) { [self] in fail(SMTPProbeError.timeout) }
        replyWaiter = (promise, timer)
        return promise.futureResult
    }

    func waitHandshake(loop: any EventLoop, timeout: TimeAmount) -> EventLoopFuture<Void> {
        if handshakeDone { return loop.makeSucceededVoidFuture() }
        if let failure { return loop.makeFailedFuture(failure) }
        let promise = loop.makePromise(of: Void.self)
        let timer = loop.scheduleTask(in: timeout) { [self] in fail(SMTPProbeError.timeout) }
        handshakeWaiter = (promise, timer)
        return promise.futureResult
    }

    private func fail(_ error: any Error) {
        if failure == nil { failure = error }
        if let (promise, timer) = replyWaiter { replyWaiter = nil; timer.cancel(); promise.fail(failure ?? error) }
        if let (promise, timer) = handshakeWaiter { handshakeWaiter = nil; timer.cancel(); promise.fail(failure ?? error) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        buffer += bytes.readString(length: bytes.readableBytes) ?? ""
        guard buffer.utf8.count <= 16384 else { fail(SMTPProbeError.protocolViolation); context.close(promise: nil); return }
        while let end = buffer.range(of: "\r\n") {
            let line = String(buffer[..<end.lowerBound]); buffer.removeSubrange(..<end.upperBound)
            let raw = Array(line.utf8)
            guard raw.count >= 4, raw.count <= 512, let value = Int(String(line.prefix(3))),
                  raw[3] == 32 || raw[3] == 45, code == nil || code == value else {
                fail(SMTPProbeError.protocolViolation); context.close(promise: nil); return
            }
            code = value; size += raw.count
            guard size <= 16384 else { fail(SMTPProbeError.protocolViolation); context.close(promise: nil); return }
            lines.append(String(line.dropFirst(4)))
            if raw[3] == 32 {
                let reply = SMTPReply(code: value, lines: lines)
                lines = []; code = nil; size = 0
                if let (promise, timer) = replyWaiter { replyWaiter = nil; timer.cancel(); promise.succeed(reply) } else { ready.append(reply) }
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            handshakeDone = true
            if let (promise, timer) = handshakeWaiter { handshakeWaiter = nil; timer.cancel(); promise.succeed(()) }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) { fail(SMTPProbeError.closed); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { fail(error); context.close(promise: nil) }
}

private struct StepBody {
    var details: [String] = []
    var warnings: [String] = []
    var certificate: MailCheckCertificate?
    var skipReason: String?
}
private struct StepFailure: Error {
    let problem: MailCheckProblem
    var details: [String] = []
    var certificate: MailCheckCertificate?
}

/// Live diagnostic of the configured SMTP server (ADR-0022). Sends no message: the dialog stops after `MAIL FROM` and `RSET`.
final class MailCheckRunner: @unchecked Sendable {
    private let config: SMTPConfiguration
    private let group: any EventLoopGroup
    private let tlsConfiguration: TLSConfiguration
    private let limits: MailCheckLimits
    private let clock = ContinuousClock()
    private let deadline: ContinuousClock.Instant
    private var channel: (any Channel)?
    private var handler: SMTPProbeHandler?
    private var loop: (any EventLoop)?
    private var capabilities: [String] = []

    init(configuration: SMTPConfiguration, group: any EventLoopGroup, tls: TLSConfiguration? = nil, limits: MailCheckLimits = MailCheckLimits()) {
        config = configuration; self.group = group; self.limits = limits
        var base = tls ?? TLSConfiguration.makeClientConfiguration()
        base.minimumTLSVersion = .tlsv12
        tlsConfiguration = base
        deadline = clock.now.advanced(by: .nanoseconds(Int(limits.total.nanoseconds)))
    }

    // MARK: Run

    func run() async -> MailCheckResult {
        let start = clock.now
        var steps: [MailCheckStep] = []
        var failed = false
        let plan: [(String, String)] = [("dns", "Servername auflösen"), ("tcp", "Verbindung aufbauen"), ("tls", "Verschlüsselung"),
                                        ("ehlo", "Server-Fähigkeiten"), ("auth", "Anmeldung"), ("mailFrom", "Absender prüfen")]
        for (id, title) in plan {
            if failed {
                steps.append(MailCheckStep(id: id, title: title, status: "skipped", durationMs: 0, details: ["Übersprungen, weil ein früherer Schritt fehlgeschlagen ist."],
                                           warnings: [], certificate: nil, problem: nil))
                continue
            }
            let step = await execute(id, title)
            if step.status == "failed" { failed = true }
            steps.append(step)
        }
        await closeConnection()
        let problem = steps.first { $0.status == "failed" }
        let summary = problem.map { "Die Prüfung ist bei „\($0.title)“ fehlgeschlagen. \($0.problem?.message ?? "")" }
            ?? "Alles in Ordnung: Der Server ist erreichbar, die Verschlüsselung und die Anmeldung funktionieren und der Absender wird akzeptiert. Es wurde keine Nachricht gesendet."
        // Defence in depth: configured credentials never leave in any returned text, whatever produced it.
        let secrets = redactionSecrets()
        func scrub(_ value: String) -> String { Self.redact(value, secrets: secrets) }
        let safeSteps = steps.map { step in
            MailCheckStep(id: step.id, title: step.title, status: step.status, durationMs: step.durationMs, details: step.details.map(scrub),
                          warnings: step.warnings.map(scrub), certificate: step.certificate,
                          problem: step.problem.map { MailCheckProblem(code: $0.code, message: scrub($0.message), advice: scrub($0.advice)) })
        }
        return MailCheckResult(ok: problem == nil, summary: scrub(summary), checkedAt: Date(), totalMs: Self.milliseconds(clock.now - start), steps: safeSteps)
    }

    private func execute(_ id: String, _ title: String) async -> MailCheckStep {
        let start = clock.now
        func step(_ status: String, _ body: StepBody, _ problem: MailCheckProblem? = nil) -> MailCheckStep {
            MailCheckStep(id: id, title: title, status: status, durationMs: Self.milliseconds(clock.now - start), details: body.details,
                          warnings: body.warnings, certificate: body.certificate, problem: problem)
        }
        do {
            let body: StepBody
            switch id {
            case "dns": body = try await dnsStep()
            case "tcp": body = try await tcpStep()
            case "tls": body = try await tlsStep()
            case "ehlo": body = try await ehloStep()
            case "auth": body = try await authStep()
            default: body = try await mailFromStep()
            }
            guard let reason = body.skipReason else { return step("ok", body) }
            var skipped = body; skipped.details = [reason]
            return step("skipped", skipped)
        } catch let failure as StepFailure {
            return step("failed", StepBody(details: failure.details, certificate: failure.certificate), failure.problem)
        } catch {
            return step("failed", StepBody(), MailCheckProblem(code: "unexpected", message: "Unerwarteter Fehler bei der Prüfung.",
                advice: "Versuche die Prüfung erneut. Tritt der Fehler wieder auf, sieh in den Server-Logs nach."))
        }
    }

    private func redactionSecrets() -> [String] {
        var secrets: [String] = []
        // A user name that equals the sender address stays readable: SMTP_FROM is shown on purpose in the messages.
        if let user = config.user, user.lowercased() != config.from.lowercased() { secrets.append(user) }
        if let password = config.password {
            secrets.append(password)
            if let user = config.user { secrets.append(Data(("\0" + user + "\0" + password).utf8).base64EncodedString()) }
        }
        return secrets
    }

    // MARK: Steps

    private func dnsStep() async throws -> StepBody {
        let host = config.host
        do {
            let addresses = try await Self.resolve(host, timeout: budget(limits.step))
            let shown = addresses.prefix(6).joined(separator: ", ") + (addresses.count > 6 ? " …" : "")
            return StepBody(details: ["\(host) → \(addresses.count == 1 ? "1 Adresse" : "\(addresses.count) Adressen"): \(shown)"])
        } catch SMTPProbeError.timeout {
            throw failure("dns_timeout", "Die Namensauflösung für „\(Self.clean(host))“ hat zu lange gedauert.",
                          "Prüfe den DNS-Server des Hosts bzw. des Containers. Im Docker-Netz hilft ein Blick in die DNS-Einstellungen des Stacks.")
        } catch {
            throw failure("host_not_found", "Der Servername „\(Self.clean(host))“ ist unbekannt.",
                          "Prüfe SMTP_HOST auf Tippfehler. Im Docker-Netz muss ein Dienstname im selben Netzwerk liegen wie Timetrack.")
        }
    }

    private func tcpStep() async throws -> StepBody {
        let allowed = try budget(limits.step)
        let connectTimeout = min(limits.connect, allowed)
        let handler = SMTPProbeHandler()
        let channel: any Channel
        do {
            channel = try await ClientBootstrap(group: group.next()).connectTimeout(connectTimeout)
                .channelInitializer { channel in channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(handler) } }
                .connect(host: config.host, port: config.port).get()
        } catch {
            throw connectFailure(error)
        }
        self.channel = channel; self.handler = handler; self.loop = channel.eventLoop
        var details = ["Verbunden mit \(channel.remoteAddress?.ipAddress ?? "?") auf Port \(config.port)"]
        if config.tls != .implicit {
            let greeting = try await readReply(expecting: "Begrüßung")
            guard greeting.code == 220 else {
                throw failure("greeting_rejected", "Der Server hat die Verbindung nicht angenommen (Antwort \(greeting.code)).",
                              "Der Server ist erreichbar, will aber keine Mails von diesem Rechner entgegennehmen. Prüfe Zugriffsregeln und Sperrlisten beim Mailanbieter.",
                              details: details + [Self.serverLine(greeting)])
            }
            details.append("Begrüßung: \(greeting.code) \(Self.clean(greeting.text, limit: 100))")
        }
        return StepBody(details: details)
    }

    private func tlsStep() async throws -> StepBody {
        guard let channel, let loop else { throw failure("not_connected", "Keine Verbindung.", "Wiederhole die Prüfung.") }
        switch config.tls {
        case .off:
            return StepBody(details: ["Unverschlüsselt (SMTP_TLS=off, nur für lokale Tests zulässig)."], skipReason: "Unverschlüsselt (SMTP_TLS=off, nur für lokale Tests zulässig).")
        case .starttls:
            try await send("EHLO localhost")
            let hello = try await readReply(expecting: "EHLO")
            guard hello.code == 250 else {
                throw failure("ehlo_rejected", "Der Server hat EHLO abgelehnt (Antwort \(hello.code)).", "Prüfe, ob SMTP_HOST und SMTP_PORT auf einen SMTP-Server zeigen.", details: [Self.serverLine(hello)])
            }
            guard Self.parseCapabilities(hello).contains(where: { $0.hasPrefix("STARTTLS") }) else {
                throw failure("starttls_missing", "Der Server bietet STARTTLS nicht an.",
                              "Timetrack sendet nie unverschlüsselt. Wähle bei SMTP_PORT=465 SMTP_TLS=implicit, sonst einen Port mit STARTTLS (meist 587).")
            }
            try await send("STARTTLS")
            let ready = try await readReply(expecting: "STARTTLS")
            guard ready.code == 220 else {
                throw failure("starttls_rejected", "Der Server hat STARTTLS abgelehnt (Antwort \(ready.code)).",
                              "Der Server bietet STARTTLS an, lehnt es aber ab. Prüfe die TLS-Einstellungen des Mailservers.", details: [Self.serverLine(ready)])
            }
        case .implicit: break
        }
        let ssl: NIOSSLClientHandler
        do { ssl = try NIOSSLClientHandler(context: NIOSSLContext(configuration: tlsConfiguration), serverHostname: config.host) }
        catch let error as NIOSSLExtraError where error == .cannotUseIPAddressInSNI {
            throw failure("tls_needs_hostname", "Für die verschlüsselte Verbindung muss SMTP_HOST ein Servername sein, keine IP-Adresse.",
                          "Trage den Namen ein, für den das Zertifikat des Mailservers ausgestellt ist. Der Name muss von diesem Server aus auflösbar sein.")
        }
        try await channel.pipeline.addHandler(ssl, position: .first).get()
        guard let handler else { throw failure("not_connected", "Keine Verbindung.", "Wiederhole die Prüfung.") }
        do {
            let timeout = (try? budget(limits.step)) ?? .zero
            try await loop.flatSubmit { handler.waitHandshake(loop: loop, timeout: timeout) }.get()
        } catch {
            throw await tlsFailure(error)
        }
        var body = StepBody()
        let version = try? await channel.nioSSL_tlsVersion().get()
        body.details.append("Verschlüsselt mit \(Self.versionName(version)) (\(config.tls == .implicit ? "sofortige Verschlüsselung" : "STARTTLS"))")
        if let certificate = try? await channel.nioSSL_peerCertificate().get() {
            let info = Self.describe(certificate, host: config.host)
            body.certificate = info
            body.details.append("Zertifikat für \(Self.clean(info.subject ?? config.host)), ausgestellt von \(Self.clean(info.issuer ?? "unbekannt"))")
            body.details.append("Gültig bis \(Self.dateString(info.validUntil)) (noch \(info.daysLeft) Tage)")
            if info.daysLeft <= 14 { body.warnings.append("Das Zertifikat läuft in \(info.daysLeft) Tagen ab. Bitte rechtzeitig erneuern lassen.") }
        }
        return body
    }

    private func ehloStep() async throws -> StepBody {
        var details: [String] = []
        if config.tls == .implicit {
            let greeting = try await readReply(expecting: "Begrüßung")
            guard greeting.code == 220 else {
                throw failure("greeting_rejected", "Der Server hat die Verbindung nicht angenommen (Antwort \(greeting.code)).",
                              "Prüfe Zugriffsregeln und Sperrlisten beim Mailanbieter.", details: [Self.serverLine(greeting)])
            }
            details.append("Begrüßung: \(greeting.code) \(Self.clean(greeting.text, limit: 100))")
        }
        try await send("EHLO localhost")
        let hello = try await readReply(expecting: "EHLO")
        guard hello.code == 250 else {
            throw failure("ehlo_rejected", "Der Server hat EHLO abgelehnt (Antwort \(hello.code)).", "Prüfe, ob SMTP_HOST und SMTP_PORT auf einen SMTP-Server zeigen.", details: [Self.serverLine(hello)])
        }
        capabilities = Self.parseCapabilities(hello)
        let auth = capabilities.first { $0.hasPrefix("AUTH ") || $0.hasPrefix("AUTH=") }
        details.append(auth.map { "Anmeldeverfahren: " + $0.dropFirst(5).replacingOccurrences(of: " ", with: ", ") } ?? "Keine Anmeldung angeboten")
        if let size = capabilities.first(where: { $0.hasPrefix("SIZE ") }), let bytes = Int(size.dropFirst(5)), bytes > 0 {
            details.append("Maximale Nachrichtengröße: \(bytes / 1_048_576 > 0 ? "\(bytes / 1_048_576) MB" : "\(bytes / 1024) KB")")
        }
        details.append("Weitere Fähigkeiten: " + (capabilities.filter { !$0.hasPrefix("AUTH") && !$0.hasPrefix("SIZE") }.prefix(8).joined(separator: ", ").nilIfEmpty ?? "keine gemeldet"))
        return StepBody(details: details)
    }

    private func authStep() async throws -> StepBody {
        guard let user = config.user, let password = config.password else {
            return StepBody(skipReason: "Keine Anmeldung eingerichtet (SMTP_USER und SMTP_PASSWORD sind nicht gesetzt).")
        }
        let offered = capabilities.first { $0.hasPrefix("AUTH ") || $0.hasPrefix("AUTH=") }?.dropFirst(5).split(separator: " ").map(String.init) ?? []
        guard offered.contains("PLAIN") else {
            throw failure("auth_mechanism_unsupported", offered.isEmpty ? "Der Server bietet keine Anmeldung an." : "Der Server bietet nur diese Anmeldeverfahren an: \(offered.joined(separator: ", ")). Timetrack nutzt PLAIN.",
                          offered.isEmpty ? "Manche Server bieten die Anmeldung erst nach der Verschlüsselung an. Prüfe SMTP_TLS und den Port." : "Aktiviere PLAIN (über die gesicherte Verbindung) beim Mailanbieter.")
        }
        let credentials = Data(("\0" + user + "\0" + password).utf8).base64EncodedString()
        try await send("AUTH PLAIN " + credentials)
        var reply = try await readReply(expecting: "AUTH")
        if reply.code == 334 { try await send(credentials); reply = try await readReply(expecting: "AUTH") }
        guard reply.code == 235 else {
            // The server's text is left out: it may echo the account.
            if reply.code >= 400 && reply.code < 500 {
                throw failure("auth_temporary", "Die Anmeldung ist vorübergehend nicht möglich (Antwort \(reply.code)).", "Versuche es später erneut.")
            }
            throw failure("auth_rejected", "Die Anmeldung wurde abgelehnt (Antwort \(reply.code)). Benutzername oder Passwort stimmen nicht.",
                          "Prüfe SMTP_USER und SMTP_PASSWORD. Manche Anbieter verlangen ein eigenes App-Passwort oder lassen die Anmeldung nur mit der vollständigen E-Mail-Adresse zu.")
        }
        return StepBody(details: ["Angemeldet (Verfahren PLAIN). Das Passwort wird nie angezeigt."])
    }

    private func mailFromStep() async throws -> StepBody {
        try await send("MAIL FROM:<\(config.from)>")
        let reply = try await readReply(expecting: "MAIL FROM")
        guard reply.code == 250 else {
            // The server's free text is never passed on (Q1 finding 3): it may echo the account, the sender address or
            // internal policy details. Only the classified German reason and the numeric code remain.
            let verdict = Self.classifyMailFrom(reply, from: Self.clean(config.from))
            throw failure(verdict.code, verdict.message, verdict.advice, details: ["Antwort des Servers: \(reply.code)"])
        }
        // Reset instead of continuing: nothing is sent.
        try? await send("RSET"); _ = try? await readReply(expecting: "RSET")
        try? await send("QUIT")
        return StepBody(details: ["Absender „\(Self.clean(config.from))“ wird akzeptiert. Die Sitzung wurde ohne Nachricht beendet."])
    }

    // MARK: Plumbing

    private func closeConnection() async {
        if let channel { try? await channel.close().get() }
        channel = nil; handler = nil
    }

    private func budget(_ requested: TimeAmount) throws -> TimeAmount {
        let remaining = deadline - clock.now
        let nanos = remaining.components.seconds * 1_000_000_000 + remaining.components.attoseconds / 1_000_000_000
        guard nanos > 0 else { throw SMTPProbeError.timeout }
        return min(requested, .nanoseconds(Int64(nanos)))
    }

    private func send(_ command: String) async throws {
        guard let channel else { throw SMTPProbeError.closed }
        var bytes = channel.allocator.buffer(capacity: command.utf8.count + 2)
        bytes.writeString(command + "\r\n")
        try await channel.writeAndFlush(bytes).get()
    }

    /// Waits for one reply; a timeout, a closed connection or a protocol violation become a failed step.
    private func readReply(expecting what: String) async throws -> SMTPReply {
        guard let handler, let loop else { throw SMTPProbeError.closed }
        do {
            let timeout = try budget(limits.step)
            return try await loop.flatSubmit { handler.nextReply(loop: loop, timeout: timeout) }.get()
        } catch SMTPProbeError.timeout {
            let port = config.port
            let hint = config.tls == .starttls && what == "Begrüßung" && port == 465
                ? "Auf Port 465 erwartet der Server meist sofortige Verschlüsselung: setze SMTP_TLS=implicit."
                : "Prüfe Port und Verschlüsselungsmodus. Eine Firewall oder ein falscher Verschlüsselungsmodus lässt die Verbindung oft stumm hängen."
            throw failure("reply_timeout", "Der Server antwortet nicht (Zeitüberschreitung bei „\(what)“).", hint)
        } catch SMTPProbeError.closed {
            throw failure("connection_closed", "Der Server hat die Verbindung während „\(what)“ beendet.",
                          "Prüfe Port und Verschlüsselungsmodus; manche Server trennen Clients, die sie nicht zulassen.")
        } catch is SMTPProbeError {
            throw failure("protocol_error", "Der Server antwortet nicht wie ein SMTP-Server („\(what)“).", "Prüfe, ob SMTP_PORT wirklich zu einem Mailserver gehört.")
        } catch {
            throw failure("tls_failed", "Die verschlüsselte Verbindung wurde unterbrochen („\(what)“).", "Prüfe SMTP_TLS und den Port.")
        }
    }

    private func failure(_ code: String, _ message: String, _ advice: String, details: [String] = []) -> StepFailure {
        StepFailure(problem: MailCheckProblem(code: code, message: message, advice: advice), details: details)
    }

    private func connectFailure(_ error: any Error) -> StepFailure {
        var inner: any Error = error
        if let aggregate = error as? NIOConnectionError, let first = aggregate.connectionErrors.first { inner = first.error }
        if case ChannelError.connectTimeout = inner {
            return failure("connect_timeout", "Der Server antwortet nicht auf Port \(config.port) (Zeitüberschreitung).",
                           "Meist blockiert eine Firewall die ausgehende Verbindung oder der Port ist falsch. Port 25 sperren viele Anbieter; probiere 587 oder 465.")
        }
        if let io = inner as? IOError {
            switch io.errnoCode {
            case ECONNREFUSED:
                return failure("connection_refused", "Der Server nimmt auf Port \(config.port) keine Verbindungen an.", "Prüfe SMTP_PORT. Läuft der Mailserver, und lauscht er auf diesem Port?")
            case ENETUNREACH, EHOSTUNREACH:
                return failure("unreachable", "Der Server ist von hier aus nicht erreichbar.", "Prüfe die Netzwerkverbindung und die Firewall des Servers bzw. des Docker-Hosts.")
            default: break
            }
        }
        return failure("connect_failed", "Die Verbindung zu Port \(config.port) konnte nicht aufgebaut werden.", "Prüfe SMTP_HOST, SMTP_PORT und die Netzwerkverbindung.")
    }

    /// A failed verified handshake: a second, unverified connection reads the certificate so the cause can be named.
    private func tlsFailure(_ error: any Error) async -> StepFailure {
        if case SMTPProbeError.timeout = error {
            return failure("tls_timeout", "Die Verschlüsselung kam nicht zustande (Zeitüberschreitung).",
                           "Meist passt der Verschlüsselungsmodus nicht zum Port: 465 braucht SMTP_TLS=implicit, 587 braucht starttls.")
        }
        await closeConnection()
        var probe = tlsConfiguration
        probe.certificateVerification = .none
        let inspector = MailCheckRunner(configuration: config, group: group, tls: probe, limits: limits)
        guard let certificate = await inspector.inspectCertificate() else {
            return failure("tls_failed", "Die verschlüsselte Verbindung konnte nicht aufgebaut werden.",
                           config.tls == .implicit
                           ? "Antwortet der Server gar nicht verschlüsselt? Auf Port 587 und 25 gilt SMTP_TLS=starttls. Timetrack verlangt mindestens TLS 1.2."
                           : "Timetrack verlangt mindestens TLS 1.2. Prüfe die TLS-Einstellungen des Mailservers.")
        }
        let now = Date()
        let name = Self.clean(certificate.subject ?? "unbekannt")
        if certificate.validUntil < now {
            return StepFailure(problem: MailCheckProblem(code: "certificate_expired", message: "Das Zertifikat des Servers ist am \(Self.dateString(certificate.validUntil)) abgelaufen.",
                advice: "Das Zertifikat muss beim Mailanbieter bzw. auf dem Mailserver erneuert werden. Timetrack akzeptiert keine abgelaufenen Zertifikate."), certificate: certificate)
        }
        if certificate.validFrom > now {
            return StepFailure(problem: MailCheckProblem(code: "certificate_not_yet_valid", message: "Das Zertifikat des Servers gilt erst ab dem \(Self.dateString(certificate.validFrom)).",
                advice: "Prüfe die Uhrzeit des Timetrack-Servers und des Mailservers."), certificate: certificate)
        }
        if !certificate.hostnameMatches {
            return StepFailure(problem: MailCheckProblem(code: "certificate_hostname_mismatch", message: "Das Zertifikat gilt für „\(name)“, aber SMTP_HOST ist „\(Self.clean(config.host))“.",
                advice: "Trage in SMTP_HOST genau den Namen ein, für den das Zertifikat ausgestellt ist, nicht eine IP-Adresse oder einen Alias."), certificate: certificate)
        }
        return StepFailure(problem: MailCheckProblem(code: "certificate_untrusted", message: "Dem Zertifikat des Servers (ausgestellt von „\(Self.clean(certificate.issuer ?? "unbekannt"))“) wird nicht vertraut.",
            advice: "Die Zertifizierungsstelle ist unbekannt oder das Zertifikat ist selbst signiert. Nötig ist ein Zertifikat einer öffentlichen Zertifizierungsstelle (zum Beispiel Let's Encrypt)."), certificate: certificate)
    }

    /// Connects without certificate verification and reports the peer certificate (diagnostic only; no mail data is exchanged).
    private func inspectCertificate() async -> MailCheckCertificate? {
        let certificate = await readPeerCertificate()
        await closeConnection()
        return certificate
    }

    private func readPeerCertificate() async -> MailCheckCertificate? {
        guard (try? await tcpStep()) != nil else { return nil }
        if config.tls == .starttls {
            guard (try? await send("EHLO localhost")) != nil, (try? await readReply(expecting: "EHLO"))?.code == 250,
                  (try? await send("STARTTLS")) != nil, (try? await readReply(expecting: "STARTTLS"))?.code == 220 else { return nil }
        }
        guard let channel, let loop, let handler,
              let ssl = try? NIOSSLClientHandler(context: NIOSSLContext(configuration: tlsConfiguration), serverHostname: config.host),
              (try? await channel.pipeline.addHandler(ssl, position: .first).get()) != nil else { return nil }
        let timeout = (try? budget(limits.step)) ?? .zero
        guard (try? await loop.flatSubmit({ handler.waitHandshake(loop: loop, timeout: timeout) }).get()) != nil,
              let certificate = try? await channel.nioSSL_peerCertificate().get() else { return nil }
        return Self.describe(certificate, host: config.host)
    }

    // MARK: Helpers

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Printable ASCII only, so server- or certificate-controlled text cannot inject markup or control characters.
    static func clean(_ value: String, limit: Int = 80) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { (32...126).contains($0.value) }.prefix(limit)))
    }

    /// Classifies a refused `MAIL FROM` by numeric code and enhanced status code (RFC 3463). The server text is only
    /// inspected, never returned.
    static func classifyMailFrom(_ reply: SMTPReply, from: String) -> (code: String, message: String, advice: String) {
        let enhanced = reply.text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        if reply.code == 530 || reply.code == 535 || enhanced.hasPrefix("5.7.0") || enhanced.hasPrefix("5.7.8") {
            return ("auth_required", "Der Server verlangt vor dem Senden eine Anmeldung (Antwort \(reply.code)).",
                    "Setze SMTP_USER und SMTP_PASSWORD (bzw. SMTP_PASSWORD_FILE).")
        }
        if reply.code >= 400 && reply.code < 500 {
            let reason: String
            switch reply.code {
            case 421: reason = "Der Server ist gerade nicht verfügbar"
            case 450, 451: reason = "Der Server hat die Anfrage vorübergehend zurückgestellt (zum Beispiel Greylisting oder Ratenbegrenzung)"
            case 452: reason = "Der Server hat gerade nicht genug Speicher oder Kapazität"
            default: reason = "Der Server nimmt den Absender gerade nicht an"
            }
            return ("sender_temporary", "\(reason) (Antwort \(reply.code)).", "Versuche es später erneut.")
        }
        let reason: String
        switch reply.code {
        case 551: reason = "Der Server verlangt eine andere Absenderadresse als „\(from)“"
        case 552: reason = "Der Server lehnt die Anfrage wegen einer Größen- oder Mengenbegrenzung ab"
        case 554: reason = "Der Server hat die Absenderprüfung nicht bestanden (Richtlinie oder Sperrliste)"
        case 555: reason = "Der Server versteht die Parameter der Absenderadresse „\(from)“ nicht"
        default: reason = "Der Server lehnt die Absenderadresse „\(from)“ ab"
        }
        return ("sender_rejected", "\(reason) (Antwort \(reply.code)).",
                "Die Adresse in SMTP_FROM muss zum angemeldeten Konto gehören oder beim Anbieter als Absender freigegeben sein.")
    }

    /// Replaces configured credentials (user, password and the base64 AUTH PLAIN payload) in text that is returned to the
    /// client. Secrets shorter than four characters are skipped because replacing them would garble ordinary words.
    static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where secret.count >= 4 { result = result.replacingOccurrences(of: secret, with: "***") }
        return result
    }

    static func serverLine(_ reply: SMTPReply) -> String { "Antwort des Servers: \(reply.code) \(clean(reply.text, limit: 100))" }

    static func parseCapabilities(_ reply: SMTPReply) -> [String] {
        reply.lines.dropFirst().map { $0.uppercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func versionName(_ version: TLSVersion?) -> String {
        switch version {
        case .tlsv13?: "TLS 1.3"
        case .tlsv12?: "TLS 1.2"
        default: "TLS"
        }
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func describe(_ certificate: NIOSSLCertificate, host: String) -> MailCheckCertificate {
        let until = Date(timeIntervalSince1970: TimeInterval(certificate.notValidAfter))
        var names: [String] = []
        for alternative in certificate._subjectAlternativeNames() where alternative.nameType == .dnsName {
            names.append(alternative.contents.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) })
        }
        let subject = certificate.subjectName.first { $0.type == .commonName }?.value
        let issuer = certificate.issuerName.first { $0.type == .commonName }?.value ?? certificate.issuerName.first { $0.type == .organization }?.value
        let candidates = names.isEmpty ? [subject].compactMap { $0 } : names
        return MailCheckCertificate(subject: subject ?? names.first, issuer: issuer, validFrom: Date(timeIntervalSince1970: TimeInterval(certificate.notValidBefore)),
                                    validUntil: until, daysLeft: Int((until.timeIntervalSinceNow / 86400).rounded(.down)),
                                    hostnameMatches: candidates.contains { hostnameMatches(host, pattern: $0) })
    }

    /// RFC 6125 style: an exact match, or a leading `*.` standing for exactly one label.
    static func hostnameMatches(_ host: String, pattern: String) -> Bool {
        let host = host.lowercased(), pattern = pattern.lowercased()
        if pattern.hasPrefix("*.") {
            guard let dot = host.firstIndex(of: ".") else { return false }
            return host[host.index(after: dot)...] == pattern.dropFirst(2) && !host.hasPrefix(".")
        }
        return host == pattern
    }

    /// Blocking getaddrinfo off the cooperative pool; the caller stops waiting after `timeout` (the lookup itself cannot be cancelled).
    static func resolve(_ host: String, timeout: TimeAmount) async throws -> [String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], any Error>) in
            let once = ResumeOnce(continuation)
            DispatchQueue.global().async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                #if os(Linux)
                hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
                #else
                hints.ai_socktype = SOCK_STREAM
                #endif
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    once.resume(.failure(SMTPProbeError.notFound)); return
                }
                defer { freeaddrinfo(result) }
                var addresses: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let entry = cursor {
                    var buffer = [CChar](repeating: 0, count: 1025)
                    if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, Int32(NI_NUMERICHOST)) == 0 {
                        let text = String(cString: buffer)
                        if !addresses.contains(text) { addresses.append(text) }
                    }
                    cursor = entry.pointee.ai_next
                }
                once.resume(.success(addresses))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(max(0, timeout.nanoseconds)))) { once.resume(.failure(SMTPProbeError.timeout)) }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], any Error>?
    init(_ continuation: CheckedContinuation<[String], any Error>) { self.continuation = continuation }
    func resume(_ result: Result<[String], any Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
