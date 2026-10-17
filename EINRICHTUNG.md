# Einrichtung und Startbefehle

Stand: 17.10.2026. Diese Anleitung führt von einem frischen Checkout zu einem laufenden Backend, einer
Entwicklungsdatenbank, Tests und der PWA. Den tatsächlich geprüften Stand und offene Punkte führt
[docs/STATUS.md](docs/STATUS.md); Testdienste und Ports im Detail: [docs/TESTUMGEBUNGEN.md](docs/TESTUMGEBUNGEN.md).
Alle Befehle laufen im jeweiligen Repo-Hauptordner (Backend: dieses Repository, PWA: `../timetrack-pwa`).

## 1. Umgebung

Versionen laut `docs/STATUS.md` (Stand 17.10.2026, vom Lead gemeldet): Swift 6.4 (Xcode 27), Node 26.5 / npm 11.17,
Docker 29.5.2 über Colima (arm64), Compose 5.3.1, Buildx 0.38. Kein pnpm, kein Docker Desktop. Das Claude-Codex-Plugin
`codex@openai-codex` war am 13.10.2026 in Version 1.0.6 installiert (nicht erneut geprüft).

`swift test` und `swift run` nur mit `--build-system native` (der Standard-Build scheitert an Codesign-Xattrs).
In Colima laufen auch fremde Projekte: nur Ressourcen mit Präfix `timetrack-dev` anfassen.

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

## 5. Schnellstart

```sh
# 5.1 Entwicklungsdatenbank (MariaDB 12.3, 127.0.0.1:13306, Volume timetrack-dev-db)
scripts/dev-env.sh init            # erzeugt .env mit Zufallspasswörtern (gitignoriert); bestehende .env bleibt unberührt
scripts/dev-env.sh up              # startet MariaDB und wartet auf "healthy"
scripts/dev-env.sh down            # Stopp ohne Datenverlust (nie -v verwenden)
scripts/dev-env.sh status          # Container, Ports, Volumes

# 5.2 Backend lokal mit SQLite (kein Docker nötig), erster Admin
SQLITE_PATH=/tmp/tt.sqlite AUTO_MIGRATE=true swift run --build-system native App bootstrap-admin
SQLITE_PATH=/tmp/tt.sqlite AUTO_MIGRATE=true swift run --build-system native App serve --hostname 127.0.0.1 --port 18080
# bootstrap-admin gibt einen einmaligen Einladungslink (<PUBLIC_BASE_URL>/invite/<token>) für die Admin-Rolle aus und
# funktioniert nur, solange noch kein Konto existiert. Dann http://localhost:18080 öffnen (PWA nur, wenn PWA_STATIC_DIR gesetzt ist).

# 5.3 Backend in Containern (arm64): Backend + MariaDB bzw. SQLite-Einzelinstanz
scripts/dev-env.sh up-app          # baut das Image und startet db + backend (Profil app), Port 18080
scripts/dev-env.sh up-sqlite       # nur Backend mit SQLite im Volume timetrack-dev-sqlite (Profil sqlite)
docker compose --project-name timetrack-dev --profile app run --rm -T backend bootstrap-admin
# im laufenden Container per exec nur mit Einstiegspunkt: docker exec -it <container> /app/docker-entrypoint.sh bootstrap-admin
scripts/dev-env.sh build-multiarch # amd64+arm64 per buildx als OCI-Archiv, nicht gepusht (amd64 nur emuliert, QEMU_LIMIT=1; siehe unten)
```

WebAuthn lokal immer über `http://localhost:<port>` (RP-ID `localhost`), nicht über `127.0.0.1`.
`/health` liefert Prozess-Liveness, `/ready` prüft die Datenbank.

### Backend-Tests

