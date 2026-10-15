# Aktueller Projektstand

Stand: 15.10.2026. Backend und PWA decken Etappe 1–4 ab (siehe unten); native Apps, KI und spätere Etappen fehlen. `main` in beiden Repos, keine Remotes, nichts veröffentlicht.

## Was läuft (vom Lead selbst ausgeführt)

- **Backend** (Swift/Vapor/Fluent, MariaDB 12.3 und SQLite): Konten, Einladungen, Passkeys, Sitzung/CSRF, Recovery (Codes, Rückfallpasswort, E-Mail via SMTP-Sender), optionales OIDC, Zeittracking (Modelle, Orte, Segmente mit Revisionen, idempotenter Timer,
  Rundung nur äußerste Grenzen, Pausen, Schulregel, Zeitkonto), Automation per Geräte-Token (Shortcuts), Urlaub/Abwesenheiten/Feiertage (alle Bundesländer)/Planung/Freigaben, Export (XLSX/PDF/CSV), Import (CSV/XLSX mit Vorschau/Commit/Rollback),
  Dateispeicher (DB/lokal/S3, Admin-Regeln, Anhänge), Berichtsheft (Standardformat, kopierbarer Text), OAuth-Server (DCR, PKCE, Refresh-Rotation), persönliche Tokens, Grants, MCP-Endpunkt `/mcp` mit 22 Tools.
  Dazu Hinweise/Erinnerungen/Web Push (RFC 8291/8292, VAPID) mit Scheduler und Lease.
  **193 Tests, 0 Fehler** (`swift test --build-system native`; mit frischer MariaDB-Testdatenbank 0 übersprungen). Linux-Image baut (`docker compose --profile app build backend`). Codex-Adversarial-Review C9–C18 lieferte 12 Befunde, alle behoben (C19, `docs/reviews/2026-10-15-codex-review.md`).
- **PWA** (Svelte 5/SvelteKit statisch, Tailwind/shadcn-Stil): alle zugehörigen Seiten inkl. Berichtsheft, Export/Import, Speicher-Admin, Verbindungen/Tokens/MCP-Hilfe, OIDC. `npm run check` ohne Fehler, **426 Unit-Tests (1 flackernder Altest L4), 53 Mock-E2E, 128 Echt-E2E, 6 PWA-Produktionsbuild-Specs** (Playwright gegen echte Wegwerf-Backends, virtueller Passkey, S3Mock-Test).
- **Live-Testinstanz**: `https://test.example.org` (→ 192.0.2.10:18080, Compose-Profil `app`, MariaDB) mit aktuellem Backend und PWA; erster Admin-Link noch zu erzeugen (siehe EINRICHTUNG.md/TESTUMGEBUNGEN.md).
- **Testumgebungen** (`docs/TESTUMGEBUNGEN.md`): Mailpit (Mail-Recovery Ende-zu-Ende belegt), Adobe S3Mock, Dex (OIDC), Bind-Adressen.

## Offen / nicht belegt

- **Geräte/Clients**: Shortcuts auf echtem iPhone/Mac, echter Plattform-Passkey, ChatGPT-/Claude-Connector gegen `/mcp` (Anleitung `docs/MCP.md`, nicht erprobt), Safari-Zwischenablage, Firefox/WebKit, Screenreader.
- **Betrieb**: Colima-Datenplatte nahezu voll (40 GB) – `docker builder prune` oder größere Platte (TESTUMGEBUNGEN.md); amd64 nur emuliert und für SQLite belegt (Stand 14.10., nicht für den aktuellen Stand); hinter Reverse Proxy nutzt das Rate-Limit die Peer-IP; globale `auth_lock`-Serialisierung begrenzt Durchsatz.
- **Fachlich offen**: IHK-Berichtsheft-Ausgabeformat (Standardprofil angenommen), E-Mail-SMTP nur gegen Mailpit/Fake (kein TLS/Auth real), Token-Ablauf (1 h Access) und abgelaufene Tokens nicht zeitgesteuert getestet, XLSX/PDF nicht in Excel/Viewer geöffnet, Import mit 20 000 Zeilen auf MariaDB nicht gemessen,
  MariaDB-Blobs nahe 64 MiB, S3 nur gegen S3Mock, kein periodischer Aufräumjob für Speicher, einzelne Testdatenbank-Kollisionen bei paralleler Agent-Arbeit.
- **Codex-Anteil**: Kontingent war vom 14.10. bis 15.10. erschöpft; C9–C18 setzten deshalb Claude-Agents um (Nutzerentscheidung 14.10.), Codex prüfte sie anschließend (R1, 12 Befunde) und behob sie (C19). Dockerfile/Compose ohne Befund im Review; PWA-Code seit L3b nicht mehr von Codex geprüft.
- **Nicht begonnen**: native Apps macOS/iOS/watchOS und Kalenderbrücke (Etappe 5), KI/Mac-Worker, Selbstständigenfunktionen, Google-Kalender, Offline-Sync (Etappe 6), strukturierte PDF-Altberichte.

## Umgebung

Swift 6.4, Node 26.5/npm 11.17, Docker 29.5.2 (Colima arm64), Compose 5.3.1, Buildx 0.38. `swift test` nur mit `--build-system native` (Standard scheitert an Codesign-Xattrs). Parallele Agents: je eigener Worktree und eigene Test-Datenbank (`MARIADB_TEST_DB`).
In Colima laufen fremde Projekte: nur `timetrack-dev-*` anfassen.

## Nächste Schritte

0. Nutzer: Echtgeräte-Tests (Push-Zustellung iOS/Android/Desktop über die Testdomain, Installation als PWA, Shortcuts, ChatGPT-/Claude-Connector).
1. Nutzer: ersten Admin-Link erzeugen, mit echtem Passkey registrieren, Shortcuts/Passkeys/MCP-Connector prüfen (`docs/SHORTCUTS.md` im PWA-Repo, `docs/MCP.md`).
2. Flackernder Unit-Test `TimerCard … double click` (L4) stabilisieren; Backend-Findings aus L16 (Allowlist für weitere Push-Dienste prüfen).
3. Native macOS-App (Etappe 5), danach iOS/iPadOS/watchOS; KI-Entwürfe/Mac-Worker.
4. Nach Rückkehr des Codex-Kontingents: Codex-Adversarial-Reviews für Backend-Pakete C9–C17.

## C19-Prüfstand (15.10.2026, Branch `c19-review-fixes`)

Zwölf Reviewkorrekturen und Zahlen-/Datums-Sweep implementiert, uncommitted im Hauptverzeichnis; noch nicht abgenommen.
Neue Migrationen `BindStorageLocations` und `HardenPushOutbox`; Original-Dateistandorte werden gebunden,
Push-Outbox erhält Claims und Abschlusszeit. Details: `handoffs/C19.md`, Entscheidung ADR-0011.
Build erfolgreich. Letzte vollständige Suite: 193 Tests, 15 MariaDB-Varianten übersprungen,
33 Tests wegen Socket-Sandboxfehlern fehlgeschlagen (35 Meldungen, ausschließlich `Operation not permitted`).
C19: 14 Tests bestanden, 2 MariaDB-Varianten übersprungen; Fehler-Reinjektion für alle zwölf Befunde
sowie Formatierung/ZIP64 bestätigt. MariaDB-Einrichtung scheitert am Colima-Socket, TCP ebenfalls gesperrt.
Keine Testdatenbank angelegt, keine Container oder `.env` verändert. Vollständige Abnahme außerhalb der
Sandbox und Commit durch den Lead stehen aus; Details und nächster Schritt im Handoff C19.
