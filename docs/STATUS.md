# Aktueller Projektstand

**C3-backend (Abwesenheitssemantik, Zeitkonto ohne heutigen Tag, ICS, Konto-E-Mail = Recovery, 29.10.2026, Branch `c3-absence-semantics`, Lead-Prüfung offen):** Vertrag 0.36.0, ADR-0032. Krank/Freistellung ohne Antragsablauf (neuer Status `recorded`, alte Werte werden normalisiert), Saldo zählt nur bis gestern (`todayDeltaSeconds`/`includesToday`), ICS zeigt Tagesmarkierungen und Berufsschultage, Recovery-Codes gehen an die Konto-E-Mail. MariaDB nicht geprüft; PWA und Apple-Apps nicht angepasst (`docs/handoffs/C3-backend.md`).
**P13 (Planblöcke, 24.10.2026, Branch `worktree-agent-a34fccae7f0e10f5a`, Lead-Prüfung offen):** API 0.34.0, Blockliste je Plantag, Migration `p13.add_plan_blocks`, Wochen- und Plan/Ist-Ansichten, Planfreigabe mit geschwärzten Blockdetails, Kontoexport und MCP erweitert. PWA und Apple-Clients sind nicht angepasst; Übergabe `docs/handoffs/P13.md`, Entscheidung ADR-0031. Integriert mit main (Vertrag 0.34.0); Suite 436 Tests, 42 übersprungen (MariaDB/optional), 0 Fehler. ICS-Abo nennt Blöcke gemischter Tage in der Beschreibung. Änderungen uncommitted, keine laufenden Dienste.
**P14d (APNs-Schlüssel als Swarm-Secret, 27.10.2026, Branch `p14d-apns-secret`, Lead-Prüfung offen):** optionaler APNs-Block in `deploy/swarm/stack.yaml`, Secret `tt_apns_private_key` über `create-secrets.sh --apns-private-key-file` (Validierung ohne Ausgabe, kein Überschreiben, `--dry-run`), Doku in DEPLOYMENT.md. Nur mit Wegwerf-Testschlüssel geprüft, kein echter Swarm. Übergabe: docs/handoffs/P14d.md.
**P14b (Auslöser stiller Sync-Push, 27.10.2026, Branch `p14b-apns-deploy`, Lead-Prüfung offen):** `ApnsSyncMiddleware` + `ApnsSyncCoordinator` senden nach schreibenden Anfragen einen entprellten (3 s), je Konto auf 30 s begrenzten stillen Push an die APNs-Geräte; Ausschluss des auslösenden Geräts über optionalen Header `X-Timetrack-Device`; Vertrag 0.34.0. Echter APNs-Test und `deploy/`-Secret-Verdrahtung offen. Übergabe: docs/handoffs/P14b.md.
**P14 (APNs-Push, 26.10.2026, Branch `p14-apns`, Lead-Prüfung offen):** Geräte-Registrierung `/me/push-devices` (Sitzung+CSRF, nicht über Bearer/MCP), HTTP/2-APNs-Client mit `.p8`-Token-Authentifizierung hinter `ApnsTransport`, Zustellung der bestehenden Benachrichtigungsarten über `apns_outbox` mit Kategorie-/Ruhezeit-Regeln, Token-Löschung bei 410/BadDeviceToken/Unregistered, stiller Sync-Push als Baustein (Vertrag 0.33.0, ADR-0030, Migration `p14.create_apns_devices`). Vollständiger `swift test` auf SQLite: 434 Tests, 42 übersprungen, 0 Fehler (12 neue); **keine echte APNs-Verbindung geprüft**, MariaDB nicht geprüft. Handoff `docs/handoffs/P14.md`.
**N4 (Betriebstage 24.12./31.12., 26.10.2026, Branch `n4-company-days`, Lead-Prüfung offen):** `companyDays` (none|half|full, Standard none) in den Urlaubseinstellungen; `full` wie Feiertag, `half` halbes Soll und höchstens halber Urlaubstag; Felder `holidayName`/`companyDayTreatment`, `companyTreatment`, ICS, Export (Vertrag 0.32.0, ADR-0029, Migration `n4.add_company_days`). Handoff `docs/handoffs/N4-backend.md`.
**N2 (Kalenderabo und Feiertage, 26.10.2026, Branch `n2-holidays-ics`, Lead-Prüfung offen):** ICS-Abo `GET /ics/{token}.ics` mit Verwaltung `/me/calendar-feeds` (Token als Hash, 404 ohne Orakel, Ratenbegrenzung, ETag/304) und `TimeWeekDay.holidayName` (Vertrag 0.31.0, Migration `n2.create_calendar_feeds`); Feiertagstabellen waren vollständig, nur die Anzeige am Wochenende/außerhalb von Arbeitsmodellen fehlte (Details `docs/handoffs/N2-backend.md`). Vollständiger `swift test` auf SQLite: 410 Tests, 42 übersprungen, 0 Fehler; MariaDB nicht geprüft. PWA-/Apple-Oberflächen (Abo-Verwaltung, Feiertagsname) offen.
**R2 (Jugendrechtsprofil, 24.10.2026, Worktree `worktree-agent-a540a8eec2a90d179`):** Backend-Implementierung für `jarbschg-minor-de`, Modellhistorie, Berufsschulstunden, Hinweise und Vertrag v0.29.0 im Worktree. Migration `r2.add_legal_work_profile`; bestehende Modelle bleiben bei `arbzg-adult-de`. Swift-Build erfolgreich. Gezielte R2-/Vertragstests: 8 bestanden; breiter Zeit-/Vertragslauf: 34 Tests, 33 bestanden, 1 optionaler Test übersprungen. Vollständiger Testlauf nicht grün: bestehende HTTP-/SMTP-Tests können in der Sandbox keine lokalen Sockets binden (`Operation not permitted`); der Lauf wurde nach mehreren solchen Fehlern beendet. Commit deshalb offen. PWA-/Apple-Anzeige und fachliche Rechtsprüfung offen (Handoff R2).
## Paket X3 (Backend-Lücken für Clients, 24.10.2026, Lead-Prüfung offen)

