# ADR-0017: Wartung – Aufräumjob, Review-Restpunkte, MariaDB-Isolation

Status: akzeptiert gemäß Arbeitspaket B2 (16.10.2026), Lead-Prüfung offen. Ergänzt ADR-0003, ADR-0006, ADR-0009, ADR-0010 und ADR-0011.
Vertrag v0.10.5 (additiv). Übergabe mit Messzahlen: [B2](../handoffs/B2.md).

## Aufräumjob

- Ein Lauf löscht abgelaufene bzw. veraltete Zeilen in fester Reihenfolge; jeder Schritt ist idempotent, auf höchstens 500 Zeilen je Runde
  und 20 Runden je Tabelle und Lauf begrenzt und löscht nur Zeilen, die **länger als ihre Karenzzeit** ungültig sind (strikt älter als
  `jetzt − Karenz`; eine Zeile genau auf der Grenze bleibt). Es werden nur Zähler protokolliert, nie Bezeichner oder Personendaten.
- Karenzzeiten: Sitzungen 1 Tag nach Ablauf bzw. 7 Tage nach Widerruf; WebAuthn-Challenges, Recovery-/E-Mail-Codes (`recovery_attempts`), OIDC-States
  und -Pending-Registrierungen 1 Stunde; OAuth-Requests und -Codes 1 Tag; OAuth-Tokens 7 Tage nach Ablauf (Wiederverwendungserkennung bleibt bis zum Ablauf);
  persönliche Tokens und Geräte-Tokens (nur mit Ablaufdatum) 30 Tage; `rate_limit_events` 2 Stunden (längstes Fenster im Code: 3600 s, Push-Test);
  `mcp_audit` `MCP_AUDIT_RETENTION_DAYS` (90); Push-Abos mit mindestens 10 Fehlern und 30 Tage ohne Erfolg (bzw. ohne Erfolg seit Anlage) samt Outbox;
  offene Importe (`uploaded`/`mapped`) nach `IMPORT_JOB_TIMEOUT_HOURS` (168); Dateien: `deleting`/`failed` sofort (wie bisher `cleanup`), `pending` nach 6 Stunden;
  Blobs der DB-Ablage ohne Metadaten sofort (Upload und Löschen ändern Blob und Zeile atomar, ein Blob ohne Zeile ist nur nach manuellen Eingriffen/Teil-Restore möglich);
  lokale Objekte ohne Metadaten (nur kanonische Pfade `ab/cd/<uuid>`, keine Symlinks, nur unter dem aktuell konfigurierten Wurzelpfad) und liegengebliebene `.tmp-*`-Dateien
  nach `STORAGE_ORPHAN_GRACE_HOURS` (168). **Nie angefasst:** Dauer-Recovery-Codes, Einladungen, OAuth-Clients/-Grants, Geräte-Tokens ohne Ablauf, Konten, fachliche Daten.
- Offene Importe werden **gelöscht** (wie ein Verwerfen durch den Nutzer: Datei, Zuordnung, Job), nicht als `failed` markiert: Die CHECK-Bedingung
  von `import_jobs.status` kennt `failed` nicht, und ein Umbau würde auf SQLite einen Tabellenneubau einer von mehreren Tabellen referenzierten Tabelle bedeuten.
  Abgeschlossene (`committed`/`rolled_back`) Importe samt Batches bleiben unberührt. Eine spätere Migration kann `failed` nachrüsten.
- S3-Buckets werden nicht aufgelistet: Die Metadatenzeile entsteht immer vor dem Objekt, fehlgeschlagene Uploads räumt `cleanup` ab; verwaiste S3-Objekte ohne Zeile
  entstehen nur durch manuelle Eingriffe.
