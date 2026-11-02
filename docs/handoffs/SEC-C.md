# Übergabe SEC-C: Kontingente und Last (SEC-06, SEC-07, SEC-11, SEC-12)

Branch `sec-c`, Vertrag **0.41.0**, Migration `sec06.add_storage_quota` (wiederholbar: Spalten nur anlegen, wenn sie fehlen; SQLite und MariaDB).

## Was geändert wurde

- **SEC-06:** `storage_settings.quota_bytes`/`quota_files` (nullable, `nil` = Standard 200 MiB / 500 Dateien, `0` = unbegrenzt). Admin-API `GET/PUT /admin/storage` führt `quotaBytes`/`quotaFiles`. Geprüft in `StorageService.enforceQuota` innerhalb der serialisierten Upload-Transaktion (Summe über `pending` und `stored`), Fehler 413 `storage_quota_exceeded` mit deutscher Meldung. Zusätzlich 30 Uploads je Konto in 5 Minuten (429 `too_many_requests`, `RateLimitEvent`-Schlüssel `upload:<Konto>`). Das Einzeldateilimit bleibt unverändert; der Puffer je Anfrage ist weiter durch dieses Limit begrenzt.
- **SEC-07:** `GET /me/export` ruft `context.fresh()` (403 `reauth_required`, Sitzung höchstens 10 Minuten alt) und zählt Aufrufe über `account_audit` (`account.exported`, 3 je Stunde, 429 `export_rate_limited`). Der Audit-Eintrag wird vor dem Bau des Archivs geschrieben. Die bestehende Größengrenze (256 MiB Anhangsbudget im Archiv) bleibt; Streaming wurde nicht umgesetzt.
- **SEC-11:** (a) Token-Limiter: Zähler je (Client, IP) bleibt bei 120 je 5 Minuten, der clientweite Zähler ist nur noch eine Obergrenze von 1200. (c) `AuthService.limited` (IP-/Handle-Zähler für anonyme Pfade) läuft auf MariaDB in einer gewöhnlichen Transaktion ohne `auth_lock` (SQLite behält die Sperre, einziger Schreiber); das Aufräumen alter Zeilen ist eine eigene Best-Effort-Anweisung. Nicht geändert: Handle-Zähler der Wiederherstellung (b) sperren weiter das Konto für die Wiederherstellung (bewusst, sonst entfällt der Schutz vor Raten); die Gruppen-/Trigger-/Feed-Zähler laufen unverändert (Gruppen-Lesepfade ohnehin ohne Sperre).
- **SEC-12:** Neuer Wartungsschritt `oauth_clients` (Clients ohne Anfrage und Grant, 30 Tage nach Registrierung bzw. letzter Nutzung). `GET /oauth/requests/{id}` liefert zusätzlich `clientRegisteredAt` und `clientVerified` (immer false). Nicht umgesetzt: Scope-Vorbelegung nur lesend (Verhalten der Clients/Tests bleibt unverändert; Entscheidung des Nutzers nötig) und Anzeigeänderung der Zustimmungsseite (PWA).

## Auswirkungen auf Clients (nicht angepasst)

- **PWA/Apple, Kontoexport:** 403 `reauth_required` muss in eine Anmeldeaufforderung (Passkey, dann Export wiederholen) münden; 429 `export_rate_limited` anzeigen.
- **Upload:** 413 `storage_quota_exceeded` (Meldung kommt vom Server) und 429 anzeigen. Admin-Seite Speicher: Felder `quotaBytes`/`quotaFiles`.
- **Zustimmungsseite:** `clientVerified=false` als „nicht verifizierter Client“ kennzeichnen, Redirect-Host hervorheben, Registrierungsdatum zeigen.

## Tests

`Tests/TimetrackKitTests/SecCTests.swift` (Kontingent, Upload-Rate, Migration wiederholbar, Export-Re-Auth und -Limit), erweitert: Token-Limiter-Test, Wartungsfall `oauth_clients`, OAuth-Zustimmungsdaten.