Branch `worktree-agent-ad51edf6202fb6b47`: `needsReview` wird bei Ende-Korrektur und Entscheidung über Ende-Vorschläge gelöscht; explizite Quittierung per Segment-PATCH mit Revision. `GET/DELETE /time/account/adjustments` ergänzt die Zeitkonto-Verwaltung einschließlich Anfangsstand; Löschung mit datensparsamer Konto-Auditspur, Export und Kontolöschung geprüft. MCP liest Anpassungen mit `time:read`. Vertrag 0.29.0; genaue Client-Aufrufe in `docs/handoffs/X3-backend.md`.

**Prüfung in diesem Worktree:** `scripts/contract-json.sh` erfolgreich. Sieben gezielte Tests (Zeitkonto-Seiten/Löschung/Kontentrennung, Segment-Korrektur/Quittierung, Ende-Vorschläge, MCP-Leseparität, bestehender MCP-Katalog, Vertragsversion und Antwortformen) mit `swift test --build-system native --no-parallel` und lokalen SwiftPM-Caches: 7 bestanden, 0 Fehler. Ein vollständiger Lauf vor zwei Testkorrekturen: 389 Tests, 42 übersprungen, 51 Fehler (41 unerwartet). Die beobachteten X3- und MCP-Fehler wurden danach gezielt grün nachgeprüft. Viele weitere Fehler stammen von der Sandbox: lokale Socket-Bindung liefert `Operation not permitted`, auch bei einem direkten Loopback-Bind-Versuch; die betroffenen HTTP/OIDC-Tests können hier nicht grün laufen. Nicht jeder Fehler des Gesamtlaufs wurde einzeln nachgeprüft. **Offen:** vollständigen seriellen Testlauf außerhalb dieser Sandbox auf SQLite, anschließend bei verfügbarer Testdatenbank auf MariaDB, und Lead-Integration. Keine Migration produktiv ausgeführt.

