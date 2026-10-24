import XCTest
import Foundation
@testable import TimetrackKit

final class MailTemplateTests: XCTestCase {
    private let text = RecoveryMailText(subject: "Dein Timetrack-Bestätigungscode",
                                        body: "Dein Bestätigungscode für Timetrack lautet:\n\n{code}\n\nDer Code ist zehn Minuten gültig. Wenn du diese Anfrage nicht gestellt hast, kannst du diese E-Mail ignorieren.")
    private let brand = MailBrand(productName: "Timetrack", operatorName: "Beispiel GmbH", baseURL: URL(string: "https://timetrack.example.org"))
    private let payload = "<script>alert(1)</script>\"'&<img src=x onerror=alert(2)>"

    private func account(_ name: String) -> Account {
        Account(handle: "erika", displayName: name, role: .member, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func config() throws -> SMTPConfiguration {
        try XCTUnwrap(Configuration(environment: ["SMTP_HOST": "localhost", "SMTP_FROM": "sender@example.test"]).smtp)
    }

    func testCodeMailKeepsSubjectAndTextFallback() {
        let mail = MailTemplates.verificationCode("abc-123_XYZ", text: text, brand: brand)
        XCTAssertEqual(mail.subject, "Dein Timetrack-Bestätigungscode")
        XCTAssertEqual(mail.text, "Dein Bestätigungscode für Timetrack lautet:\n\nabc-123_XYZ\n\nDer Code ist zehn Minuten gültig. Wenn du diese Anfrage nicht gestellt hast, kannst du diese E-Mail ignorieren.")
    }

    func testCodeMailHTMLStructure() {
        let html = MailTemplates.verificationCode("abc-123_XYZ", text: text, brand: brand).html
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<html lang=\"de\""))
        XCTAssertTrue(html.contains("<meta name=\"color-scheme\" content=\"light dark\">"))
        XCTAssertTrue(html.contains("@media (prefers-color-scheme:dark)"))
        XCTAssertTrue(html.contains("<h1 "))
        XCTAssertTrue(html.contains(">abc-123_XYZ</span>"))
        XCTAssertTrue(html.contains("Wenn du das nicht warst"))
        XCTAssertTrue(html.contains("von Beispiel GmbH über Timetrack"))
        XCTAssertTrue(html.contains("Instanz: timetrack.example.org"))
        // No remote assets, scripts or tracking.
        for forbidden in ["<script", "<img", "<link", "src=", "url(", "@import"] { XCTAssertFalse(html.contains(forbidden), forbidden) }
        XCTAssertFalse(html.contains("<a "), "a code mail has no links")
    }

    func testBrandNameIsConfigurable() {
        let html = MailTemplates.verificationCode("c", text: text, brand: MailBrand(productName: "Zeiterfassung Muster")).html
        XCTAssertTrue(html.contains("Zeiterfassung Muster</td>"))
        XCTAssertFalse(html.contains("Instanz:"))
    }

    func testEscapingOfEveryInterpolatedValue() {
        let hostile = MailBrand(productName: payload, operatorName: payload, baseURL: URL(string: "https://timetrack.example.org"))
        let code = MailTemplates.verificationCode(payload, text: text, brand: hostile).html
        let test = MailTemplates.test(text: "t", triggeredBy: payload, at: Date(timeIntervalSince1970: 0), brand: hostile, subject: "s").html
        for html in [code, test] {
            XCTAssertFalse(html.contains("<script"))
            XCTAssertFalse(html.contains("<img"))
            XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;&quot;&#39;&amp;&lt;img"))
        }
        XCTAssertEqual(MailTemplates.escape("a\0b"), "ab")
    }

    func testButtonOnlyForSafeURLsAndEscapesAttribute() {
        for bad in ["javascript:alert(1)", "data:text/html,x", "https://", "https://a.example/ x", "//evil.example", "https://a.example/\u{0}"] {
            XCTAssertNil(MailTemplates.safeURL(bad), bad)
            let doc = MailDocument(title: "t", preheader: "p", blocks: [.button(label: "Los", url: bad)], securityNote: nil)
            XCTAssertFalse(MailTemplates.html(doc, brand: brand).contains("<a "), bad)
        }
        let doc = MailDocument(title: "t", preheader: "p", blocks: [.button(label: "<b>Los</b>", url: "https://a.example/x?a=1&b=\"2\"")], securityNote: nil)
        let html = MailTemplates.html(doc, brand: brand)
        XCTAssertTrue(html.contains("href=\"https://a.example/x?a=1&amp;b=&quot;2&quot;\""))
        XCTAssertTrue(html.contains("&lt;b&gt;Los&lt;/b&gt;"))
        // Plain-text link below the button: href twice plus visible text.
        XCTAssertEqual(html.components(separatedBy: "https://a.example/x?a=1&amp;b=&quot;2&quot;").count - 1, 3)
    }

