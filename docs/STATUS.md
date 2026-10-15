# Aktueller Projektstand

Stand: 15.10.2026. Backend und PWA decken Etappe 1–4 weitgehend ab (siehe unten); native Apps, KI und spätere Etappen fehlen. `main` in beiden Repos, keine Remotes, nichts veröffentlicht.

## Was läuft (vom Lead selbst ausgeführt)

- **Backend** (Swift/Vapor/Fluent, MariaDB 12.3 und SQLite): Konten, Einladungen, Passkeys, Sitzung/CSRF, Recovery (Codes, Rückfallpasswort, E-Mail via SMTP-Sender), optionales OIDC, Zeittracking (Modelle, Orte, Segmente mit Revisionen, idempotenter Timer,
  Rundung nur äußerste Grenzen, Pausen, Schulregel, Zeitkonto), Automation per Geräte-Token (Shortcuts), Urlaub/Abwesenheiten/Feiertage (alle Bundesländer)/Planung/Freigaben, Export (XLSX/PDF/CSV), Import (CSV/XLSX mit Vorschau/Commit/Rollback),
  Dateispeicher (DB/lokal/S3, Admin-Regeln, Anhänge), Berichtsheft (Standardformat, kopierbarer Text), OAuth-Server (DCR, PKCE, Refresh-Rotation), persönliche Tokens, Grants, MCP-Endpunkt `/mcp` mit 22 Tools.
  **169 Tests, 0 Fehler** (`swift test --build-system native` gegen frische MariaDB-Testdatenbank; SQLite-Varianten immer). Linux-Image baut (`docker compose --profile app build backend`).
- **PWA** (Svelte 5/SvelteKit statisch, Tailwind/shadcn-Stil): alle zugehörigen Seiten inkl. Berichtsheft, Export/Import, Speicher-Admin, Verbindungen/Tokens/MCP-Hilfe, OIDC. `npm run check` ohne Fehler, **384 Unit-Tests, 48 Mock-E2E, 120 Echt-E2E** (Playwright gegen echte Wegwerf-Backends, virtueller Passkey, S3Mock-Test).
- **Live-Testinstanz**: `https://test.example.org` (→ 192.0.2.10:18080, Compose-Profil `app`, MariaDB) mit aktuellem Backend und PWA; erster Admin-Link noch zu erzeugen (siehe EINRICHTUNG.md/TESTUMGEBUNGEN.md).
- **Testumgebungen** (`docs/TESTUMGEBUNGEN.md`): Mailpit (Mail-Recovery Ende-zu-Ende belegt), Adobe S3Mock, Dex (OIDC), Bind-Adressen.

## Offen / nicht belegt

- **Geräte/Clients**: Shortcuts auf echtem iPhone/Mac, echter Plattform-Passkey, ChatGPT-/Claude-Connector gegen `/mcp` (Anleitung `docs/MCP.md`, nicht erprobt), Safari-Zwischenablage, Firefox/WebKit, Screenreader.
- **Betrieb**: Colima-Datenplatte nahezu voll (40 GB) – `docker builder prune` oder größere Platte (TESTUMGEBUNGEN.md); amd64 nur emuliert und für SQLite belegt (Stand 14.10., nicht für den aktuellen Stand); hinter Reverse Proxy nutzt das Rate-Limit die Peer-IP; globale `auth_lock`-Serialisierung begrenzt Durchsatz.
- **Fachlich offen**: IHK-Berichtsheft-Ausgabeformat (Standardprofil angenommen), E-Mail-SMTP nur gegen Mailpit/Fake (kein TLS/Auth real), Token-Ablauf (1 h Access) und abgelaufene Tokens nicht zeitgesteuert getestet, XLSX/PDF nicht in Excel/Viewer geöffnet, Import mit 20 000 Zeilen auf MariaDB nicht gemessen,
  MariaDB-Blobs nahe 64 MiB, S3 nur gegen S3Mock, kein periodischer Aufräumjob für Speicher, einzelne Testdatenbank-Kollisionen bei paralleler Agent-Arbeit.
- **Codex-Anteil**: Kontingent erschöpft bis 20.10.2026 07:50; seit C9 setzen Claude-Agents die ursprünglich für Codex vorgesehenen Pakete um (Nutzerentscheidung 14.10.); Codex-Reviews von C9–C17 und Dockerfile/Compose stehen aus.
- **Nicht begonnen**: PWA-Manifest/Service Worker/Push/In-App-Hinweise (Etappe 4), native Apps macOS/iOS/watchOS und Kalenderbrücke (Etappe 5), KI/Mac-Worker, Selbstständigenfunktionen, Google-Kalender, Offline-Sync (Etappe 6), strukturierte PDF-Altberichte.

## Umgebung

Swift 6.4, Node 26.5/npm 11.17, Docker 29.5.2 (Colima arm64), Compose 5.3.1, Buildx 0.38. `swift test` nur mit `--build-system native` (Standard scheitert an Codesign-Xattrs). Parallele Agents: je eigener Worktree und eigene Test-Datenbank (`MARIADB_TEST_DB`).
In Colima laufen fremde Projekte: nur `timetrack-dev-*` anfassen.

## Nächste Schritte

1. Nutzer: ersten Admin-Link erzeugen, mit echtem Passkey registrieren, Shortcuts/Passkeys/MCP-Connector prüfen (`docs/SHORTCUTS.md` im PWA-Repo, `docs/MCP.md`).
2. PWA-Installierbarkeit (Manifest, Service Worker, Web Push, In-App-Hinweise) – Rest von Etappe 4.
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