**Release v0.1.0 (19.10.2026):** Tags `v0.1.0` in Backend, PWA und Apple-Repo; Docker-Image `ghcr.io/magicalwig34653/timetrack-backend:0.1.0` (mit PWA 0.1.0), GitHub-Release (kein Pre-Release) mit Quellarchiv und Vertrag 0.22.0; TestFlight Version 0.1.0 Build 7. Nächste Schritte: Roadmap in `docs/ARBEITSPLAN.md` (S1-Rest, N1, LA1, E1, AI1, R2, Q1, M2).


Stand: 17.10.2026 (Paket D3, Dokumentationsabgleich). Alle drei Repositories (Backend, PWA, Apple) sind seit 17.10.2026 öffentlich auf GitHub (AGPL-3.0-only), Historie von persönlichen Angaben bereinigt (siehe `ARBEITSPLAN.md`, Abschnitt „Veröffentlichung“). Das Projekt ist **Alpha**: Backend und PWA decken Etappe 1–4 ab, die nativen Apps (Etappe 5) sind implementiert, aber noch nicht auf Echtgeräten erprobt; KI, Kalenderbrücke und Selbstständigenfunktionen (Etappe 6) fehlen.
**W2 (Assets, 18.10.2026, Branch `w2-asset-recovery` in Backend und PWA, nicht gemergt):** fehlende `/_app/`-Dateien und Asset-Pfade antworten mit echtem 404 statt SPA-Hülle; die PWA heilt sich bei Asset-Ladefehlern einmal pro 5 Minuten selbst oder zeigt eine Meldung statt weißer Seite (`handoffs/W2-asset-recovery.md`).
Zahlen unten sind die zuletzt vom Lead selbst gemessenen (Stand der Pakete P2/A8 vom 16./17.10.); seitdem änderten sich in Backend und PWA nur CI, Website und Dokumentation, keine Quellen.

## Was läuft wo

| Ort | Stand |
| --- | --- |
| Entwicklungsstack (lokal, Colima, Compose-Projekt `timetrack-dev`) | Backend (Swift/Vapor/Fluent) mit MariaDB 12.3 oder SQLite, Mailpit, S3Mock, Dex; Befehle in `EINRICHTUNG.md` |
| Live-Testinstanz (privat, hinter dem Reverse Proxy des Betreibers, Compose-Profil `app`, MariaDB) | Backend und PWA im Stand P2 (Vertrag v0.14.0), ausgerollt am Abend des 16.10.2026. **Nicht** auf der Testinstanz: der Apple-Endpunkt `/.well-known/apple-app-site-association` ist aus (`APPLE_APP_IDS` nicht gesetzt); Stack-Vorlage und Deployment-Anleitung (B3/D2) laufen dort nicht (Compose-Dev-Profil). Zugang für Dritte: keiner (Einladungsprinzip) |
| Produktionsinstanz | Wird vom Betreiber gerade eingerichtet (Swarm, eigene MariaDB; Anleitung `DEPLOYMENT.md`; im Repo steht als Platzhalter die Domain `timetrack.example.org`). Noch nichts ausgerollt, Go-Live-Checkliste nicht durchlaufen |
| GitHub (öffentlich) | Repos mit Workflows (W1), GitHub-Pages-Website aus `site/` (Pages-Lauf grün), Dependabot-Pull-Requests offen (Stand 17.10.: Backend 2, PWA 3, Apple 1) |
| TestFlight | Archiv und Export lokal mit `scripts/testflight.sh` im Apple-Repo bestätigt; **Upload steht aus**, weil er auf die AASA-Auslieferung der Produktionsdomain wartet |

## Paket W4 (Wochen-/Konto-/Statistik-Performance, 28.10.2026, Lead-Prüfung offen)

Branch `w4-week-perf`: Kontostand-Zwischenstände je Monatsende mit DB-Änderungsmarken (Migration `w4.create_time_change_marks`), Fenster-Snapshot für Woche/Konto/Statistik; Woche 147 -> 29 ms, Konto 122 -> 20 ms bei 3 Jahren Historie, Antworten inhaltsgleich (625 Äquivalenzvergleiche), Vertrag unverändert. MariaDB nicht geprüft (`docs/handoffs/W4-perf.md`).

