# M1 (Mail): HTML-Mails

(Dateiname mit Suffix, weil `M1.md` das Paket Arbeitsmodelle belegt.)

## Ergebnis

- Bestandsaufnahme: Das Backend versendet genau zwei Mails, beide waren Klartext: Bestätigungscode (`sendCode`, genutzt von E-Mail-Recovery, Verifizierung und E-Mail-Änderung) und die Testnachricht der Mail-Diagnose. Einladungen, Magic-Links, Passwort-Reset, Berichts-/Export- und Admin-Mails gibt es nicht als Mail.
- `Mail/MailTemplates.swift`: Vorlagensystem (`MailBrand`, `MailDocument`, `MailBlock`, `RenderedMail`), Tabellenlayout mit Inline-CSS, Hell/Dunkel, Outlook-Rückfälle, Code-Block, Button mit Klartext-Link, Sicherheitshinweis, Fußzeile mit Betreiber/Instanz. Keine externen Ressourcen.
- `SMTPMailSender.message(... html:)` erzeugt `multipart/alternative` (Text zuerst, HTML zuletzt, je quoted-printable); ohne `html` unverändert einteilig. Betreff und Klartext unverändert.
- Marke aus Konfiguration (`WEBAUTHN_RP_NAME`, `SMTP_FROM_NAME`, `PUBLIC_BASE_URL`), keine neuen Variablen, kein Vertrag/API-Änderung.
- Vorschau: `scripts/mail-preview.sh` (Test `testWritePreviews`, nur mit `MAIL_PREVIEW_DIR`), optional Playwright-Screenshots.
- Doku: ARCHITEKTUR 7b, EINRICHTUNG Konfigurationstabelle.

## Geprüft

- `MailTemplateTests` (10): Betreff/Text unverändert, HTML-Struktur, XSS-Payloads in Produktname/Betreiber/Name/Code, unsichere Button-URLs, Multipart-Aufbau, Round-Trip des quoted-printable-HTML-Teils inkl. Dot-Stuffing; bestehende `SMTPTests` grün.
- Screenshots (Chromium via Playwright) hell/dunkel/360 px selbst angesehen; Payload erscheint als sichtbarer Text, nicht als Markup.

## Nicht geprüft

- Echte Mail-Clients (Outlook, Gmail, Apple Mail); Outlook- und Gmail-Dunkelmodus nur nach Regeln gebaut. Versand an Mailpit nicht ausgeführt.
- Vorbestehend (auch ohne diese Änderung): `testStorageRESTSQLite`, `testS3ClientAgainstFakeServer` (Vapor "Unknown command -XCTest") und `testNotificationsSQLite` (Abbruch "ServeCommand did not shutdown") schlagen in dieser Umgebung fehl; übrige 375 Tests grün (42 übersprungen, MariaDB/S3 nicht gesetzt).
- Hinweis zur Umgebung: `swift test` brach mehrfach mit „resource fork … not allowed“ beim CodeSign ab; `xattr -cr .build/out/Products/Debug/TimetrackKitTests.xctest` und erneut starten hilft.
