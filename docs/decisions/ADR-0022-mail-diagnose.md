# ADR-0022: E-Mail-Diagnose für Administratoren

Status: Umsetzungsentscheidung von Paket MAIL1 (Nutzerwunsch 17.10.2026: auf einer Seite in den Servereinstellungen grafisch sehen, ob eine SMTP-Verbindung zustande kommt, und testweise eine Mail senden); Lead-Prüfung offen. Alles, was nicht aus dem Wunsch folgt, sind Annahmen des Pakets.

## Kontext

E-Mail (ADR-0003, ADR-0019) ist optional und wird nur über Umgebungsvariablen eingerichtet (`SMTP_*`, Passwort als Secret). Bei Fehlern sah der Betreiber nur „kein Code kommt an“; der Wählvorgang (`SMTPDialog`) meldet absichtlich keine Serverantworten.

## Entscheidungen

1. **Einstellungen bleiben reine Umgebung.** Passwörter gehören in Secrets, nicht in die Datenbank. Die Seite zeigt nur an und prüft; sie ändert nichts. Vertrag v0.18.0 (additiv).
2. **`GET /admin/mail`** (Admin): `configured`, `host`, `port`, `tls`, `fromAddress`, `fromName`, `authConfigured`, `source: environment`, `hints[]`. Benutzername und Passwort werden nie ausgegeben, auch nicht maskiert. Hinweise (`severity`, `code`, deutscher Text) nur als Rat, nie als Fehler: Port 465 mit `starttls`, 587 mit `implicit`, Port 25, unverschlüsselt, keine Anmeldung, Absenderdomain ≠ Serverdomain, Absenderdomain ≠ `PUBLIC_BASE_URL`. Ohne SMTP: Hinweis `not_configured` mit den nötigen Variablen. „Domain“ = letzte zwei Labels (keine Public-Suffix-Liste, nur ein Hinweis).
3. **`POST /admin/mail/check`** (Admin, normale Sitzung, keine frische Sitzung nötig, weil nichts gesendet wird): eigener Diagnose-Dialog (`MailCheckRunner`, neue Datei) mit den Schritten `dns`, `tcp`, `tls`, `ehlo`, `auth`, `mailFrom`. Jeder Schritt: `status` ok/failed/skipped, `durationMs`, `details[]`, `warnings[]`, bei TLS `certificate` (Name, Aussteller, gültig von/bis, Resttage, passt der Hostname), bei Fehlern `problem {code, message, advice}` in einfachem Deutsch. Nach dem ersten Fehler sind die übrigen Schritte `skipped`. `MAIL FROM:<SMTP_FROM>` wird gesendet, danach `RSET` und `QUIT`: **es entsteht nie eine Nachricht**. Zeitlimits: TCP 8 s, jede Antwort 8 s, insgesamt 20 s; der Kanal wird in jedem Fall geschlossen. Ein fehlgeschlagener Schritt ist ein normales Ergebnis (HTTP 200, `ok=false`); ohne SMTP 501 `not_implemented`.
   - **Zertifikatsfehler**: nach fehlgeschlagener verifizierter Verbindung öffnet die Prüfung eine zweite Verbindung ohne Überprüfung, liest nur das Zertifikat (kein Mail-Dialog) und klassifiziert: `certificate_expired`, `certificate_not_yet_valid`, `certificate_hostname_mismatch`, `certificate_untrusted`. Ist `SMTP_HOST` eine IP-Adresse, meldet `tls_needs_hostname` (NIOSSL erlaubt keine IP als Servername; der echte Versand scheitert dort ebenso).
   - **Serverantworten** werden nur für Antwortzeilen von Begrüßung, EHLO und MAIL FROM angezeigt (auf druckbares ASCII gekürzt, höchstens 100 Zeichen), **nie** bei der Anmeldung: sie kann das Konto zurückmelden. Das Passwort steht in keiner Antwort und keinem Log.
   - Begrenzung: 6 Prüfungen je 10 Minuten je Admin (`rate_limit_events`, Schlüssel `mailcheck:<id>`), danach 429 `too_many_requests`. Audit `mail.checked` ohne Detail.