## Paket W3 (stornierte Abschnitte, Statistik, 23.10.2026, Lead-Prüfung offen)

Branch `worktree-agent-ac1cefa377b418f8e`: Liste, Wiederherstellen und endgültiges Löschen (einzeln und gesammelt mit `dryRun`) stornierter Zeitabschnitte, MCP nur Liste und Wiederherstellen; Statistikreihe `GET /time/statistics` (Tag/Woche/Monat) für Diagramme (Vertrag v0.28.0). PWA-/Apple-Oberflächen fehlen noch (`docs/handoffs/W3-cancelled-statistics.md`).

## Paket W1 (Abgang beendet fremde Timer, Auslöse-Links, 22.10.2026, Lead-Prüfung offen)

Branch `worktree-agent-a96dfb882f965b00e`: (A) `departure` beendet jeden laufenden Abschnitt (Modus `direct`/`suggest`/`off` beachtet, Ereigniszeit rückdatiert); (B) Auslöse-Links `GET /t/{token}/{start|stop|toggle}` ohne Sitzung, Token nur als Hash, 404 ohne Orakel, Ratenbegrenzung, idempotent, `no-store`, Verwaltung `GET/POST/DELETE /me/trigger-links` (Vertrag v0.26.0, ADR-0027, Migration `w1.create_trigger_links`). **PWA-Verwaltungsansicht fehlt** (`docs/handoffs/W1.md`). Messwerte im Handoff.

## Paket B7 (Urlaubsantrag-Vorlage, 19.10.2026, Lead-Prüfung offen)

Branch `worktree-agent-a5d512514485f6486`: Vorlage (PDF) und Zuordnung für den Urlaubsantrag je Konto, fünf Endpunkte unter `/vacation/request-form`, Datei im Dateispeicher, Export und Kontolöschung (Vertrag v0.25.0, ADR-0026). 357 Tests, 0 Fehler (SQLite und MariaDB). Details `docs/handoffs/B7.md`.

## Paket B6 (Anhangzahl und Inline-Vorschau, 19.10.2026, Lead-Prüfung offen)

Branch `worktree-agent-a0c3a2218a5ea8324`: `Absence.attachmentCount` (eine aggregierte Abfrage je Liste), `GET /absences?hasAttachment=true|false`, `GET /files/{id}?disposition=inline` nur für sichere Vorschautypen mit nosniff und CSP-Sandbox (Vertrag v0.24.0, ADR-0006 Nachtrag). 354 Tests, 0 Fehler (SQLite und MariaDB). Details `docs/handoffs/B6.md`.

## Paket S1b (Sicherheitsbefunde Q1, 19.10.2026, Lead-Prüfung offen)

Branch `worktree-agent-aecf20448f928398e`: `system/info` Betriebsfelder nur für Administratoren (Vertrag v0.23.0, ADR-0023 Nachtrag; **PWA muss die fehlenden Felder tolerieren, siehe Handoff**), SMTP-Prüfung ohne Serverantworttext und mit Schwärzung der Zugangsdaten, `X-Real-IP`-Doku und Startwarnung, OIDC-Transportfehler nicht mehr als Datenbankausfall, `summary` je Operation (Vertragstest), Anmeldung einmal pro Anfrage (Modul-GET: 8 auf 6 Abfragen, 2 auf 1 Sitzungsabfrage), Lizenzkette BoringSSL ergänzt. 353 Tests, 0 Fehler (SQLite und MariaDB). Details `docs/handoffs/S1b.md`.

## Paket V2 (Urlaubsplanung, Backend, 19.10.2026, Lead-Prüfung offen)

