# Aktueller Projektstand

Stand: 13.10.2026. Drei lokale Git-Repos auf main eingerichtet; Backend ist Hauptrepo.
Die Grundgerüste sind ausführbar, Fachfunktionen noch nicht implementiert.

## Vorhanden

- Kanonische Konzepte, ADRs, Agent-Einstiege, Arbeitsplan, Einrichtung und Claude-Startprompt hier.
- SwiftPM/Vapor-Backend: GET /health als reine Prozess-Liveness.
- Fluent sowie MariaDB-/SQLite-Treiber aufgelöst in Package.resolved; noch keine DB-Konfiguration/Migrationen.
- SvelteKit 3 / Svelte 5 / TypeScript / Tailwind 4 / shadcn-svelte mit Static Adapter,
  Startseite und Badge; npm-Lockfile und lokale Werkzeugversionen im PWA-Repo.
- XcodeGen-Projekt und generiertes Timetrack.xcodeproj mit SwiftUI-Grundansicht,
  Targets TimetrackMac und TimetrackIOS (iPhone/iPad), OS 27.
- AGPL-3.0-only-Lizenztext in allen drei Repos. Keine Git-Remotes.
- contracts/openapi.yaml beschreibt ausschließlich den vorhandenen Health-Endpunkt.

## Prüfungen am 13.10.2026

- Schreib-/Lese-/Löschzugriff in beiden Ziel-Elternordnern erfolgreich geprüft.
- Backend: swift build erfolgreich mit Swift 6.4 auf macOS ARM64.
- Backend kurz auf 127.0.0.1:18089 gestartet; GET /health → 200 und {"status":"ok"}; danach beendet.
- PWA: npm run check ohne Fehler/Warnungen; npm run build erzeugt statische Dateien in build/.
- Apple: xcodegen generate erfolgreich; xcodebuild für TimetrackMac mit CODE_SIGNING_ALLOWED=NO erfolgreich.
- npm-/Swift-Downloads und lokaler HTTP-Test benötigten erweiterte Sandboxfreigabe.
  Kein Projektfehler: eingeschränktes Netzwerk meldete ENOTFOUND, Socket-bind war nicht erlaubt.

## Offen und Grenzen

Keine DB-/Auth-/Kontentrennungs-/Fachtests, keine Browserprüfung oder API-Anbindung der Clients.
PWA-Installation, Manifest/Service Worker, Push und Offline-Verhalten noch nicht implementiert.
MariaDB/SQLite-Anbindung und Transaktionen, Passkeys/Recovery/OIDC/Einladungen, Zeittracking,
MCP, Import/Export, Kalender, Berichtsheft und KI sind noch geplant.
Native App nur Startansicht: keine Funktionalität, keine Gerätesignierung, kein watchOS-Target.
iOS/iPadOS-Build und Geräteprüfung offen. Linux amd64/arm64 und Docker-Images noch nicht geprüft.
Compose/Swarm-Dateien fehlen; Colima/Daemon wurde bei diesem Setup nicht erneut geprüft.
Frühere Sitzung: Socket-Zugriff verweigert, Colima meldete not running; Buildx nicht verfügbar.
Vollständige Dependency-Lizenzprüfung offen. Noctule/IDE-Bedienung nicht automatisch geprüft.

## Übergabe

Diese Vorbereitung wurde direkt durch Codex erledigt, nicht über einen Claude-Plugin-Auftrag.
Noch kein tatsächlicher Claude/Codex-Anteil der fachlichen Meilensteine messbar.
Keine Hintergrunddienste oder Agent-Aufträge laufen aus diesem Setup weiter; keine Migrationen/Datenänderungen.
Die Grundgerüste sind in Ausgangscommits auf main gesichert; Commit-IDs per git log -1 je Repo.
Brainstorm ist archivierte Vorbereitung. Pfade: REPOSITORIES.md. Clients haben eigene lokale Statusdateien.

Nächster Schritt: Claude im Backend-Hauptrepo starten, EINRICHTUNG.md und CLAUDE_STARTPROMPT.md
verwenden. Zuerst Plugin/Colima prüfen, Fachverträge definieren und Pakete C1/L1/L2 konkret aufteilen.
C1 konfiguriert DB-Auswahl und erste Migrationen; L2 stellt den lokalen Container-Durchstich her.
Offene Produktdetails: KONZEPT.md Abschnitt 9. Keine bestätigten Grundentscheidungen neu aufrollen.
