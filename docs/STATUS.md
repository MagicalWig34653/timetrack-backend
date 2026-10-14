# Aktueller Projektstand

Stand: 14.10.2026. Etappe 0/1 (Grundlage und Konten) ist lokal lauffähig und getestet (arm64 nativ, amd64 emuliert); `main` in beiden Repos.
Sicherheitsrelevant und noch ungeprüft: siehe „Offen“.

## Was läuft (vom Lead selbst ausgeführt)

- **Backend (C1–C3, Codex)**: SwiftPM `TimetrackKit` + `App`; Konfiguration per Umgebung; Fluent-Migrationen für MariaDB und SQLite;
  Einladungen (nur Hash, einmalig), Konten, Passkeys (webauthn-swift, mehrere pro Konto, einzelner Widerruf, Schutz des letzten),
  Sitzungen (HttpOnly-Cookie, CSRF-Header), Recovery per Recovery-Codes, Rückfallpasswort (Argon2id) und E-Mail-Code (SMTP-Sender),
  Admin-Einladungs-API, Rate-Limits, `App bootstrap-admin`, `App migrate`, `/health`, `/ready`, statische PWA mit SPA-Fallback.
  `swift test --build-system native` → **31 Tests, 0 Fehler** auf SQLite und MariaDB 12.3.3 (Dev-Container), inkl. Konkurrenztests
  (Einladung/Recovery genau ein Gewinner) und Kontentrennung über direkte IDs. Handoffs: `docs/handoffs/C1.md`, `C2.md`, `C3.md`.
- **PWA (L1, L3b; Repo timetrack-pwa)**: Einladung/Registrierung, Login, Recovery, Passkey-/Recovery-/Sitzungsverwaltung, Admin-Einladungen.
  `npm run check`, 32 Vitest-Tests, Build grün. **Playwright-E2E 15/15** gegen das echte Backend (Chromium, virtueller Authenticator, SQLite).
- **Umgebung (L2, L3a)**: `compose.yaml` (Projekt `timetrack-dev`), `scripts/dev-env.sh`, MariaDB 12.3.3 auf 127.0.0.1:13306 mit
  persistentem Volume. **arm64-Image** gebaut (611 MB), Container mit MariaDB und SQLite gestartet, `/health` `/ready` 200, Migrate-Befehl,
  Bootstrap-Link, PWA-Auslieferung und SQLite-Persistenz laut Agent-Lauf belegt (`docs/handoffs/L3a.md`; vom Lead nicht einzeln wiederholt).
- Codex-Review der PWA (L1/L3b) hat zwei Fehler gefunden (leere 202-Antwort bei E-Mail-Recovery, getrimmtes Rückfallpasswort); behoben (`8291dd0`).

## Offen / nicht belegt

- **Linux amd64** (14.10., Lead): Image unter QEMU in Colima gebaut (≈55 min; SwiftPM braucht dort `taskset`-Workarounds), Container
  `--platform linux/amd64` im SQLite-Modus: `uname -m` = x86_64, `/health` und `/ready` je 200. **Nicht belegt**: MariaDB-Modus unter amd64,
  `build-multiarch`, echter amd64-Host (nur Emulation). Das Dockerfile wendet `taskset` auch bei nativen Builds an (soll Build-Argument werden).
- Browserprüfung nur Headless-Chromium mit virtuellem Passkey; kein echter Plattform-Authenticator, kein Firefox/WebKit, kein Mobilbreite/Dark Mode.
- E-Mail-Recovery nur gegen Fake-SMTP getestet (nicht gegen Mailpit/echten Server). MariaDB-Modus der E2E nicht umgesetzt.
- Reverse-Proxy: Rate-Limit nutzt Peer-IP (kein `X-Forwarded-For`); globale `auth_lock`-Serialisierung begrenzt Durchsatz.
- `/_app/*.js`-Unbekannte liefern SPA-Fallback 200 statt 404 (Kosmetik). Dev-Einladungstokens aus Tests bleiben in Dev-DBs bis Ablauf.
- Abhängigkeiten: webauthn-swift 1.0.0-beta.1, Argon2Swift auf Branch `main` fixiert (siehe `docs/LIZENZEN.md`); npm-Lizenzen nicht von Lead geprüft.
- Codex hat nur die PWA geprüft; Docker/Compose (L2/L3a) und Lead-Verträge noch ohne Codex-Review.
- Nicht begonnen: OIDC, MCP, Zeittracking (Etappe 2+), Import/Export, Berichtsheft, KI, PWA-Manifest/Service Worker, native Apps (nur Startansicht).

## Umgebung

Swift 6.4, Node 26.5/npm 11.17, Docker 29.5.2 (Colima arm64, Datenpartition auf 40 GB vergrößert), Compose 5.3.1, Buildx 0.38,
Codex-Plugin 1.0.6 / CLI 0.162.1. `swift test` mit Standard-Buildsystem scheitert lokal an Codesign-Xattrs → `--build-system native`.
In Colima laufen fremde Projekte: nur `timetrack-dev-*` anfassen.

## Übergabe

Nächster Schritt: Etappe 2 (Zeittracking: Arbeitsmodelle, Abschnitte, Rundung, Konto) mit Vertrag zuerst; vorher amd64-Nachweis
und Codex-Review von Docker/Compose. Worktrees `../timetrack-backend-wt/{c1,c2,c3,l2,l3a}` sind gemergt und können mit
`git worktree remove` entfernt werden.
Keine Remotes, nichts veröffentlicht.