```sh
swift test --build-system native                       # SQLite-Läufe; MariaDB-Varianten werden übersprungen
# mit MariaDB (frische, eigene Testdatenbank; parallele Agents je eigene Datenbank per MARIADB_TEST_DB):
scripts/dev-env.sh up
eval "$(scripts/dev-env.sh test-db | grep ^export)"    # MARIADB_TEST_HOST/PORT/USER/PASSWORD
export MARIADB_TEST_DB=timetrack_test                  # Standardname, falls nicht gesetzt
docker compose --project-name timetrack-dev exec db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS $0" ' "$MARIADB_TEST_DB"
swift test --build-system native
# Linux-Compile des Backends bei größeren Änderungen:
docker build --target build .
```

Die Datenbank muss vor dem Lauf existieren; der Anlege-Befehl ist aus `compose.yaml` abgeleitet und nicht erneut
ausgeführt (die Handoffs C18/C19 legen die Datenbank manuell an und löschen sie danach). Letzter dokumentierter
Lauf des Leads: 193 Tests, 0 Fehler, mit frischer MariaDB-Testdatenbank 0 übersprungen (`docs/STATUS.md`).
### Vertragstest (OpenAPI)

`swift test` enthält Tests unter `Tests/TimetrackKitTests/Contract/`: Routenabgleich Implementierung ↔ `contracts/openapi.yaml` und Antwortformen
ausgewählter Endpunkte (eigener JSON-Schema-Validator). Die Tests lesen eine JSON-Kopie des Vertrags
(`Tests/TimetrackKitTests/Contract/openapi.contract.json`) und scheitern mit Hinweis, wenn sie veraltet ist. Nach jeder Vertragsänderung:
`scripts/contract-json.sh` (Python 3 mit PyYAML) und die Kopie mit committen. Optional: `npx @redocly/cli@1.34.5 lint contracts/openapi.yaml`
und `npx openapi-typescript@7.9.1 contracts/openapi.yaml -o /tmp/types.ts` (Netzwerk nötig).

### Alles prüfen: `scripts/check-all.sh`

Ein Befehl für den lokalen Gesamtlauf: `swift build --build-system native`, `swift test` auf SQLite, optional MariaDB (nur wenn
`MARIADB_TEST_HOST` gesetzt ist, Voraussetzung wie oben), Parsen von `contracts/openapi.yaml` (OpenAPI 3.x, Version, doppelte `operationId`)
und der YAML-Dateien unter `deploy/`, `bash -n` und `shellcheck` (falls installiert) für `scripts/`, `docker compose config` (alle Profile) und
`docker stack config` für `deploy/swarm/stack.yaml` (nichts wird gestartet oder deployt). Am Ende eine PASS/FAIL/SKIP-Tabelle; Exit-Code 1 bei einem Fehler.

```sh
scripts/check-all.sh                 # alles (Swift und Docker nötig; fehlende Werkzeuge ergeben SKIP)
scripts/check-all.sh --fast          # nur statische Prüfungen (YAML, Shell, Compose/Stack), ohne Build und Tests
scripts/check-all.sh --with-restore  # zusätzlich scripts/test-restore.sh (Dev-MariaDB-Container, Port 18150/18151)
```

### Backup, Restore und Container-Nachweise

Verfahren, Archivaufbau und Grenzen: [docs/BETRIEB.md](docs/BETRIEB.md). Kurzform:

```sh
scripts/backup.sh  --driver sqlite  --sqlite-path /pfad/timetrack.sqlite --local-files /pfad/files --out /backups
scripts/restore.sh --from /backups/timetrack-backup-<UTC> --sqlite-path /pfad/timetrack.sqlite --files-target /pfad/files
scripts/test-restore.sh [sqlite|mariadb|all]   # Beweislauf mit Wegwerfdaten (braucht .build/debug/App und den Dev-DB-Container)
docker build -t timetrack-dev-b3-backend:test . && scripts/test-image-smoke.sh   # Produktions-Container-Verhalten (read-only, *_FILE-Secrets)
```

### amd64 und Multi-Arch

