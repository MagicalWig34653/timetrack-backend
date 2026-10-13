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

## Einrichtung am 13.10.2026

Drei lokale Grundgerüste eingerichtet, Konzeptdokumente ins Backend übernommen.
Backend: SwiftPM/Vapor, Fluent-Treiber als Abhängigkeiten; DB-Anbindung folgt.
PWA: SvelteKit/TypeScript, Static Adapter, Tailwind und shadcn-svelte.
Apple: reproduzierbares XcodeGen-Projekt mit macOS und iOS/iPadOS; watchOS folgt später.
Keine Remotes, keine Veröffentlichung. Prüfstand steht ausschließlich in STATUS.md.

Den Backend-Ordner in PhpStorm öffnen und Noctule verwenden; PWA separat in PhpStorm öffnen.
Apple-Projekt: Timetrack.xcodeproj. IDE-Nutzerdateien werden nicht versioniert.
Der Brainstorm-Ordner bleibt als historische Vorbereitung erhalten und ist nicht mehr kanonisch.