4. **`POST /admin/mail/test`** (Admin, **frische Sitzung**, sonst 403 `reauth_required`): Body `{to?}`; ohne `to` geht die Mail an die bestätigte eigene Adresse (sonst 400 `no_recipient`). Betreff „Timetrack: Testnachricht“ und Text sind **fest** (wer ausgelöst hat, Zeit in UTC, `PUBLIC_BASE_URL`, „du musst nichts tun“), Absender nur `SMTP_FROM`: ohne Nutzertext und mit frischer Sitzung ist der Weg als Mail-Relay unbrauchbar. Grenzen: 3 je 10 Minuten je Admin und 3 je Stunde je Empfänger (Schlüssel mit Hash der Adresse). Audit `mail.test_sent` mit den ersten 16 Zeichen des Adress-Hashs, nie mit der Adresse. Antwort `{sent, to, durationMs}`.
   - **Fehlerklassen** (ohne Serverantworten): 502 `mail_auth_failed`, `mail_tls_failed`, `mail_sender_rejected`, `mail_connect_failed`, `mail_failed`; 422 `mail_recipient_rejected` (auch „Relay verweigert“); 504 `mail_timeout`; ohne SMTP 501. Dafür trägt `SMTPError` jetzt eine Klasse (`MailFailureKind`), die der Dialog aus seinem Zustand bestimmt. `sendCode` meldet weiterhin nur `deliveryFailed`; Wiederherstellung und Profil ändern sich nicht.
5. **Kontentrennung**: kein Konto-Bezug außer dem eigenen Konto des Admins (Rate-Limit, Audit, Standardempfänger). Mitglieder 403, Wiederherstellungssitzungen 403, ohne Sitzung 401. Kein Modulschalter: Teil der Servereinrichtung wie `/admin/storage`.
6. **PWA**: Seite `/admin/mail` („E-Mail“) in Verwaltung nach Module und in den Einstellungen; Statuskarte mit Hinweisen, Checkliste der Variablen bei fehlender Einrichtung, senkrechte Schrittanzeige, Testmail, Erklärung, wofür E-Mail genutzt wird. Ältere Server ohne die Endpunkte (404): Hinweis „Dieser Server unterstützt die Prüfung noch nicht“.

## Offen

- Ein Schritt „Bounce/Zustellung beim Empfänger“ ist nicht möglich; „gesendet“ heißt: vom Server angenommen.
- Kein Test von SPF/DKIM/DMARC (nur der Hinweis bei abweichender Absenderdomain).
- Mehrere Replikate: die Prüfung läuft auf dem Replikat, das die Anfrage bekommt; Netzwerkregeln können sich unterscheiden.

## Nachtrag S1b (19.10.2026): kein Serverantworttext nach der Anmeldung

Befund Q1: Die Prüfung gab bei einem abgelehnten `MAIL FROM` den rohen Antworttext des Servers zurück. Er kann das Konto, interne Hostnamen oder Richtlinien-Details enthalten.

- Der Schritt `mailFrom` nennt nur noch die **klassifizierte deutsche Ursache** und den **numerischen SMTP-Code** (`Antwort des Servers: 550`); der Text wird nur ausgewertet (Code und erweiterter Statuscode nach RFC 3463), nie zurückgegeben. Klassen: `auth_required` (530, 535, 5.7.0, 5.7.8), `sender_temporary` (4xx; 421, 450/451, 452 mit eigener Erklärung), `sender_rejected` (5xx; 551, 552, 554, 555 mit eigener Erklärung).
- **Schwärzung als zweite Schicht:** Vor der Rückgabe werden konfigurierter Benutzername, Passwort und die Base64-Nutzlast von `AUTH PLAIN` in allen Texten (Zusammenfassung, Details, Warnungen, Problem, Hinweis) durch `***` ersetzt. Werte unter vier Zeichen werden nicht ersetzt (würden normale Wörter zerstören); ein Benutzername, der der Absenderadresse entspricht, bleibt lesbar, weil `SMTP_FROM` bewusst angezeigt wird.
- Antworttexte vor der Anmeldung (Begrüßung, EHLO) bleiben als Diagnose sichtbar: sie enthalten keine Kontodaten und helfen bei falschem Host/Port.
