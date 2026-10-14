# Erste Einrichtung auf diesem Mac

Diese Anleitung bereitet die Entwicklung durch Claude Code mit Claude-Agents und Codex über
das Claude-Codex-Plugin vor. Ziel: ungefähr 50 % der Implementierungsarbeit durch Codex.
Die Grundgerüste sind angelegt. Fachfunktionen, Datenbankkonfiguration und Container folgen.

## 1. Bereits geprüfter Stand

Prüfung am 13.10.2026, ohne Installation oder Änderung der Laufzeitumgebung:

| Bestandteil | Beobachtung |
| --- | --- |
| Mac | ARM64 |
| Colima, Docker, Claude Code, Codex, Node, Git | ausführbare Programme vorhanden |
| Swift | Swift 6.4 / Xcode 27 vorhanden |
| Docker-Kontext | `colima` ausgewählt |
| Docker Compose | Version 5.3.1 gemeldet |
| Docker Buildx | `docker buildx` nicht verfügbar |
| pnpm | nicht im geprüften PATH gefunden |
| Claude-Codex-Plugin | `codex@openai-codex`, Version 1.0.6, benutzerweit installiert |
| Docker-Daemon | nicht verifiziert: Socket-Zugriff in dieser Agent-Sitzung verweigert |

`colima status` meldete in dieser Sitzung „not running“. Wegen der eingeschränkten Umgebung
im normalen Terminal erneut prüfen, bevor daraus eine fehlende oder defekte Installation abgeleitet wird.
CLI-Präsenz bestätigt noch keine Anmeldung bei Claude/Codex. Keine Tokens oder Auth-Dateien ausgeben.

## 2. Projekt öffnen und Docker prüfen

Im normalen Terminal:

```sh
cd '<workspace>/timetrack-backend'
colima status
docker context ls
docker --context colima info
docker compose version
docker buildx version
```

Nur wenn das vorhandene Colima-Profil tatsächlich gestoppt ist:

```sh
colima start
```

