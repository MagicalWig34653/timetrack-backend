import Foundation

/// Instance-specific values shown in the header and footer of every outgoing mail.
/// `productName` comes from `WEBAUTHN_RP_NAME`, `operatorName` from `SMTP_FROM_NAME`, `baseURL` from `PUBLIC_BASE_URL`.
public struct MailBrand: Sendable, Equatable {
    public var productName: String
    public var operatorName: String?
    public var baseURL: URL?

    public init(productName: String = "Timetrack", operatorName: String? = nil, baseURL: URL? = nil) {
        self.productName = productName; self.operatorName = operatorName; self.baseURL = baseURL
    }

    /// Host name of the instance (without scheme/port) for the footer line.
    var instanceHost: String? { baseURL?.host }
}

/// A fully rendered message: the subject is sent unchanged, the text part is the plain fallback.
struct RenderedMail: Equatable, Sendable {
    let subject: String
    let text: String
    let html: String
}

/// Building blocks of the shared HTML layout. Every string is plain text and is escaped on rendering.
enum MailBlock: Sendable {
    case paragraph(String)
    /// One-time code, rendered large and monospaced.
    case code(String)
    /// Call to action. Only rendered for absolute http(s) URLs; the URL is also shown as plain text below the button.
    case button(label: String, url: String)
    /// Label/value rows (for example "Zeitpunkt").
    case facts([(label: String, value: String)])
}

struct MailDocument: Sendable {
    let title: String
    /// Hidden preview line shown by mail clients next to the subject.
    let preheader: String
    let blocks: [MailBlock]
    /// Short hint such as "Wenn du das nicht warst, ...".
    let securityNote: String?
}

