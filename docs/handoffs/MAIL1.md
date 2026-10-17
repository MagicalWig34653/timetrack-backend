# Handoff MAIL1: E-Mail-Diagnose (Backend)

Stand: 17.10.2026. Branch `mail1-smtp-check` in beiden Repos (Worktrees `timetrack-backend-wt/mail1`, `timetrack-pwa-wt/mail1`), nicht gemergt, Lead-Prüfung offen. Entscheidungen: `docs/decisions/ADR-0022-mail-diagnose.md`. Vertrag **v0.18.0** (additiv, nach K1 v0.17.0).

## Neu
- `GET /admin/mail`, `POST /admin/mail/check`, `POST /admin/mail/test` (nur Admin; Test braucht frische Sitzung). Neue Dateien `Sources/TimetrackKit/Mail/` (`MailCheckModels`, `MailDiagnostics` mit `MailCheckRunner`, `MailRoutes`); additiv geändert: `Routes.swift` (eine Zeile), `ModuleRegistry.swift` (deutsche Fehlertexte `mail_*`), `SMTPMailSender.swift` (`SMTPError.failed(MailFailureKind)`, `sendTest`, gemeinsame `deliver`; `sendCode` unverändert nach außen).
- Tests `Tests/TimetrackKitTests/MailDiagnosisTests.swift`: NIO-Fake-SMTP-Server (Klartext, STARTTLS, implizites TLS mit openssl-Testzertifikat), Schritte ok / Anmeldung fehlgeschlagen / MAIL FROM abgelehnt / STARTTLS fehlt / Zertifikat nicht vertraut / Hostname passt nicht / IP als Host / Verbindung abgelehnt / Zeitüberschreitung / unbekannter Host, Passwort und Benutzername in keiner Antwort, Hinweise, Leitplanken (Mitglied 403, Wiederherstellungssitzung 403, ohne Sitzung 401, 501), Ratenbegrenzung (Prüfung 6/10 min, Test 3/10 min, 3/h je Empfänger), Audit ohne Adresse, Fehlerabbildung, Vertragsformen, MariaDB-Variante. Handprüfung gegen Mailpit: `MAILPIT_SMTP_PORT=11025 swift test --filter testMailCheckAgainstMailpit` (übersprungen ohne Variable).
- Nicht testbar ohne Zeitmaschine: abgelaufenes Zertifikat (Klassifikation per `daysLeft`/Datum im Code, nicht im Test erzeugt).

## Prüfung (selbst ausgeführt)
- `swift build --build-system native` ok. SQLite: 323 Tests, 39 übersprungen (MariaDB-Varianten, Mailpit), 0 Fehler. Mit MariaDB (eigene Datenbank `timetrack_test_mail1`, danach gelöscht): 323 Tests, 2 übersprungen (Benchmark, Mailpit), 0 Fehler.
- `docker build --target build` (Linux) erfolgreich, Image entfernt (vor der letzten Textänderung der Begrüßungszeile gebaut).
- `scripts/contract-json.sh` neu erzeugt (0.18.0, 129 Pfade).
- Manuell gegen den Dev-Mailpit (`localhost:11025`, TLS aus): dns ok (`::1`, `127.0.0.1`), tcp ok (30 ms, Begrüßung 220 Mailpit), tls übersprungen, ehlo ok (keine Anmeldung angeboten), auth übersprungen, mailFrom ok; Gesamt 33 ms.

## Betriebshinweise
- Die Prüfung läuft auf dem Replikat, das die Anfrage bekommt. Port 25 ausgehend ist bei vielen Anbietern gesperrt (Zeitüberschreitung bei „Verbindung aufbauen“).
- Offen: SPF/DKIM/DMARC werden nicht geprüft; „gesendet“ heißt „vom Server angenommen“.