Branch `v2-vacation-suggestions`: `GET /vacation/suggestions` (Brückentage, Feiertagsblöcke, Schulferien-Erweiterungen, Auszeiten nach Effizienz; Vertrag v0.22.0, ADR-0025), reiner Algorithmus mit Unit-Tests, Handoff `docs/handoffs/V2-backend.md`. PWA-Gegenstück offen. 346 Tests, SQLite 0 Fehler (40 übersprungen), MariaDB 0 Fehler (2 übersprungen).

## Paket AC2 (Akzentfarben, 18.10.2026, Lead-Prüfung offen)

Branch `AC2`: sechs weitere Akzent-IDs `wine`, `slate`, `cocoa`, `olive`, `ocean`, `ink` (Vertrag v0.21.0, ADR-0020 Nachtrag), PWA-Gegenstück gleicher Branchname. Details und Farbwerte für die Apple-Apps `docs/handoffs/AC2.md`.

## Paket S1a (Datenbankausfall als 503, 18.10.2026, Lead-Prüfung offen)

Branch `S1a`: Verbindungs- und Pool-Fehler liefern 503 `database_unavailable` mit `Retry-After` statt 500 (ADR-0024, Vertrag v0.20.0); `/ready` und Healthcheck unverändert und geprüft. 331 Tests, 0 Fehler (SQLite und MariaDB). Details `docs/handoffs/S1a.md`.

## Paket X1 (Performance, Stand 17.10.2026, Lead-Prüfung offen)

Ursache für „App lädt ewig“ nach Import war CPU (Zuordnung und Kalenderaufbau je Tag), nicht Abfragezahl; `GET /time/account` bei 800+ Tagen 5,9 s auf 53 ms (SQLite) bzw. 82 ms (MariaDB), `time/days` 93 Tage 755 → 64 ms. Das Arbeitsmodell scheiterte beim ersten Mal, weil die blockierenden Berechnungen den Pool/`auth_lock` 10 s belegten (500 `not_ready`); ebenso war `/ready` unter Last in der Healthcheck-Zeitgrenze (dort Quelle von „Server nicht bereit“). Behoben und mit Zahlen in `docs/handoffs/X1.md`; neuer Index (Migration `x1.add_segment_time_index`); Vertrag unverändert. Tests: SQLite 310 (35 übersprungen), MariaDB 310 (1 übersprungen), PWA 591 Unit, 180 Echt-E2E; auf dem echten Swarm/Proxy ungeprüft.

## Paket K1 (Wochenplanung und Wochenübersicht, 17.10.2026, Lead-Prüfung offen)

Geplante Zeiten am Plantag, `GET/PUT /plan/weeks/{isoWeek}`, `GET /time/weeks/{isoWeek}`, Vertrag v0.17.0, ADR-0021; PWA „Woche“ (Übersicht und Planer). Selbst gemessen: SQLite 315 Tests (37 übersprungen) und MariaDB 315 Tests (1 übersprungen), je 0 Fehler; Linux-Image baut; Details `docs/handoffs/K1.md`. Native Apps folgen später.

## Was gebaut ist (Backend, vom Lead ausgeführt)

Konten, Einladungen, Passkeys, Sitzung/CSRF, Recovery (Codes, Rückfallpasswort, E-Mail via SMTP), optionales OIDC, Profil und E-Mail-Änderung per Code, geführte Einrichtung (P1), Darstellung je Konto (P2), Kontenverwaltung mit Selbstauskunft/-löschung (B1), Aufräumjob (B2), vertrauenswürdige Proxys (B4), abschaltbare Module (C20), Zeittracking (Modelle mit Gültigkeit, Orte, Segmente mit Revisionen, idempotenter Timer, Rundung nur äußerste Grenzen, Pausenhinweise, Schulregel, Zeitkonto), Automation per Geräte-Token, Urlaub/Abwesenheiten (inkl. „Freigestellt“)/Feiertage/Planung/Freigaben, Export (XLSX/PDF/CSV, Arbeitszeit-Tabelle), Import (CSV/XLSX mit Vorschau/Commit/Rollback, Arbeitszeit-Tabelle), Dateispeicher (DB/lokal/S3), Berichtsheft (Standardformat, kopierbarer Text), OAuth-Server (DCR, PKCE, Refresh-Rotation), persönliche Tokens, MCP-Endpunkt `/mcp` mit 22 Tools, Hinweise/Erinnerungen/Web Push mit Scheduler, Apple-App-Site-Association (A2), Backup/Restore-Skripte und Swarm-Stack-Vorlage (B3).
API-Vertrag: `contracts/openapi.yaml` **v0.14.0**.