enum MailTemplates {
    static func escape(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.utf8.count)
        for character in value.unicodeScalars {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&#39;"
            case "\0": continue
            default: output.unicodeScalars.append(character)
            }
        }
        return output
    }

    /// Accepts only absolute http(s) URLs without whitespace or control characters; everything else is dropped.
    static func safeURL(_ value: String) -> String? {
        guard value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }),
              let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return value
    }

    // MARK: Concrete messages

    /// One-time code for e-mail verification, e-mail change and recovery. `text` is the unchanged plain-text fallback.
    static func verificationCode(_ code: String, text: RecoveryMailText, brand: MailBrand) -> RenderedMail {
        let document = MailDocument(
            title: "Dein Bestätigungscode",
            preheader: "Dein Code für \(brand.productName) ist zehn Minuten gültig.",
            blocks: [
                .paragraph("Dein Bestätigungscode für \(brand.productName) lautet:"),
                .code(code),
                .paragraph("Der Code ist zehn Minuten gültig. Gib ihn nur in \(brand.productName) ein und nenne ihn niemandem."),
            ],
            securityNote: "Wenn du das nicht warst, kannst du diese E-Mail ignorieren. Es ändert sich nichts, solange der Code nicht eingegeben wird.")
        return RenderedMail(subject: text.subject, text: text.body.replacingOccurrences(of: "{code}", with: code),
                            html: html(document, brand: brand))
    }

    /// Diagnostic test message (ADR-0022). `account` is the display name of the person who triggered it.
    static func test(text: String, triggeredBy account: String, at date: Date, brand: MailBrand, subject: String) -> RenderedMail {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let local = DateFormatter()
        local.locale = Locale(identifier: "de_DE"); local.timeZone = TimeZone(secondsFromGMT: 0); local.dateFormat = "dd.MM.yyyy HH:mm 'Uhr (UTC)'"
        var facts: [(label: String, value: String)] = [
            ("Ausgelöst von", account.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(String.init).joined()),
            ("Zeitpunkt", "\(local.string(from: date)) (\(iso.string(from: date)))"),
        ]
        var blocks: [MailBlock] = [.paragraph("Dies ist eine Testnachricht von \(brand.productName).")]
        if let base = brand.baseURL?.absoluteString {
            facts.append(("Server", base))
        }
        blocks.append(.facts(facts))
        blocks.append(.paragraph("Wenn du diese Nachricht lesen kannst, funktioniert der E-Mail-Versand dieses Servers. Du musst nichts weiter tun."))
        if let base = brand.baseURL?.absoluteString { blocks.append(.button(label: "\(brand.productName) öffnen", url: base)) }
        let document = MailDocument(title: "Testnachricht", preheader: "Der E-Mail-Versand dieses Servers funktioniert.",
                                    blocks: blocks, securityNote: nil)
        return RenderedMail(subject: subject, text: text, html: html(document, brand: brand))
    }

    // MARK: Layout

    private enum Palette {
        static let page = "#eef1f5", card = "#ffffff", text = "#1a2230", muted = "#4a5565", border = "#d5dbe4"
        static let accent = "#1b4fd8", onAccent = "#ffffff", codeBackground = "#f1f4f9", codeText = "#0f1b33"
        static let darkPage = "#0e1116", darkCard = "#1a1f27", darkText = "#eef1f6", darkMuted = "#b3bccb", darkBorder = "#323a47"
        static let darkAccent = "#9db8ff", darkOnAccent = "#0b1430", darkCodeBackground = "#111620", darkCodeText = "#f4f7ff"
    }

    private static let sans = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif"
    private static let mono = "ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono','Courier New',monospace"

    static func html(_ document: MailDocument, brand: MailBrand) -> String {
        let product = escape(brand.productName)
        var body = ""
        for block in document.blocks { body += render(block) }
        if let note = document.securityNote {
            body += "<p class=\"muted\" style=\"margin:24px 0 0;padding:16px 0 0;border-top:1px solid \(Palette.border);font-size:14px;line-height:21px;color:\(Palette.muted);\">\(escape(note))</p>"
        }
        var footer = "Diese Nachricht wurde automatisch versendet"
        if let operatorName = brand.operatorName, !operatorName.isEmpty { footer += " von \(escape(operatorName))" }
        footer += " über \(product)."
        if let host = brand.instanceHost { footer += "<br>Instanz: \(escape(host))" }

        return """
        <!DOCTYPE html>
        <html lang="de" xmlns="http://www.w3.org/1999/xhtml" xmlns:o="urn:schemas-microsoft-com:office:office">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta name="supported-color-schemes" content="light dark">
        <title>\(escape(document.title))</title>
        <!--[if mso]><xml><o:OfficeDocumentSettings><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml><style>td,th,p,a,h1{font-family:Arial,sans-serif !important;}</style><![endif]-->
        <style>
        :root{color-scheme:light dark;supported-color-schemes:light dark;}
        body{margin:0;padding:0;width:100%;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;}
        table{border-collapse:collapse;}
        a{color:\(Palette.accent);}
        @media only screen and (max-width:620px){.container{width:100% !important;}.pad{padding-left:20px !important;padding-right:20px !important;}.code{font-size:24px !important;letter-spacing:2px !important;}}
        @media (prefers-color-scheme:dark){
        body,.bg-page{background-color:\(Palette.darkPage) !important;}
        .bg-card{background-color:\(Palette.darkCard) !important;border-color:\(Palette.darkBorder) !important;}
        .tx,h1,p{color:\(Palette.darkText) !important;}
        .muted{color:\(Palette.darkMuted) !important;border-color:\(Palette.darkBorder) !important;}
        .link,a.link{color:\(Palette.darkAccent) !important;}
        .code-box{background-color:\(Palette.darkCodeBackground) !important;border-color:\(Palette.darkBorder) !important;}
        .code{color:\(Palette.darkCodeText) !important;}
        .btn{background-color:\(Palette.darkAccent) !important;}
        .btn a{color:\(Palette.darkOnAccent) !important;}
        .line{border-color:\(Palette.darkBorder) !important;}
        }
        [data-ogsc] .bg-page,[data-ogsb] .bg-page{background-color:\(Palette.darkPage) !important;}
        [data-ogsc] .bg-card{background-color:\(Palette.darkCard) !important;}
        [data-ogsc] .tx,[data-ogsc] h1,[data-ogsc] p{color:\(Palette.darkText) !important;}
        [data-ogsc] .muted{color:\(Palette.darkMuted) !important;}
        [data-ogsc] .link{color:\(Palette.darkAccent) !important;}
        [data-ogsc] .code-box{background-color:\(Palette.darkCodeBackground) !important;}
        [data-ogsc] .code{color:\(Palette.darkCodeText) !important;}
        [data-ogsc] .btn{background-color:\(Palette.darkAccent) !important;}
        [data-ogsc] .btn a{color:\(Palette.darkOnAccent) !important;}
        </style>
        </head>
        <body class="bg-page" style="margin:0;padding:0;background-color:\(Palette.page);">
        <div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;mso-hide:all;">\(escape(document.preheader))&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;</div>
        <table role="presentation" class="bg-page" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:\(Palette.page);">
        <tr><td align="center" style="padding:24px 12px;">
        <table role="presentation" class="container" width="560" cellpadding="0" cellspacing="0" border="0" style="width:560px;max-width:560px;">
        <tr><td class="pad tx" style="padding:0 4px 16px;font-family:\(sans);font-size:20px;line-height:26px;font-weight:700;letter-spacing:0.2px;color:\(Palette.text);">\(product)</td></tr>
        <tr><td class="bg-card pad" bgcolor="\(Palette.card)" style="background-color:\(Palette.card);border:1px solid \(Palette.border);border-radius:12px;padding:32px 32px 28px;font-family:\(sans);color:\(Palette.text);">
        <h1 class="tx" style="margin:0 0 16px;font-family:\(sans);font-size:22px;line-height:28px;font-weight:700;color:\(Palette.text);">\(escape(document.title))</h1>
        \(body)
        </td></tr>
        <tr><td class="pad muted" style="padding:16px 4px 0;font-family:\(sans);font-size:12px;line-height:18px;color:\(Palette.muted);">\(footer)</td></tr>
        </table>
        </td></tr>
        </table>
        </body>
        </html>
        """
    }

    private static func render(_ block: MailBlock) -> String {
        switch block {
        case .paragraph(let value):
            return "<p class=\"tx\" style=\"margin:0 0 16px;font-family:\(sans);font-size:16px;line-height:24px;color:\(Palette.text);\">\(escape(value))</p>"
        case .code(let value):
            return """
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 16px;"><tr><td class="code-box" align="center" bgcolor="\(Palette.codeBackground)" style="background-color:\(Palette.codeBackground);border:1px solid \(Palette.border);border-radius:8px;padding:18px 12px;"><span class="code" style="display:inline-block;font-family:\(mono);font-size:30px;line-height:36px;font-weight:700;letter-spacing:4px;color:\(Palette.codeText);word-break:break-all;-webkit-user-select:all;user-select:all;">\(escape(value))</span></td></tr></table>
            """
        case .button(let label, let url):
            guard let safe = safeURL(url) else { return "" }
            let href = escape(safe)
            return """
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:8px 0 8px;"><tr><td class="btn" align="center" bgcolor="\(Palette.accent)" style="background-color:\(Palette.accent);border-radius:8px;"><a href="\(href)" style="display:inline-block;padding:13px 26px;font-family:\(sans);font-size:16px;line-height:20px;font-weight:700;color:\(Palette.onAccent);text-decoration:none;">\(escape(label))</a></td></tr></table>
            <p class="muted" style="margin:0 0 16px;font-family:\(sans);font-size:13px;line-height:20px;color:\(Palette.muted);word-break:break-all;">Falls der Button nicht funktioniert, öffne diesen Link: <a class="link" href="\(href)" style="color:\(Palette.accent);">\(href)</a></p>
            """
        case .facts(let rows):
            let items = rows.map { row in
                "<tr><td class=\"muted\" valign=\"top\" style=\"padding:4px 12px 4px 0;font-family:\(sans);font-size:14px;line-height:20px;color:\(Palette.muted);white-space:nowrap;\">\(escape(row.label))</td><td class=\"tx\" valign=\"top\" style=\"padding:4px 0;font-family:\(sans);font-size:14px;line-height:20px;color:\(Palette.text);word-break:break-all;\">\(escape(row.value))</td></tr>"
            }.joined()
            return "<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"margin:0 0 16px;\">\(items)</table>"
        }
    }
}