`scripts/dev-env.sh build-multiarch` baut amd64 und arm64 (OCI-Archiv, nicht gepusht). Auf dem arm64-Mac läuft amd64 unter QEMU;
`QEMU_LIMIT=1` (Standard im Skript, Docker-Build-Argument) begrenzt SwiftPM auf wenige CPUs, sonst stürzt es unter Emulation ab. Nur amd64 geladen:
`docker buildx build --platform linux/amd64 --build-arg QEMU_LIMIT=1 -t timetrack-dev-b3-amd64 --load .` (danach `docker rmi timetrack-dev-b3-amd64`).
Ergebnis und Dauer: docs/BETRIEB.md, Abschnitt 7, und `docs/handoffs/B3.md`.

### PWA (Repo timetrack-pwa)

```sh
npm ci
npm run check            # svelte-check + tsc für den Service Worker
npm run build            # statische Dateien nach build/ (adapter-static)
npm run dev              # Vite-Dev-Server http://localhost:5173, Proxy auf das Backend :18080
npm run dev:mock         # Dev-Server mit Mock-Backend (VITE_MOCK=1), kein Backend nötig
npm test                 # Vitest (Unit)
npm run test:e2e:mock    # Playwright gegen das Mock-Backend
npm run test:e2e         # baut die PWA, Playwright gegen echte Wegwerf-Backends (Ports 18090 ff., virtueller Passkey)
npm run test:e2e:pwa     # baut die PWA, Spec-Satz für den Produktionsbuild (Manifest, Service Worker)
```

Quelle: `package.json` des PWA-Repos; Details und Voraussetzungen (z. B. gebautes Backend für die Echt-E2E) stehen dort.
Image mit eingebauter PWA lokal bauen (Produktionsweg, Node nur im Build):
`docker build --build-context pwa-src=../timetrack-pwa -t timetrack-backend:local .` (optional `--build-arg PWA_REVISION=$(git -C ../timetrack-pwa rev-parse HEAD)`).
Ohne `--build-context` entsteht wie bisher ein Image mit leerem `/srv/pwa`.
Die PWA wird produktiv nicht mit Node betrieben: das Backend liefert `build/` über `PWA_STATIC_DIR` aus; im Container
über `PWA_STATIC_HOST_DIR` (Standard `./deploy/pwa-empty`, Beispiel `../timetrack-pwa/build`).

### Xcode/timetrack-apple

Das Apple-Projekt wird mit XcodeGen erzeugt (`project.yml`); es enthält die macOS-, iOS/iPadOS- und watchOS-App samt Widgets (Pakete A1–A8, Etappe 5). Test-, Build- und TestFlight-Befehle: `timetrack-apple/docs/STATUS.md` und `scripts/testflight.sh` dort.

```sh
xcodegen generate
xcodebuild -project Timetrack.xcodeproj -scheme TimetrackMac -configuration Debug -derivedDataPath /tmp/timetrack-derived-data CODE_SIGNING_ALLOWED=NO build
```

## 6. Konfiguration (Umgebungsvariablen)

Gelesen in `Sources/TimetrackKit/Configuration.swift` und den Modulen; Vorlage `.env.example` (Compose reicht sie durch).
Nie ein echtes `.env` committen. Ungültige Werte brechen den Start mit klarer Meldung ab.