| Messung | Ergebnis | Quelle |
| --- | --- | --- |
| Backend-Tests (SQLite) | **305, 0 Fehler** (`swift test --build-system native`) | Lead, Paket P2 |
| Backend-Tests (MariaDB 12.3) | zuletzt vom Lead vollständig 277 (B2); 295 laut Agent (B5); für den Stand P2 nicht erneut vom Lead | Handoffs B2/B5 |
| Linux-Image | baut (`docker compose --profile app build backend`), arm64 nativ; amd64 nur unter Emulation und nur für einen älteren Stand belegt | L3a, B3 |
| Restore-Beweis | 36 Prüfungen auf SQLite und MariaDB bestanden | B3 (Lead) |
| Vertragstreue | Routenabgleich und ca. 55 Antwortformen ohne Abweichung; Anfrageschemas, MCP, OAuth, Dateien ungeprüft | B5 |
| Codex-Review C9–C18 | 12 Befunde, alle in C19 behoben | `docs/reviews/2026-10-15-codex-review.md` |

## PWA (Repo timetrack-pwa)

Svelte 5/SvelteKit (statisch), Tailwind, shadcn-Stil, Designsprache nach ADR-0014/`DESIGN.md`. Alle Seiten der Etappen 1–4 inklusive Berichtsheft, Export/Import, Speicher-Admin, Verbindungen/Tokens/MCP-Hilfe, OIDC, Modulschalter, Konten-Verwaltung, Datenschutz, Profil/Einrichtung, Darstellung je Konto.
Zuletzt vom Lead gemessen (Paket P2): `npm run check` ohne Fehler, **587 Unit-Tests, 84 Mock-E2E, 6 PWA-Produktionsbuild-Specs, 180 Echt-E2E** (gegen frisch gebautes Backend, virtueller Passkey). Auf GitHub: PWA-CI und CodeQL grün (17.10.).

## Apple-Apps (Repo timetrack-apple)

macOS, iOS/iPadOS und watchOS (Paketliste A1–A8: Kern `TimetrackCore`, Design `TimetrackDesign`, Apps, Uhr mit Komplikation, Widgets/Live Activity/Control Center, App-Symbole, Darstellung, Konto-Akzent). Letzte Messung (A8, Lead): **93 Kerntests + 14 Design-Tests**, Builds für iOS, macOS und watchOS erfolgreich (unsigniert), UI-Smoke auf iPhone- und iPad-Simulator gegen Wegwerf-Backend. Details und Grenzen: `timetrack-apple/docs/STATUS.md`.
Signierung: bezahltes Apple Developer Program, Team im Apple-Repo hinterlegt; Associated Domains und App Groups funktionieren mit dem bezahlten Team (zuvor mit persönlichem Team nicht). Der Passkey-Weg in den Apps braucht die AASA-Datei auf der erreichbaren Produktionsdomain (ADR-0015).

## CI auf GitHub (Stand 17.10.2026)

- **Pages und CodeQL**: grün (Backend, PWA). **PWA-CI**: grün.
- **Backend-CI rot (Swift-Jobs SQLite und MariaDB)**: `Tests/TimetrackKitTests/ExportTests.swift` nutzt `XMLParser`; unter Linux muss dafür `FoundationXML` importiert werden (Kompilierfehler, auf macOS unsichtbar). Vertrags- und Shell-Prüfungen grün. Behebung steht aus (Testcode, nicht Teil von D3).
- **Dependency Review**: schlägt fehl, solange „Dependency graph“ in den Repository-Einstellungen nicht aktiviert ist (Einstellung durch den Betreiber).
- **Apple-CI rot**: Der gehostete Runner hat nur Swift 6.3.3; die Pakete verlangen Swift Tools 6.4 (Xcode 27). XcodeGen-Drift-Prüfung grün. Lösung braucht einen Runner mit Xcode 27 (selbst gehostet, Variable `APPLE_RUNNER`).
- Docker-Multi-Arch-Lauf (Backend): beim Abgleich noch in Arbeit, Ergebnis ungeprüft.