Vorhandenes Profil und Ressourcen zunächst beibehalten. Kein Docker Desktop erforderlich.
Bei anders benanntem Colima-Profil den in `docker context ls` angezeigten lokalen Kontext verwenden.
Keinen Remote-/Produktionskontext für lokale Tests benutzen. Colima nicht zurücksetzen und keine
bestehenden Volumes löschen. Quelle: [Colima-Docker-Laufzeit](https://colima.run/docs/runtimes/).

## 3. Fehlende Entwicklungswerkzeuge ergänzen

Buildx wird für die späteren Images für `linux/arm64` und `linux/amd64` benötigt.
Falls weiterhin fehlend, über das vorhandene Homebrew installieren:

```sh
brew install docker-buildx
```

Falls Docker das Plugin danach nicht findet, gemäß Homebrew-Hinweis `cliPluginsExtraDirs` in
`~/.docker/config.json` ergänzen. Auf diesem Mac ist der erwartete Homebrew-Pfad
`/opt/homebrew/lib/docker/cli-plugins`; vor Verwendung mit `brew --prefix` prüfen.
Bestehende Konfiguration zusammenführen, nicht überschreiben und keine Registry-Zugangsdaten ausgeben.
Danach `docker buildx version` erneut prüfen.
Quelle: [Homebrew docker-buildx](https://formulae.brew.sh/formula/docker-buildx).

PWA verwendet das vorhandene Node 26.5.0 und npm 11.17.0; .node-version, packageManager und
package-lock.json halten den Stand fest. Keine zusätzliche globale pnpm-Installation erforderlich.
Node wird auch vom lokal installierten Codex-Plugin verwendet, bleibt aber außerhalb der App-Produktion.

Swift zuerst mit `swift --version` prüfen. Das Backend kann in einem Linux-Swift-Buildcontainer
entwickelt/getestet werden; Xcode für native Apple-Apps ist kein Startblocker für die PWA.
Den vollständigen Multi-Arch-Laufzeittest getrennt vom lokalen ARM64-Test dokumentieren.

## 4. Claude und Codex verbinden

Claude Code in diesem Ordner starten:

```sh
claude
```

In Claude Code:

```text
/codex:setup
```

Das installierte Plugin prüft die Codex-Bereitschaft. Falls nicht angemeldet, dem Login-Hinweis
folgen; das Plugin dokumentiert dafür `!codex login` innerhalb von Claude Code.
Ist der Slash-Befehl unbekannt, zuerst prüfen, ob das bereits installierte Plugin in dieser
Sitzung aktiviert ist; nicht einfach ein zweites Plugin installieren.

Lokal geprüfte Plugin-Quellen:

- `~/.claude/plugins/cache/openai-codex/codex/1.0.6/commands/setup.md`
- `~/.claude/plugins/cache/openai-codex/codex/1.0.6/commands/rescue.md`
- `~/.claude/plugins/cache/openai-codex/codex/1.0.6/agents/codex-rescue.md`

Für neue Implementierungspakete ist `/codex:rescue --fresh ...` vorgesehen, für Fortsetzung
`--resume`. Der Subagent `codex:codex-rescue` kann schreibende Aufgaben übernehmen; er ist
kein Skill. Claude soll die tatsächlich installierten Befehle lesen und keine Plugin-API erfinden.
Keine Modell-/Effort-Overrides nötig; vorhandene Einstellungen beibehalten.

## 5. Entwicklung starten

Den gesamten Textblock aus [CLAUDE_STARTPROMPT.md](CLAUDE_STARTPROMPT.md) in Claude Code einfügen.
Claude soll zunächst lokale Voraussetzungen prüfen, Arbeitspakete aufteilen und dann tatsächlich
implementieren. Nicht bei einer weiteren Planung stehen bleiben.

Die erste Runde soll einen ausführbaren, getesteten Stand der Projektgrundlage und Konten liefern.
Die technischen Durchstiche aus `docs/UMSETZUNG.md` priorisieren; geräteabhängige Tests und
spätere Funktionen dürfen nachgelagert werden und müssen als offen dokumentiert bleiben.

Claude initialisiert Git, sofern dieser Ordner weiterhin kein Repository ist, und legt vor
Parallelentwicklung einen Ausgangscommit an. Nutzerdateien erhalten, keinen Remote automatisch anlegen.
Anschließend Worktrees für parallele Schreibarbeit oder strikt getrennte Dateibereiche verwenden.

## 6. Lokale App-Umgebung, die Claude anlegen soll

- Eigenes Compose-Projekt, z. B. `timetrack-dev`, ohne Zugriff auf die bestehende Serverdatenbank.
- Separate lokale MariaDB mit passendem 12.3-Stand und persistiertem Entwicklungsvolume.
- SQLite als separater Test-/Einzelinstanzmodus, nicht als gemeinsame Datei mehrerer Replikate.
- Swift-Backend und PWA; Node-Entwicklungsserver nur im Entwicklungsprofil.
- Separates Produktionsprofil mit gebauter statischer PWA und ohne Node-Laufzeit.
- Lokale Konfiguration über ignorierte `.env`, daneben `.env.example` ohne echte Secrets.
- Optional lokale Mail-Testumgebung für E-Mail-Recovery, optional S3-Testdienst für Speicheradapter.
- Browseroberfläche und API möglichst unter einer Origin; stabile lokale WebAuthn-RP-ID dokumentieren.
- Für echte iPhone-/OAuth-Clienttests sichere erreichbare Testadresse gesondert vorsehen;
  `localhost` auf dem iPhone ist nicht dieser Mac. Keine Produktionsdomain ungefragt umkonfigurieren.

Claude soll konkrete Start-/Stopp-/Testbefehle erst nach Anlegen der Compose-Dateien ergänzen
und ausführen. Projektlokale Volumes für Daten, Caches getrennt; kein `down -v` als normaler Stopp.
Swarm bleibt das spätere Deploymentziel, lokal zunächst Compose. Kein `docker swarm init` erforderlich.

## 7. Arbeitsaufteilung und Nachweis

Claude koordiniert mehrere Agents. Codex implementiert ungefähr die Hälfte des geschätzten
Entwicklungsumfangs, nicht lediglich Reviews. Richtwert 40–60 % je größerem Meilenstein;
keine künstliche Zählung von Codezeilen oder Tokenverbrauch.

Claude aktualisiert den vorhandenen `docs/ARBEITSPLAN.md`: Paket-ID, Ziel, Umfangspunkte, Claude/Codex-Verantwortung,
Dateien/Worktree, Abhängigkeiten, Status und Abnahmebeleg. Pro Paket genau ein Schreibverantwortlicher.
Claude und Codex prüfen jeweils auch Ergebnisse der anderen Seite; Review allein zählt nicht als Umsetzung.
Gemeinsame Verträge, Migrationen und Lockfiles koordiniert ändern, nicht parallel überschreiben.

Zum ersten Meilenstein gehören dokumentierte Builds/Tests, ein lokaler Browserdurchlauf,
ein echter Codex-Implementierungsbeitrag und eine ehrliche Liste noch nicht geprüfter Integrationen.
Es muss nicht bereits der vollständige Funktionsumfang aller späteren Etappen fertig sein.

## 8. Wiederaufnahme ohne alte Session und IDEs

Das Repository enthält den gesamten dauerhaften Wissensstand. Jede neue Session beginnt mit
`AGENTS.md`, `docs/STATUS.md` und `docs/ARBEITSPLAN.md`; Checkpoints und Übergaben folgen
[ENTWICKLUNGSABLAUF.md](docs/ENTWICKLUNGSABLAUF.md). Keine alte Session-ID erforderlich.
Vor Sessionende die nächste konkrete Aktion dokumentieren und vorhandene Arbeit sichern.

PWA in PhpStorm, native Apps in Xcode. VS Code ist ausdrücklich ausgeschlossen.
Backend beschlossen: PhpStorm mit Noctule (noch ohne integriertes Swift-Debugging).
Drei getrennte Repos mit Backend als Hauptrepo: siehe [REPOSITORIES.md](docs/REPOSITORIES.md).
Linux-Tests über IDE-unabhängige Docker-/Compose-Befehle in Colima.
Details und Quellen: [IDE.md](docs/IDE.md). PhpStorm öffnet jeweils den Projektordner; Apple hat ein generiertes Xcode-Projekt.

## 9. Vorhandene Grundgerüste starten

Im Backend-Hauptrepo:

```sh
swift build
swift run App serve --hostname 127.0.0.1 --port 8080
```

GET http://127.0.0.1:8080/health liefert Prozess-Liveness, noch keine DB-Readiness.
Beenden mit Ctrl-C. Keine Datenbank oder Secrets für dieses Grundgerüst erforderlich.

Im benachbarten timetrack-pwa:

```sh
npm ci
npm run check
npm run build
npm run dev
```

Der Build erzeugt statische Dateien in build/. Installation als PWA, Service Worker,
API-Anbindung und Authentifizierung sind noch nicht implementiert.

Im Xcode/timetrack-apple:

```sh
xcodegen generate
open Timetrack.xcodeproj
xcodebuild -project Timetrack.xcodeproj -scheme TimetrackMac -configuration Debug -derivedDataPath /tmp/timetrack-derived-data CODE_SIGNING_ALLOWED=NO build
```

macOS ist erstes Ziel; iOS/iPadOS-Gerätetests und watchOS folgen später.
Produkt-Bundle-IDs sind vorläufig. Geräteinstallation erfordert eigene Signing-Einrichtung.

## 10. Lauffähiger Stand (14.10.2026)

Alle Befehle im jeweiligen Repo-Hauptordner.

```sh
# Dev-Datenbank (MariaDB 12.3, 127.0.0.1:13306, Volume timetrack-dev-db; Stopp ohne Datenverlust)
scripts/dev-env.sh init && scripts/dev-env.sh up     # down: scripts/dev-env.sh down  (nie -v)
# Backend-Tests (SQLite immer; MariaDB mit Exporten)
eval "$(scripts/dev-env.sh test-db | grep ^export)"   # Testdatenbank timetrack_test einmalig anlegen
swift test --build-system native
# Backend lokal (SQLite) + erster Admin
SQLITE_PATH=/tmp/tt.sqlite AUTO_MIGRATE=true swift run --build-system native App bootstrap-admin
SQLITE_PATH=/tmp/tt.sqlite AUTO_MIGRATE=true swift run --build-system native App serve --hostname 127.0.0.1 --port 18080
# Container (arm64): scripts/dev-env.sh up-app | up-sqlite | up-mail
# PWA (Repo timetrack-pwa): npm ci; npm run dev (Proxy auf :18080, http://localhost:5173), npm run dev:mock, npm test, npm run test:e2e
```

WebAuthn lokal: immer `http://localhost:<port>` (RP-ID `localhost`), nicht `127.0.0.1`.
Platz in Colima prüfen: `colima ssh -- df -h /var/lib/docker`. Lizenzen: `docs/LIZENZEN.md`. Details je Paket: `docs/handoffs/`.