| Variable | Standard im Code | Bedeutung |
| --- | --- | --- |
| `DATABASE_DRIVER` | `sqlite` | `mariadb` oder `sqlite` |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER` | `127.0.0.1`, `3306`, `timetrack`, `timetrack` | MariaDB-Verbindung |
| `DB_PASSWORD` | – | bei `mariadb` ausdrücklich zu setzen (lokal darf er leer sein) |
| `DB_TLS` | `required` | `off` nur für lokale Entwicklung |
| `SQLITE_PATH` | `timetrack.sqlite` | Datei bei `sqlite`; nur eine Instanz, nie zwischen Replikaten teilen |
| `AUTO_MIGRATE` | `false` | `true` migriert beim Start; Compose/`.env.example` setzen `true` |
| `WEBAUTHN_RP_ID`, `WEBAUTHN_RP_NAME` | `localhost`, `Timetrack` | RP-ID als Kleinbuchstaben-Hostname; Wechsel entwertet vorhandene Passkeys |
| `WEBAUTHN_ORIGIN`, `PUBLIC_BASE_URL` | `http://localhost:18080` | HTTPS außer auf Loopback, ohne Pfad/Slash; Host muss zur RP-ID passen |
| `APPLE_APP_IDS` | leer | Kommagetrennt `<TeamID>.<BundleID>` (z. B. `ABCDE12345.com.example.timetrack`); Leerstellen/leere Einträge werden ignoriert, ungültiges Format ist ein Startfehler. Leer: `/.well-known/apple-app-site-association` antwortet 404, sonst `{"webcredentials":{"apps":[...]}}`. Native Passkeys melden den Origin `https://<RP-ID>` (ohne Port); das Backend akzeptiert ihn zusätzlich zu `WEBAUTHN_ORIGIN`, sofern die RP-ID eine echte Domain (mit Punkt) ist (ADR-0015) |
| `SESSION_TTL_HOURS` | `720` | Compose/`.env.example` setzen `336` |
| `PWA_STATIC_DIR` | `/srv/pwa` | Verzeichnis der gebauten PWA |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_TLS`, `SMTP_FROM`, `SMTP_FROM_NAME`, `SMTP_USER`, `SMTP_PASSWORD` | Port `587`, TLS `starttls` | E-Mail-Recovery; ohne `SMTP_HOST` ist sie nicht wählbar. `SMTP_TLS`: `starttls`, `implicit`, `off` |
| `OIDC_ISSUER`, `OIDC_CLIENT_ID` (+ `OIDC_CLIENT_SECRET`, `OIDC_NAME`, `OIDC_SCOPES`) | aus | optionales OIDC (ADR-0007); Issuer und Client-ID nur zusammen |
| `STORAGE_SECRET_KEY` | – | Base64 von 32 Zufallsbytes; verschlüsselt S3-Secrets. Ohne ihn wird S3-Konfiguration abgelehnt; Verlust macht gespeicherte Secrets unbrauchbar |
| `NOTIFICATIONS_ENABLED` | `true` | `false` schaltet den Erinnerungs-Runner ab (Liste und REST bleiben) |
| `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` | – | Web Push; beide nötig, sonst `available:false` |
| `PUSH_ALLOWED_HOSTS` | Standard-Allowlist (ADR-0011) | kommagetrennt, **ersetzt** die Standardliste (`fcm.googleapis.com`, `*.push.services.mozilla.com`, `*.notify.windows.com`, `web.push.apple.com`, `*.push.apple.com`); `*.` erlaubt Subdomains, nicht die Hauptdomain. Getesteter Vorschlag mit je einem echten Muster pro Dienst siehe unten |
| `DB_POOL_CONNECTIONS_PER_LOOP` | `1` | MariaDB: Verbindungen pro Event-Loop (1 bis 8). Bei vielen Kernen und mehreren Replikaten summiert sich das (Kerne × Wert × Replikate); `max_connections` und `MAX_USER_CONNECTIONS` der Datenbank müssen reichen. |
| `DB_POOL_TIMEOUT_SECONDS` | `10` | MariaDB: Wartezeit auf eine freie Verbindung (1 bis 120). |
| `DB_KEEPALIVE_SECONDS` | `45` | MariaDB: Ping-Intervall, hält Leerlaufverbindungen am Leben (0 = aus). |
| `MAINTENANCE_INTERVAL_MINUTES` | `60` | Abstand des periodischen Aufräumjobs in Minuten (0 bis 10080); `0` schaltet ihn ab. Der CLI-Befehl `maintenance` läuft unabhängig davon (ADR-0017) |
| `MCP_AUDIT_RETENTION_DAYS` | `90` | Aufbewahrung der `mcp_audit`-Zeilen in Tagen (1 bis 3650) |
| `IMPORT_JOB_TIMEOUT_HOURS` | `168` | offene Importe (hochgeladen/zugeordnet) älter als dies werden verworfen (1 bis 8760) |
| `STORAGE_ORPHAN_GRACE_HOURS` | `168` | Karenzzeit, bevor verwaiste Objekte im lokalen Speicher gelöscht werden (1 bis 8760) |
| `TRUSTED_PROXY_CIDRS` | leer | Kommagetrennt IPv4-/IPv6-Adressen oder CIDR-Netze der Reverse Proxys (z. B. `172.18.0.0/16,fd00::/8`). Nur wenn die Socket-Gegenstelle darin liegt, wird die Client-Adresse aus dem Forwarded-Header gelesen (ADR-0018). Leer: niemand vertrauenswürdig, Header wirkungslos. Ungültiger Eintrag ist ein Startfehler |
| `TRUSTED_PROXY_HEADER` | `X-Forwarded-For` | `X-Forwarded-For` oder `X-Real-IP` (Groß-/Kleinschreibung egal); anderes ist ein Startfehler |
| `MODULES_DISABLED` | – | **geplant** (ADR-0012, Paket C20, noch nicht im Code): kommagetrennt, z. B. `reports,mcp`; schaltet Module serverweit ab |

Vorschlag für `PUSH_ALLOWED_HOSTS` (ein echtes Muster je Push-Dienst; Chrome/Edge/Samsung über FCM, Firefox über Mozilla, Safari und installierte
iOS-PWAs über Apple, Windows/Edge über WNS). Das ist enger als die Standardliste und im Test belegt (`B2ReviewTests`); die Standardliste bleibt wie in ADR-0011:

```sh
PUSH_ALLOWED_HOSTS=fcm.googleapis.com,updates.push.services.mozilla.com,web.push.apple.com,*.notify.windows.com
```

Aufräumjob (ADR-0017): läuft im Backend-Prozess (Sperre über `job_leases`, beliebig viele Replikate), einmalig für Betrieb/Cron mit
`App maintenance` bzw. im Container `docker compose --project-name timetrack-dev --profile app run --rm -T backend maintenance` (Ausgabe: nur Zähler; Exit-Code ungleich 0, wenn ein Schritt scheiterte).

`*_FILE`: Das Backend liest nur die Variablen selbst. Das Container-Image übersetzt im Einstiegspunkt `DB_PASSWORD_FILE`, `STORAGE_SECRET_KEY_FILE`,
`VAPID_PRIVATE_KEY_FILE`, `SMTP_PASSWORD_FILE`, `OIDC_CLIENT_SECRET_FILE` in die jeweilige Variable (Docker/Swarm-Secrets, `docs/BETRIEB.md` 5.4); bei `swift run` gilt das nicht.

Schlüssel erzeugen:

```sh
# STORAGE_SECRET_KEY
openssl rand -base64 32
# VAPID_PRIVATE_KEY (base64url, 32 Byte, P-256); VAPID_SUBJECT z. B. mailto:you@example.test
openssl ecparam -name prime256v1 -genkey -noout | openssl ec -outform DER 2>/dev/null | tail -c +8 | head -c 32 | base64 | tr '+/' '-_' | tr -d '=\n'
```

Bind-Adressen und Host-Ports der Compose-Dienste (`BACKEND_BIND_ADDR`, `BACKEND_HOST_PORT`, `DB_BIND_ADDR`, `DB_HOST_PORT`,
`MAIL_*`, `S3_*`, `OIDC_*`) stehen in `.env.example`; Standard ist `127.0.0.1`.

## 7. Testprofile, Ports und Testdomain

| Dienst (Compose-Profil) | Host-Port (127.0.0.1) | Start |
| --- | --- | --- |
| MariaDB 12.3 (immer) | 13306 | `scripts/dev-env.sh up` |
| Backend (`app`, MariaDB / `sqlite`) | 18080 | `up-app` / `up-sqlite` |
| Mailpit (`mail`) | UI 18025, SMTP 11025 | `up-mail` |
| Adobe S3Mock (`s3`) | 19090 (HTTP), 19191 (HTTPS) | `up-s3`, Werte fürs Admin-Formular: `s3-env` |
| Dex (`oidc`) | 15556 | `up-oidc` |
| PWA-Dev-Server | 5173 | `npm run dev` |
| Wegwerf-Backends der Echt-E2E | 18090 ff. | durch Playwright |

Details, Grenzen (Mailpit ohne TLS/AUTH, S3Mock ohne Signaturprüfung, Dex nur HTTP) und Testnutzer: `docs/TESTUMGEBUNGEN.md`.
Alle Dienste sind reine Testdoubles der Entwicklung.

Öffentliche Testdomain (hier als Platzhalter `test.example.org`; die echten Adressen stehen nur in der privaten `.env`) (Reverse Proxy und TLS beim Nutzer, Ziel
`192.0.2.10:18080`). Dafür in `.env` `BACKEND_BIND_ADDR=0.0.0.0` und `PUBLIC_BASE_URL`, `WEBAUTHN_ORIGIN`, `WEBAUTHN_RP_ID`
auf die Domain setzen, danach `up-app`. Auf dieser Instanz keine automatisierten Registrierungen mit virtuellen Passkeys;
der erste Admin soll der Nutzer mit echtem Passkey sein (Link noch zu erzeugen, `docs/STATUS.md`). Nichts davon wird vom
Projekt provisioniert.

## 8. Speicherplatz in Colima

Die Docker-Datenplatte der Colima-VM (40 GB) war am 15.10.2026 wiederholt voll; MariaDB startet dann nicht mehr.
Prüfen: `colima ssh -- df -h /var/lib/docker`. Abhilfe: eigene ungenutzte `timetrack-dev-*`-Images entfernen,
Build-Cache bereinigen (`docker builder prune`, betrifft alle Projekte der VM nur als Cache) oder die Platte
vergrößern (`colima stop && colima start --disk 80`). Details und Vorfall: `docs/TESTUMGEBUNGEN.md`.
Vorhandene Colima-Ressourcen nicht zurücksetzen, fremde Volumes/Images nie löschen.

## 9. Arbeitsaufteilung und Nachweis

Claude koordiniert mehrere Agents; Codex soll ungefähr die Hälfte der Implementierung übernehmen (Richtwert 40–60 %),
Review allein zählt nicht. Wegen des erschöpften Codex-Kontingents setzten Claude-Agents C9–C18 um (Nutzerentscheidung
14.10.2026); Zahlen und Abweichung (Stand 17.10.: Codex ca. 19,5 %) in `docs/ARBEITSPLAN.md`. Pro Paket genau ein Schreibverantwortlicher,
eigener Worktree je Schreiber (Regeln: `docs/ENTWICKLUNGSABLAUF.md`). Gemeinsame Verträge, Migrationen und Lockfiles
koordiniert ändern.

## 10. Wiederaufnahme ohne alte Session und IDEs

Das Repository enthält den gesamten dauerhaften Wissensstand. Jede neue Session beginnt mit
`AGENTS.md`, `docs/STATUS.md` und `docs/ARBEITSPLAN.md`; Checkpoints und Übergaben folgen
[ENTWICKLUNGSABLAUF.md](docs/ENTWICKLUNGSABLAUF.md). Keine alte Session-ID erforderlich.
Vor Sessionende die nächste konkrete Aktion dokumentieren und vorhandene Arbeit sichern.

PWA in PhpStorm, native Apps in Xcode. VS Code ist ausdrücklich ausgeschlossen.
Backend beschlossen: PhpStorm mit Noctule (noch ohne integriertes Swift-Debugging).
Drei getrennte Repos mit Backend als Hauptrepo: siehe [REPOSITORIES.md](docs/REPOSITORIES.md).
Linux-Tests über IDE-unabhängige Docker-/Compose-Befehle in Colima.
Details und Quellen: [IDE.md](docs/IDE.md). PhpStorm öffnet jeweils den Projektordner; Apple hat ein generiertes Xcode-Projekt.