    func testTestMailTextUnchangedAndLinksOnlyToBaseURL() {
        let date = Date(timeIntervalSince1970: 0)
        let mail = MailDiagnosis.mail(by: account("Erika"), at: date, brand: brand)
        XCTAssertEqual(mail.subject, "Timetrack: Testnachricht")
        XCTAssertEqual(mail.text, MailDiagnosis.body(by: account("Erika"), at: date, baseURL: URL(string: "https://timetrack.example.org")!))
        XCTAssertTrue(mail.text.hasPrefix("Dies ist eine Testnachricht von Timetrack.\n\nAusgelöst von: Erika\n"))
        XCTAssertEqual(mail.html.components(separatedBy: "href=\"").count - 1, 2)
        XCTAssertTrue(mail.html.contains("href=\"https://timetrack.example.org\""))
        XCTAssertTrue(mail.html.contains("Erika"))
    }

    func testMultipartAlternativeStructure() throws {
        let mail = MailTemplates.verificationCode("abc", text: text, brand: brand)
        let message = try SMTPMailSender.message(configuration: try config(), address: "a@example.test", subject: mail.subject, body: mail.text, html: mail.html)
        let lines = message.components(separatedBy: "\r\n")
        let typeLine = try XCTUnwrap(lines.first { $0.hasPrefix("Content-Type: multipart/alternative") })
        let boundary = try XCTUnwrap(typeLine.components(separatedBy: "\"").dropFirst().first)
        XCTAssertEqual(lines.filter { $0 == "--\(boundary)" }.count, 2)
        XCTAssertEqual(lines.filter { $0 == "--\(boundary)--" }.count, 1)
        let plain = try XCTUnwrap(lines.firstIndex { $0 == "Content-Type: text/plain; charset=UTF-8" })
        let htmlPart = try XCTUnwrap(lines.firstIndex { $0 == "Content-Type: text/html; charset=UTF-8" })
        XCTAssertLessThan(plain, htmlPart, "text first, HTML last")
        XCTAssertEqual(lines.filter { $0 == "Content-Transfer-Encoding: quoted-printable" }.count, 2, "encoding is declared per part")
        XCTAssertTrue(lines.allSatisfy { $0.utf8.count < 998 })
        XCTAssertTrue(message.hasSuffix("\r\n.\r\n"))
        XCTAssertTrue(message.contains("Subject: =?UTF-8?B?"))
        XCTAssertTrue(message.contains("zehn=20Minuten=20g=C3=BCltig"))
    }

    func testPlainMessageStaysSinglePart() throws {
        let message = try SMTPMailSender.message(configuration: try config(), address: "a@example.test", subject: "S", body: "Body")
        XCTAssertTrue(message.contains("Content-Type: text/plain; charset=UTF-8"))
        XCTAssertFalse(message.contains("multipart"))
    }

    func testHTMLPartSurvivesQuotedPrintableRoundTrip() throws {
        let mail = MailTemplates.verificationCode("abc", text: text, brand: brand)
        let message = try SMTPMailSender.message(configuration: try config(), address: "a@example.test", subject: mail.subject, body: mail.text, html: mail.html)
        let start = try XCTUnwrap(message.range(of: "Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"))
        let rest = message[start.upperBound...]
        // Undo SMTP dot-stuffing (the server removes the extra leading dot) before decoding.
        let encoded = String(rest[..<(try XCTUnwrap(rest.range(of: "\r\n--=_timetrack_"))).lowerBound])
            .components(separatedBy: "\r\n").map { $0.hasPrefix("..") ? String($0.dropFirst()) : $0 }.joined(separator: "\r\n")
        var out = Data(); var bytes = Array(encoded.utf8)[...]
        while let byte = bytes.popFirst() {
            if byte == 61 {
                let next = Array(bytes.prefix(2)); bytes.removeFirst(2)
                if next == [13, 10] { continue }
                out.append(try XCTUnwrap(UInt8(String(decoding: next, as: UTF8.self), radix: 16)))
            } else { out.append(byte) }
        }
        let decoded = String(decoding: out, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        let index = zip(decoded, mail.html).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
        XCTAssertEqual(decoded, mail.html, "first difference at \(index): \(decoded.dropFirst(max(index - 20, 0)).prefix(60)) | \(mail.html.dropFirst(max(index - 20, 0)).prefix(60))")
    }

    /// Dev-only: renders all templates when `MAIL_PREVIEW_DIR` is set (see `scripts/mail-preview.sh`); skipped otherwise.
    func testWritePreviews() throws {
        guard let directory = ProcessInfo.processInfo.environment["MAIL_PREVIEW_DIR"], !directory.isEmpty else {
            throw XCTSkip("MAIL_PREVIEW_DIR not set")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let hostile = MailBrand(productName: "Timetrack", operatorName: payload, baseURL: URL(string: "https://timetrack.example.org"))
        let samples: [(String, RenderedMail)] = [
            ("code", MailTemplates.verificationCode("k3Jx9-Qm2_vTb7Rw", text: text, brand: brand)),
            ("test", MailDiagnosis.mail(by: account("Erika Beispiel"), at: Date(), brand: brand)),
            ("test-hostile", MailTemplates.test(text: "t", triggeredBy: payload, at: Date(), brand: hostile, subject: "s")),
        ]
        for (name, mail) in samples {
            try mail.html.write(toFile: directory + "/\(name).html", atomically: true, encoding: .utf8)
            try mail.text.write(toFile: directory + "/\(name).txt", atomically: true, encoding: .utf8)
        }
    }
}
