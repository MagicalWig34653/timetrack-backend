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

## Stand der Repositories (15.10.2026)

Alle drei Repositories sind lokale Git-Repos ohne Remote; nichts ist veröffentlicht. Prüfstand ausschließlich in `STATUS.md`.

| Repository | Inhalt und Stand |
| --- | --- |
| timetrack-backend | SwiftPM/Vapor/Fluent (MariaDB, SQLite), Pakete `TimetrackKit` und `App`; fachlich umgesetzt bis Etappe 4 (siehe `UMSETZUNG.md`). Führt `contracts/openapi.yaml`, `compose.yaml`, `Dockerfile`, `scripts/`, `deploy/` und alle globalen Dokumente. |
| timetrack-pwa | SvelteKit (statischer Adapter), TypeScript, Tailwind, shadcn-svelte-Stil; alle Seiten der Etappen 1–4, Service Worker und Manifest; eigene Tests (Vitest, Playwright) und eigener Status im Repo. Wird als statischer Build vom Backend ausgeliefert. |
| timetrack-apple | nur reproduzierbares XcodeGen-Projekt (`project.yml`, macOS und iOS/iPadOS); keine fachliche App, watchOS folgt später (Etappe 5). |

Das Backend enthält die Konzeptdokumente; Vertragskopien in den Clients tragen Herkunft/Version. Den Backend-Ordner in
PhpStorm mit Noctule öffnen, die PWA separat in PhpStorm; Apple-Projekt: `Timetrack.xcodeproj`. IDE-Nutzerdateien werden
nicht versioniert. Der Brainstorm-Ordner bleibt als historische Vorbereitung erhalten und ist nicht mehr kanonisch.
Parallele Schreiber arbeiten in eigenen Worktrees (`../timetrack-backend-wt/<paket>`, `../timetrack-pwa-wt/<paket>`),
Regeln in `ENTWICKLUNGSABLAUF.md`.

## Apple-Kennungen (16.10.2026, vom Nutzer)

Team-ID `ABCDE12345` (kein Geheimnis); Bundle-ID `com.example.timetrack` für iOS/iPadOS und macOS (Universal Purchase), watchOS-App `com.example.timetrack.watchkitapp`. App-ID für `apple-app-site-association`: `ABCDE12345.com.example.timetrack`. Details: ADR-0015 (Entwurf durch Paket A1).
