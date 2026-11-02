# Handoff SEC-A (Sicherheitsbefunde SEC-02, SEC-03, SEC-04, SEC-08, SEC-15)

Quelle: `docs/reviews/2026-11-01-security-review.md`. Vertrag 0.40.0. Code: `Sources/TimetrackKit/AuthHardening.swift` (Sperre, Kontingent, Outbox, Hinweis-Mails, Passwortregeln, Widerruf), Anpassungen in `RecoveryService.swift`, `WebAuthnService.swift`, `SessionService.swift`, `Accounts/ProfileService.swift`, `SMTPMailSender.swift`. Tests: `AuthHardeningTests`.

## Entscheidungen
- SEC-02: Die Recovery-Sitzung selbst widerruft nichts; erst das Anlegen des neuen Passkeys (Beförderung) beendet alle anderen Sitzungen, OAuth-Grants/-Token/-Codes, persönliche und Geräte-Token. Grund: Wer nur einen Nachweis testet oder abbricht, soll sich nicht selbst aussperren. Auslöse-Links und Kalender-Abos bleiben (eigene Verwaltung, kein Sitzungsersatz); Hinweis in der Mail. Passkey-Widerruf beendet andere Sitzungen (Sitzungen sind nicht an ein Credential gebunden).
- SEC-03: Sperren sind nach gehashtem Handle (auch unbekannte) und Client-Adresse geschlüsselt, daher kein Orakel. Gesperrt wird vor der Prüfung des Nachweises und ohne Versuch zu verbrauchen. Tabelle `recovery_lockouts`.
- SEC-04/08: Tabelle `mail_quota_events`; Mails nach der Antwort über `MailOutbox`. Über dem Limit bleibt die Recovery-Antwort 202 unverändert, es wird nur nichts gesendet.
- SEC-15: `SESSION_IDLE_HOURS` (Standard 336) anhand `lastSeenAt`. `__Host-`-Präfix nicht umgesetzt (würde alle bestehenden Cookies ungültig machen und Clients berühren).
- Hinweis-Mails (neu, Deutsch): Nachweis akzeptiert, Fehlversuche mit Sperre, Konto wiederhergestellt, Passkey widerrufen. Nur an bestätigte Konto-E-Mail, eigenes kleines Kontingent.

## Verhalten für Clients (PWA / Apple)
- `PUT /me/recovery/fallback-password`: mindestens 16 Zeichen (vorher 12), neuer Fehlercode 400 `weak_password` (UI-Text und Hinweis auf lange Zufallsfolge nötig). Beide Clients haben die 12 vermutlich als Mindestlänge fest verdrahtet.
- `POST /auth/recovery/start|complete` und `PUT /me/profile/email`, `PUT /me/recovery/email`: neu 429 bei Sperre oder Kontingent; UI-Meldung „zu viele Versuche, später erneut“.
- Nach Passkey-Anlegen in der Recovery-Sitzung und nach Passkey-Widerruf werden andere Geräte abgemeldet (401 dort), auch MCP/OAuth-Zugänge nach Recovery.
- Leerlauf-Timeout: Sitzungen ohne Nutzung 14 Tage enden (401).

## Betrieb
Migrationen `seca.create_recovery_lockouts`, `seca.create_mail_quota_events`, `seca.add_recovery_attempt_lock_key` (wiederholbar). Noch nie auf MariaDB gelaufen. Neue Umgebungsvariable optional: `SESSION_IDLE_HOURS`. Bei Betrieb ohne `TRUSTED_PROXY_CIDRS` teilen alle Clients eine Adresssperre (20 Fehlversuche), siehe SEC-01.

## Offen
`__Host-`-Präfix, Mail-Zeitorakel nur durch Outbox gemindert (Zeitunterschied der DB-Arbeit minimal), PWA/Apple-Anpassungen oben, MariaDB-Lauf.
