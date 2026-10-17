# Drei Repositories – Einrichtungsauftrag

Bestätigt am 13.10.2026: getrennte Repos; Backend ist Hauptrepo, aus dem der Nutzer agiert.
Ordnernamen unten sind zweckmäßige Vorschläge. Der frühere Monorepo-Vorschlag ist ersetzt.

| Repository | Ziel | IDE |
| --- | --- | --- |
| timetrack-backend (Hauptrepo) | <workspace>/timetrack-backend | PhpStorm + Noctule |
| timetrack-pwa | <workspace>/timetrack-pwa | PhpStorm |
| timetrack-apple | <workspace>/timetrack-apple | Xcode |

## Kanonisches Wissen

Backend führt globale Konzepte, ADRs, Status/Arbeitsplan, Startprompt und versionierte API-Verträge.
Clients führen eigene Agent-Anweisungen, lokalen Status, Tests und Einrichtung; globale Dokumente
referenzieren, nicht unabhängig duplizieren. Spätere Client-Vertragskopien mit Herkunft/Version versehen.
Cross-Repo-Aufträge nennen Repos, Branches/Commits, erlaubte Dateien und Integrationsabnahme.
Keine Hosting-URL erfinden. Schreibrechte müssen alle betroffenen Workspaces umfassen.

## Stand der Repositories (17.10.2026)

Alle drei Repositories sind seit dem 17.10.2026 öffentlich auf GitHub (AGPL-3.0-only); `main` ist der Hauptzweig. Prüfstand ausschließlich in `STATUS.md`.

| Repository | URL | Inhalt und Stand |
| --- | --- | --- |
| timetrack-backend | https://github.com/MagicalWig34653/timetrack-backend | SwiftPM/Vapor/Fluent (MariaDB, SQLite), Pakete `TimetrackKit` und `App`; umgesetzt bis Etappe 4 und Betrieb (siehe `UMSETZUNG.md`). Führt `contracts/openapi.yaml`, `compose.yaml`, `Dockerfile`, `scripts/`, `deploy/`, die Website `site/` und alle globalen Dokumente. |
| timetrack-pwa | https://github.com/MagicalWig34653/timetrack-pwa | SvelteKit (statischer Adapter), TypeScript, Tailwind, shadcn-svelte-Stil; alle Seiten der Etappen 1–4, Service Worker und Manifest; eigene Tests (Vitest, Playwright) und eigener Status im Repo. Wird als statischer Build vom Backend ausgeliefert. |
| timetrack-apple | https://github.com/MagicalWig34653/timetrack-apple | XcodeGen-Projekt mit macOS-, iOS/iPadOS- und watchOS-App, Swift-Paketen `TimetrackCore` und `TimetrackDesign`, Widgets (Etappe 5, A1–A8); eigener Status im Repo. |

Lokale Anordnung (frei wählbar, hier generisch): `<workspace>/timetrack-backend`, `<workspace>/timetrack-pwa` und `<workspace>/timetrack-apple` nebeneinander; Verweise wie `../timetrack-backend` in den Client-Repos setzen das voraus; liegt der Apple-Ordner an anderer Stelle, den Pfad zum Backend in der eigenen Umgebung anpassen. Den Backend-Ordner in PhpStorm mit Noctule öffnen, die PWA separat in PhpStorm; Apple-Projekt: `Timetrack.xcodeproj` (aus `project.yml` erzeugt). IDE-Nutzerdateien werden nicht versioniert.
Parallele Schreiber arbeiten in eigenen Worktrees (`<workspace>/timetrack-backend-wt/<paket>`, `timetrack-pwa-wt/<paket>`), Regeln in `ENTWICKLUNGSABLAUF.md`. Das Backend enthält die Konzeptdokumente; Vertragskopien in den Clients tragen Herkunft/Version.

### Veröffentlichung und Historienbereinigung

Vor der Veröffentlichung wurde die Historie aller drei Repos von persönlichen Angaben bereinigt (umgeschrieben, alle Hashes neu). Die bereinigten Repos wurden mit einem Austauschskript anstelle der alten Arbeitskopien eingesetzt; die unbereinigten Originale bleiben als lokale Sicherungen außerhalb der Repos (`_old-repos/`, `_repo-backups-before-scrub/` mit Git-Bundles, `_publish/` mit dem Austauschskript, jeweils neben den Arbeitsordnern). Sie gehören nie in ein öffentliches Repo. Commit-Hashes in älteren Handoffs sind seitdem ungültig.

## Apple-Kennungen (Platzhalter in diesem Repo)

Im Backend-Repo stehen Platzhalter: Team-ID `ABCDE12345`, Bundle-ID `com.example.timetrack` (watchOS `com.example.timetrack.watchkitapp`), Domain `timetrack.example.org`; App-ID für `apple-app-site-association`: `ABCDE12345.com.example.timetrack`. Die tatsächlichen Werte stehen im Apple-Repo (`project.yml`) und in der privaten Betreiber-Konfiguration. Siehe `docs/README.md`, Abschnitt „Namensgebung und Kennungen“, und ADR-0015.