- Mehrere Replikate: Der Lauf hält die Lease `maintenance` in `job_leases` (Dauer 600 s, nach jedem Schritt erneuert, Verlust bricht den Lauf ab). Gleichzeitig gestartete
  Läufer (auch der CLI-Befehl) führen genau einmal aus, die anderen überspringen. Periodische Läufe halten die Lease nach Ende noch eine halbe Periode, damit Replikate nicht
  nacheinander dieselbe Arbeit wiederholen; der CLI-Lauf gibt sie sofort frei. Der erste periodische Lauf startet nach 15 bis 75 s (Zufall).
- Konfiguration: `MAINTENANCE_INTERVAL_MINUTES` (60, `0` = aus; in Tests nur mit ausdrücklich gesetztem Wert), `MCP_AUDIT_RETENTION_DAYS`, `IMPORT_JOB_TIMEOUT_HOURS`, `STORAGE_ORPHAN_GRACE_HOURS`;
  ungültige Werte brechen den Start ab. CLI: `App maintenance` (Exit 0 auch bei „übersprungen“, ungleich 0 bei fehlgeschlagenem Schritt).

## Review-Restpunkte

- Lernfeld: Eine Unique-Verletzung (SQLite und MariaDB melden sie als Constraint-Fehler) wird zu 409 `learning_field_exists` abgebildet. Die eigentliche Ursache der 500 bei
  gleichzeitigen Anfragen auf MariaDB war ein anderer Fehler (siehe nächster Abschnitt).
- `pushsubscriptionchange`: `POST /api/v1/me/push-subscriptions/replace` (Vertrag v0.10.5) tauscht das Abo in einer Transaktion unter `auth_lock`; Id, Erstellzeit und wartende
  Outbox-Einträge bleiben, fremde Konten werden nie berührt, Validierung wie bei der Registrierung. Die PWA nutzt den Endpunkt noch nicht (eigener PWA-Auftrag).
- `PUSH_ALLOWED_HOSTS`: Die Standardliste bleibt wie in ADR-0011. Dokumentierter, getesteter Vorschlag (enger als der Standard): `fcm.googleapis.com,updates.push.services.mozilla.com,web.push.apple.com,*.notify.windows.com`.
  Leerer Wert der Variable (Compose reicht ungesetzte Variablen leer durch) gilt jetzt als nicht gesetzt statt alle Dienste zu sperren.

## MariaDB 12: READ COMMITTED unter `auth_lock`

MariaDB ab 11.6.2 setzt `innodb_snapshot_isolation=ON`. Unter REPEATABLE READ öffnet die erste Anweisung einer Transaktion (hier `UPDATE auth_lock`) die Sicht, noch bevor die
Transaktion auf die Sperre wartet. Hat der Vorgänger inzwischen dieselbe Sitzungszeile angefasst (jede Anfrage setzt `last_seen_at`), scheitert der Wartende mit
„Record has changed since last read“ (HTTP 500), und Lesezugriffe nach der Sperre sähen veraltete Daten. Gemessen vor der Änderung: bei 24 parallelen Anfragen derselben Sitzung
in 40 von 40 Runden mindestens eine 500. `AuthService.transaction` setzt deshalb auf MariaDB vor dem Start `SET TRANSACTION ISOLATION LEVEL READ COMMITTED`; mit der globalen
Serialisierung entspricht das dem beabsichtigten Verhalten (jede Anweisung nach der Sperre sieht den festgeschriebenen Stand). SQLite ist unverändert. Nachher: 0 von 40 Runden.

## Bewertung `auth_lock`

Messung und Zahlen im [Handoff B2](../handoffs/B2.md) (`AUTH_LOCK_BENCH=1`, nicht Teil des Standardlaufs). Kurzfassung dort; Codeänderung nur die Isolationsstufe oben.

## Alternativen und Folgen

Wiederholen der Transaktion bei Fehler 1020 (würde unter Last erneut scheitern, weil jeder Wiederholungsversuch wieder vor dem Warten die Sicht öffnet), Aufräumen als eigenes
Programm (zweiter Deployment-Pfad, aber dieselbe Logik; der CLI-Befehl deckt Cron ab), `failed`-Status für Importe (siehe oben). Keine neue Migration, keine neue Abhängigkeit.
