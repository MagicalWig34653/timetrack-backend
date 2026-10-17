# Aktueller Projektstand

Stand: 17.10.2026 (Paket D3, Dokumentationsabgleich). Alle drei Repositories (Backend, PWA, Apple) sind seit 17.10.2026 öffentlich auf GitHub (AGPL-3.0-only), Historie von persönlichen Angaben bereinigt (siehe `ARBEITSPLAN.md`, Abschnitt „Veröffentlichung“). Das Projekt ist **Alpha**: Backend und PWA decken Etappe 1–4 ab, die nativen Apps (Etappe 5) sind implementiert, aber noch nicht auf Echtgeräten erprobt; KI, Kalenderbrücke und Selbstständigenfunktionen (Etappe 6) fehlen.
Zahlen unten sind die zuletzt vom Lead selbst gemessenen (Stand der Pakete P2/A8 vom 16./17.10.); seitdem änderten sich in Backend und PWA nur CI, Website und Dokumentation, keine Quellen.

## Was läuft wo

| Ort | Stand |
| --- | --- |
| Entwicklungsstack (lokal, Colima, Compose-Projekt `timetrack-dev`) | Backend (Swift/Vapor/Fluent) mit MariaDB 12.3 oder SQLite, Mailpit, S3Mock, Dex; Befehle in `EINRICHTUNG.md` |
| Live-Testinstanz (privat, hinter dem Reverse Proxy des Betreibers, Compose-Profil `app`, MariaDB) | Backend und PWA im Stand P2 (Vertrag v0.14.0), ausgerollt am Abend des 16.10.2026. **Nicht** auf der Testinstanz: der Apple-Endpunkt `/.well-known/apple-app-site-association` ist aus (`APPLE_APP_IDS` nicht gesetzt); Stack-Vorlage und Deployment-Anleitung (B3/D2) laufen dort nicht (Compose-Dev-Profil). Zugang für Dritte: keiner (Einladungsprinzip) |
| Produktionsinstanz | Wird vom Betreiber gerade eingerichtet (Swarm, eigene MariaDB; Anleitung `DEPLOYMENT.md`; im Repo steht als Platzhalter die Domain `timetrack.example.org`). Noch nichts ausgerollt, Go-Live-Checkliste nicht durchlaufen |
| GitHub (öffentlich) | Repos mit Workflows (W1), GitHub-Pages-Website aus `site/` (Pages-Lauf grün), Dependabot-Pull-Requests offen (Stand 17.10.: Backend 2, PWA 3, Apple 1) |
| TestFlight | Archiv und Export lokal mit `scripts/testflight.sh` im Apple-Repo bestätigt; **Upload steht aus**, weil er auf die AASA-Auslieferung der Produktionsdomain wartet |

## Paket X1 (Performance, Stand 17.10.2026, Lead-Prüfung offen)

Ursache für „App lädt ewig“ nach Import war CPU (Zuordnung und Kalenderaufbau je Tag), nicht Abfragezahl; `GET /time/account` bei 800+ Tagen 5,9 s auf 53 ms (SQLite) bzw. 82 ms (MariaDB), `time/days` 93 Tage 755 → 64 ms. Das Arbeitsmodell scheiterte beim ersten Mal, weil die blockierenden Berechnungen den Pool/`auth_lock` 10 s belegten (500 `not_ready`); ebenso war `/ready` unter Last in der Healthcheck-Zeitgrenze (dort Quelle von „Server nicht bereit“). Behoben und mit Zahlen in `docs/handoffs/X1.md`; neuer Index (Migration `x1.add_segment_time_index`); Vertrag unverändert. Tests: SQLite 310 (35 übersprungen), MariaDB 310 (1 übersprungen), PWA 591 Unit, 180 Echt-E2E; auf dem echten Swarm/Proxy ungeprüft.

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
- IHK-Berichtsheft-Ausgabeformat (Standardprofil angenommen, ADR-0008); Rechtsprofile für Jugendliche fehlen (nur `arbzg-adult-de`).
- XLSX/PDF-Exporte nicht in Excel/LibreOffice/Viewer geöffnet; Import mit 20 000 Zeilen und Blobs nahe 64 MiB auf MariaDB nicht gemessen; S3 nur gegen S3Mock/In-Process-Fake; S3-Kontolöschung nicht gegen S3Mock getestet; sehr große Konto-Exporte ungeprüft.
- Access-Token-Ablauf (1 h) zeitgesteuert nicht getestet.
- Vertrag: 189 Redocly-Lint-Fehler (überwiegend fehlende `summary`), Request-Schemas nicht abgeglichen.

**Lizenz und Veröffentlichung**
- Release-Prüfung der Abhängigkeiten offen (`LIZENZEN.md`): insbesondere eingebettetes BoringSSL in `swift-nio-ssl` (OpenSSL/ISC-Hinweise) und Beilage der Lizenztexte in Binär-/PWA-Auslieferung.
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
5. **Produktpunkte**: IHK-Berichtsheft-Format klären (Beispiel vom Betreiber), Rechtsprofile für Jugendliche, Standortautomatik auf iOS, KI-Entwurfs-Worker, Kalenderbrücke, Selbstständigenfunktionen, visuelle Prüfung des nativen Mac-Clients.
6. **Qualität**: Codex-Reviews für B1–B5/P1/P2/A2 nachholen (Kontingent prüfen); Lizenz-Release-Prüfung (BoringSSL); Vertrag: `summary` je Operation ergänzen.

## Roadmap

Reihenfolge, Umfang und Entscheidungen vom 17.10.2026: `docs/ARBEITSPLAN.md`, Abschnitt „Roadmap nach Release v0.1.0“.
