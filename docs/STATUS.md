# Aktueller Projektstand

Stand: 14.10.2026. Etappe 0/1 in Arbeit; Backend ist Hauptrepo (Branch `main`).

## Integriert und geprüft

- **C1 (Codex)**: Bibliothek `TimetrackKit` + dünner `App`, typisierte Konfiguration, Fluent-Migrationen/Modelle für
  Konten, Passkeys, Sitzungen, Einladungen, Challenges, Recovery, Rate-Limits; `GET /health`, `GET /ready`;
  `App migrate`; atomarer Einmalverbrauch (`SingleUse`). Details: `docs/handoffs/C1.md`.
  Geprüft (Lead, 14.10.): `swift test --build-system native` → 7 Tests, 0 Fehler, inkl. MariaDB 12.3.3 (Dev-Container)
  und SQLite (Speicher/Datei), Konkurrenztest Einmalverbrauch.
- **L2 (Claude)**: `compose.yaml` (Projekt `timetrack-dev`, MariaDB 12.3 auf 127.0.0.1:13306, Profile app/sqlite/mail),
  `.env.example`, `scripts/dev-env.sh`, Dockerfile. DB-Start, Persistenz über down/up und Zugriff verifiziert.
  **Nicht verifiziert**: alle Image-Builds (arm64/amd64), Container-Start des Backends – Colima-Datenpartition voll
  (20 GiB, ~243 MB frei). Details: `docs/handoffs/L2.md`.
- **L1 (Claude, Repo timetrack-pwa)**: SPA-Oberfläche (Einladung/Registrierung, Login, Recovery, Passkey-/Recovery-/
  Sitzungsverwaltung, Admin-Einladungen), typisierter API-Client, WebAuthn-Helfer, Mock-Modus.
  `npm run check`, 31 Vitest-Tests und `npm run build` grün; gegen Mock im Headless-Browser angesehen.
  **Nicht verifiziert**: echtes Backend, echter Passkey, Smartphone-Breite/Dark Mode.
- Vertrag `contracts/openapi.yaml` v0.1.0 (Auth, Passkeys, Recovery, Einladungen) mit Fehlercodes und Lead-Entscheidungen.

## In Arbeit

- **C2 (Codex)**: Sitzungen/CSRF, Einladung/Konten, WebAuthn, Recovery, Admin-API, statische PWA-Auslieferung.
  Worktree `../timetrack-backend-wt/c2`, Branch `c2-auth-services`, Basis `9608d9e`. Noch nichts integriert.

## Offen

- L3: Image-Builds (arm64, amd64 getrennt nachweisen), Browser-E2E mit virtuellem WebAuthn-Authenticator.
- Blocker Nutzeraktion: Colima-Speicherplatz (siehe EINRICHTUNG.md, Abschnitt Docker-Speicher).
- Dependency-Lizenzprüfung (neu: webauthn-swift Apache-2.0, Argon2Swift MIT; Argon2Swift auf Branch `main` fixiert,
  da Abhängigkeit `phc-winner-argon2` unstabil – bei Updates prüfen), OIDC, MCP, Zeittracking und alle späteren Etappen.
- Native Apps: nur Startansicht (XcodeGen-Projekt); iOS-Build/Gerätetests/watchOS offen.
- E-Mail-Versand real, Rate-Limit-Feintuning, PWA-Manifest/Service Worker.

## Umgebung (14.10.2026)

Swift 6.4, Node 26.5/npm 11.17, Docker 29.5.2 (Colima, ARM64), Compose 5.3.1, Buildx 0.38 (jetzt vorhanden;
`cliPluginsExtraDirs` in `~/.docker/config.json` ergänzt). Codex-Plugin 1.0.6, Codex CLI 0.162.1, Login aktiv.
`swift test` mit Standard-Buildsystem scheitert lokal an Codesign-Xattrs im .xctest; `--build-system native` nutzen.
In Colima laufen fremde Projekte (Host-Ports 3306/3310/5432/9090/82xx belegt) – nur `timetrack-dev-*` anfassen.

## Übergabe

Nächster Schritt: C2 abnehmen (Diff lesen, Tests inkl. MariaDB laufen lassen: `eval "$(scripts/dev-env.sh test-db | grep ^export)"`,
Testdatenbank `timetrack_test` im Dev-Container ggf. anlegen), nach `main` mergen, Platz in Colima schaffen, dann L3.
Keine Remotes, nichts veröffentlicht.