## Nicht belegt / bekannte Lücken (konsolidiert)

**Geräte und Clients**
- Shortcuts mit echter Standortauslösung auf iPhone/Mac, echter Plattform-Passkey (PWA und Apps), Safari-Zwischenablage, Firefox/WebKit, Screenreader/VoiceOver.
- ChatGPT-/Claude-Connector gegen `/mcp` (Anleitung `MCP.md`; nur Protokoll und Skript-Client belegt).
- Web-Push-Zustellung auf echten Geräten (nur Fake-Dienst); echte E-Mail-Zustellung (SMTP nur gegen Mailpit/Fake, kein TLS/AUTH real).
- Native Apps: alle Geräteprüfungen offen (WatchConnectivity auf gekoppeltem Paar, Komplikation auf dem Zifferblatt, Widgets, Live Activity, Control Center, Keychain-Lesen aus Erweiterungen, App Intents); macOS-Oberfläche nur als Hierarchie-Aufnahme bzw. Fensterbild gesichtet, keine vollständige visuelle Prüfung des Mac-Clients.
- Konto-Akzent/Erscheinungsbild in den Apps: Offline-/Fehlerzustände und Zwei-Geräte-Konflikt ungeprüft.

**Betrieb**
- Produktionsstack (Swarm, eigene MariaDB 12.3.3, Proxy, TLS, AASA hinter dem Proxy) nie getestet; Lücke: `DB_TLS=required` ohne eigene CA (`DEPLOYMENT.md`). Restore auf anderem Host und Last ungeprüft; Metriken fehlen; amd64 nur nativ nachweisbar (Emulation > 60 min unfertig).
- Colima-Datenplatte der Entwicklungsmaschine kann volllaufen (40 GB; `TESTUMGEBUNGEN.md`).
- Globale `auth_lock`-Serialisierung begrenzt den Durchsatz (Bewertung in ADR-0017); Mehr-Replikas-Betrieb und S3Mock-Lauf von B2 ungeprüft.
- Trusted-Proxy-Header (B4) ohne echten Proxy getestet.
- Frühere Beobachtung: zwei C19-Push-Tests waren lastempfindlich; B5 machte sie deterministisch (20/20 stabil), Lead-Prüfung der Ursache nur teilweise.

**Fachlich und Daten**
- IHK-Berichtsheft-Ausgabeformat (Standardprofil angenommen, ADR-0008); Jugendprofil R2 im Backend-Worktree, Client-Anzeige und fachliche Prüfung offen.
- XLSX/PDF-Exporte nicht in Excel/LibreOffice/Viewer geöffnet; Import mit 20 000 Zeilen und Blobs nahe 64 MiB auf MariaDB nicht gemessen; S3 nur gegen S3Mock/In-Process-Fake; S3-Kontolöschung nicht gegen S3Mock getestet; sehr große Konto-Exporte ungeprüft.
- Access-Token-Ablauf (1 h) zeitgesteuert nicht getestet.
- Vertrag: 189 Redocly-Lint-Fehler (überwiegend fehlende `summary`), Request-Schemas nicht abgeglichen.

