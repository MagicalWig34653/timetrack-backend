# Codex Adversarial Review – Pakete C9–C18 (15.10.2026)

Prüfgegenstand: Branch-Diff gegen `2d57c11`, statische Prüfung (keine Tests ausgeführt), drei Blöcke. Alle Befunde werden im Paket C19 behoben (Regressionstests je Befund) und hier mit Status geführt.

| # | Schwere | Bereich | Befund | Status |
| --- | --- | --- | --- | --- |
| 1 | high | Planung | `abs(Int.min)` bei Urlaubskorrektur (`halfDays`) beendet den Prozess (`PlanningServices.swift:95-97`) | behoben (C19) |
| 2 | high | Import | XLSX `<row r="9223372036854775807">` → Überlauf bei `rowNumber + 1` (`ImportTable.swift:355-356`) | behoben (C19) |
| 3 | high | Planung | Grenzdatum 9999-12-31 + 365 Tage → `try!` in `LocalDate.local` (`PlanningServices.swift:15-17`), auch Export/Listenpfade | behoben (C19) |
| 4 | high | Speicher | Speicherwechsel: Löschen löst gegen neue Konfiguration auf, Original bleibt, Retry-Marker weg (`StorageService.swift:253-258`) | behoben (C19) |
| 5 | medium | Import | CSV-Trennererkennung fällt ab 41 Zeilen auf Komma zurück (`ImportTable.swift:87-95`) | behoben (C19) |
| 6 | high | Zeit | `abs(Int.min)` bei Kontokorrektur `seconds` (`TimeEvaluationServices.swift:127`) | behoben (C19) |
| 7 | medium | OAuth | Code-Replay widerruft Grant vor Client-/PKCE-Prüfung; abgelaufene Codes erreichen den Zweig (`OAuthService.swift:237-246`) | behoben (C19) |
| 8 | medium | OAuth | `/oauth/token` ohne Ratenbegrenzung, nutzt globalen `auth_lock` (`OAuthRoutes.swift:69-72`) | behoben (C19) |
| 9 | high | Push | SSRF: Push-Endpunkte (http-Loopback, beliebige Hosts/Ports, keine IP-Prüfung) (`PushDelivery.swift:87-93`) | behoben (C19) |
| 10 | high | Push | Lease läuft während Zustellung ab, Doppelzustellung (`NotificationRuntime.swift:65-68`) | behoben (C19) |
| 11 | medium | Push | Wartende Pushes ignorieren aktuelle Einstellungen/Ruhezeiten (`NotificationScheduler.swift:180-186`) | behoben (C19) |
| 12 | medium | Push | Outbox wächst unbegrenzt (`NotificationScheduler.swift:189-198`) | behoben (C19) |

Nicht geprüft in diesem Lauf: Dockerfile/Compose/Skripte wurden im dritten Block mitgenannt, aber ohne Befund zurückgemeldet; Frontend (PWA) separat nicht von Codex geprüft außer L1/L3b (früher). Klassenweite Gegenmaßnahme: alle `abs(...)`, `try!`, `+`/`-`/`*` auf nutzerkontrollierten Integern und `Date`-/`LocalDate`-Arithmetik im Backend systematisch prüfen (C19 Teil 2).

C19-Implementierung und Regressionen: [Übergabe C19](../handoffs/C19.md). Die Statusspalte bezeichnet den Code-Fix; vollständige Netz-/MariaDB-Verifikation ist wegen der Sandbox noch offen.