**Lizenz und Veröffentlichung**
- Release-Prüfung der Abhängigkeiten offen (`LIZENZEN.md`, Paket L3): `swift-nio-ssl` 2.37.5 (neuestes Release) bettet BoringSSL mit 323 Dateien unter der alten OpenSSL-Lizenz ein; Upstream-`main` ist bereits auf Apache-2.0 umgestellt (BoringSSL `8eb25be6…`), ein Release fehlt. **Entscheidung des Rechteinhabers nötig:** auf Release warten bzw. `main` pinnen, und/oder die vorgeschlagene AGPL-§7-Ausnahme (`LICENSE-EXCEPTION.md`, Vorschlag, nicht in Kraft) übernehmen. Erledigt in L3: `THIRD-PARTY-NOTICES` im Image und als Release-Asset (`scripts/third-party-notices.sh`), Betriebssystempakete und XKCP inventarisiert. Offen: Lizenzbeilage im PWA-Bundle (PWA-Repo), Apple-Apps. Details `docs/handoffs/L3.md`.
- Commit-Hashes in Handoffs und älteren Dokumenten sind seit der Historienbereinigung veraltet.

**Nicht begonnen** (Etappe 5/6): KI-Entwurfs-Worker (Mac), Kalenderbrücke (EventKit/Google), Standortautomatik auf iOS (Region Monitoring), Selbstständigenfunktionen, strukturierter PDF-Altberichtimport, Offline-Schreiben, E-Mail als Hinweiskanal.

## Codex-Anteil

Nachgerechnet in `ARBEITSPLAN.md`: 77 von 395 Punkten ≈ 19,5 % (Richtwert 40–60 %). Das Kontingent war vom 14.10. bis 15.10. erschöpft; Codex schreibt nur im Backend-Hauptordner. Offene Codex-Reviews: Pakete B1–B5, P1/P2, A2, PWA.

## Umgebung

Swift 6.4 (Xcode 27), Node 26.5/npm 11.17, Docker 29.5.2 (Colima arm64), Compose 5.3.1, Buildx 0.38. `swift test` nur mit `--build-system native` (Standard scheitert an Codesign-Xattrs). Parallele Agents: je eigener Worktree und eigene Test-Datenbank (`MARIADB_TEST_DB`). In Colima laufen fremde Projekte: nur `timetrack-dev-*` anfassen.

## Nächste Schritte

1. **Betreiber**: Produktionsinstanz fertig einrichten (`DEPLOYMENT.md`), `APPLE_APP_IDS` setzen, AASA von außen und über das Apple-CDN prüfen, ersten Admin mit echtem Passkey anlegen.
2. **TestFlight-Upload** (iOS und macOS) ausführen, sobald die Produktions-AASA erreichbar ist; Build-Nummer vor jedem Upload erhöhen (`scripts/testflight.sh`, Apple-Repo).
3. **Echtgerätetests**: Passkey in PWA und Apps, Shortcuts, Push, Widgets/Komplikation/Live Activity, WatchConnectivity, ChatGPT-/Claude-Connector (`MCP.md`).
4. **CI reparieren**: Linux-Testkompilierung (`FoundationXML`), „Dependency graph“ aktivieren, Apple-Runner mit Xcode 27 oder Apple-CI auf manuell/lokal beschränken; Dependabot-Pull-Requests sichten (große Sprünge wie TypeScript 7 oder Redocly 2 nicht blind mergen).
5. **Produktpunkte**: IHK-Berichtsheft-Format klären (Beispiel vom Betreiber), R2-Jugendprofil nach vollständigem Testlauf integrieren und fachlich prüfen, Standortautomatik auf iOS, KI-Entwurfs-Worker, Kalenderbrücke, Selbstständigenfunktionen, visuelle Prüfung des nativen Mac-Clients.
6. **Qualität**: Codex-Reviews für B1–B5/P1/P2/A2 nachholen (Kontingent prüfen); Lizenz-Release-Prüfung (BoringSSL); Vertrag: `summary` je Operation ergänzen.

## Roadmap

Reihenfolge, Umfang und Entscheidungen vom 17.10.2026: `docs/ARBEITSPLAN.md`, Abschnitt „Roadmap nach Release v0.1.0“.

**MAIL1 (17.10.2026, Lead-Prüfung offen):** E-Mail-Diagnose für Admins (`/admin/mail`, `/admin/mail/check`, `/admin/mail/test`), Vertrag v0.18.0, ADR-0022; Details `docs/handoffs/MAIL1.md`.
