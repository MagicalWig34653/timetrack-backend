# CI, Container-Images und GitHub Pages

Stand: 17.10.2026 (Paket W1). **Alle Workflows sind geschrieben und statisch geprüft (actionlint, YAML), aber noch nie auf GitHub gelaufen.** Es gibt noch keinen Push und keine Veröffentlichung. Abschnitt „Nicht geprüft“ am Ende beachten.

Die Workflows liegen je Repository unter `.github/workflows/`. Backend (Hauptrepo) enthält zusätzlich die Website unter `site/`.

## Überblick

| Repository | Datei | Auslöser | Zweck |
| --- | --- | --- | --- |
| Backend | `ci.yml` | Push auf `main`, Pull Request, aufrufbar von `release.yml` | Swift-Build und Tests (SQLite), Tests gegen MariaDB 12.3, Vertrags- und Skriptprüfungen, Compose/Stack-Konfiguration |
| Backend | `docker.yml` | Push `main`, Tags `v*`, Pull Request (nur bei Docker-relevanten Pfaden) | Image für amd64 und arm64 bauen; ab `main`/Tag nach GHCR veröffentlichen; Smoke-Test `/health` |
| Backend | `pages.yml` | Push `main` auf `site/`, `docs/`, `contracts/`; Pull Request (nur Build) | Website bauen und auf GitHub Pages veröffentlichen |
| Backend | `release.yml` | Tag `v*` | CI ausführen, GitHub Release mit generierten Notizen, OpenAPI-Vertrag, Quellarchiv, Lizenzhinweise, Prüfsummen |
| Backend | `codeql.yml` | Push/PR `main`, wöchentlich | CodeQL für GitHub Actions und JavaScript (Website-Skripte) |
| Backend | `dependency-review.yml` | Pull Request | Neue Abhängigkeiten mit bekannten Schwachstellen (hoch) blockieren |
| Backend | `dependabot.yml` | wöchentlich | Updates für Actions, npm (`site/`), Docker, SwiftPM |
| PWA | `ci.yml` | Push `main`, Pull Request, manuell, wöchentlich | `npm run check`, Vitest, Build, Playwright (Mock, Produktionsbuild); optional E2E gegen echtes Backend |
| PWA | `codeql.yml`, `dependency-review.yml`, `dependabot.yml` | wie Backend | Sicherheitsprüfungen und Updates (Actions, npm) |
| Apple | `ci.yml` | Push `main`, Pull Request, manuell | XcodeGen-Abweichung, `swift test` der Pakete, unsignierte Builds iOS/macOS/watchOS |
| Apple | `testflight.yml` | nur manuell | **Gerüst, nicht getestet:** Archiv, Export, Upload nach App Store Connect |
| Apple | `dependabot.yml` | wöchentlich | Updates für Actions und SwiftPM |

In allen Repositories außerdem: Issue-Vorlagen (Fehler, Funktion; deutsch, mit Hinweis auf synthetische Daten), `pull_request_template.md`, `CODEOWNERS`, `SECURITY.md`.

## Entscheidungen und Annahmen

- **Swift-Toolchain:** `Package.swift` verlangt `swift-tools-version:6.3`, das Dockerfile nutzt `swift:6.3-noble` (Build-Argument `SWIFT_VERSION`). Die CI verwendet dasselbe offizielle Image `swift:6.3-noble` als Job-Container. Wird das Dockerfile angehoben, muss `ci.yml` (Umgebungsvariable `SWIFT_IMAGE` und die `container:`-Zeilen) und der PWA-Job mitgezogen werden. Das Image-Tag wurde nicht gegen Docker Hub geprüft, nur gegen das Dockerfile, das lokal damit baut.
- **`--build-system native`** wird überall verwendet wie lokal (EINRICHTUNG.md). Unter Linux ist das nur Konsistenz; bei Problemen kann es dort entfallen.
- **MariaDB-Variablen** stammen aus `scripts/dev-env.sh test-db`: `MARIADB_TEST_HOST`, `_PORT`, `_USER`, `_PASSWORD`, `_DB`. Der Service-Container `mariadb:12.3` hat ein Wegwerf-Root-Passwort, das nur im Job-Netz existiert (kein Secret nötig). Die Tests legen eigene Wegwerf-Datenbanken an, deshalb Benutzer `root`.
- **Docker-Image ohne QEMU:** `docker.yml` baut amd64 auf `ubuntu-24.04` und arm64 nativ auf `ubuntu-24.04-arm` (je Plattform ein Job, Push per Digest, danach ein Manifest). Das umgeht die langsame und abstürzende Emulation (siehe `QEMU_LIMIT` im Dockerfile). Falls im Konto keine Arm-Runner verfügbar sind (für private Repositories evtl. nicht kostenlos), ist die Alternative: QEMU mit `docker/setup-qemu-action@v3` und `build-args: QEMU_LIMIT=1` für die Fremdplattform, mit deutlich längerer Laufzeit.
- **Tags:** Die Semver-Tags (`1.2.3`, `1.2`) entstehen nur bei Tags `v*`. `main` erzeugt `main`, `sha-<kurz>` und `latest` (`latest` = jüngster Stand des Standardzweigs, solange es keine Releases gibt; für Produktion besser `sha-…` oder eine Version festlegen). Provenance (`mode=max`) und SBOM sind bei Veröffentlichungen aktiv, nicht bei Pull Requests.
- **PWA im Image (D4):** `docker.yml` checkt zusätzlich `<Eigentümer>/timetrack-pwa` aus (Pfad `pwa-src`, Referenz: Repository-Variable `PWA_REF`, Standard `main`) und übergibt es als Build-Kontext `pwa-src` sowie `PWA_REVISION` (Commit-SHA, Image-Label `org.opencontainers.image.pwa.revision`). Die PWA wird im Dockerfile nativ auf dem Builder gebaut (Node 26.5.0, `NODE_VERSION`). Annahme: das PWA-Repository ist öffentlich lesbar (sonst fehlt dem Checkout ein Token). Ein `v*`-Tag baut mit `PWA_REF`, nicht automatisch mit dem gleichnamigen PWA-Tag. Nicht auf GitHub gelaufen.
- **Smoke-Test:** `scripts/ci-smoke.sh IMAGE [PORT]` startet das Image mit SQLite und ruft `/health` ab; mit `EXPECT_PWA=1` (in der CI gesetzt) prüft er zusätzlich, dass `/` und ein Deep-Link (`/settings/profile`) die HTML-Hülle der PWA liefern. Lokal gegen `timetrack-dev-backend:local` ausgeführt (Antwort `{"status":"ok"}`). Bei Pull Requests wird das amd64-Image aus dem Layer-Cache geladen, bei Veröffentlichungen läuft der Test gegen das veröffentlichte Manifest.
- **PWA, echtes Backend:** Der optionale Job baut das Backend aus dem Quellcode (Repository `<Eigentümer>/timetrack-backend`) im Swift-Image, weil `e2e/global-setup.ts` das Debug-Binary `.build/debug/App` selbst je Spec-Gruppe startet; das GHCR-Image würde dafür nicht genügen und existiert vor dem ersten Release nicht. Der Job ist schwer, läuft nur manuell (`real_backend`) und wöchentlich und ist `continue-on-error`. Bei privatem Backend-Repository braucht er das Secret `BACKEND_REPO_TOKEN` (fein granuliertes Token, nur `contents: read`).
- **Apple-Runner:** Das Projekt zielt auf OS 27 und damit Xcode 27. Gehostete macOS-Images haben Xcode 27 voraussichtlich nicht. Der Runner ist über die Repository-Variable `APPLE_RUNNER` einstellbar; ohne Variable gilt `macos-26` (Annahme). Realistisch braucht es einen selbst gehosteten Mac-Runner. Der Prüflauf `xcodegen generate` kann zusätzlich an abweichenden XcodeGen-Versionen scheitern (lokal 2.46.0).
- **CodeQL für Swift:** nicht eingerichtet. CodeQL-Swift braucht macOS-Runner mit passendem Xcode, das Backend braucht Swift 6.3. Stattdessen analysiert CodeQL Workflows (`actions`) und JavaScript.
- **Action-Versionen:** nur Hauptversionen (`@v4`, `@v3`), die bekannt existieren. Aktualisierungen kommen über Dependabot (`github-actions`). Wer maximale Härtung will, pinnt später auf Commit-SHAs; Dependabot kann auch diese aktualisieren.
- **Redocly-Lint** (`@redocly/cli@1.34.5`) läuft nicht blockierend: lokal meldet er 189 Fehler, überwiegend `operation-summary` (Operationen ohne `summary`), also Stilfragen am bestehenden Vertrag.
- **CODEOWNERS:** `@MagicalWig34653`, abgeleitet aus der Remote-URL `github.com/MagicalWig34653/...`; bitte bestätigen.

## Nötige GitHub-Einstellungen

1. **Pages:** Settings, Pages, Source = **GitHub Actions** (Backend-Repository). Die Website liegt dann unter `https://<Eigentümer>.github.io/timetrack-backend/`. Anderer Pfad oder eigene Domain: `SITE_BASE` in `pages.yml` anpassen.
2. **Pakete (GHCR):** Das Image erscheint nach dem ersten Lauf als Paket `timetrack-backend`. Sichtbarkeit (privat/öffentlich) dort einstellen; für Swarm-Knoten ohne Login muss es öffentlich sein, sonst `docker login ghcr.io` mit einem Token mit `read:packages`. Das Paket mit dem Repository verknüpfen (Package settings, Connect repository).
3. **Actions-Berechtigungen:** Settings, Actions, General: Workflow permissions auf „Read repository contents“ als Standard; die Workflows fordern erhöhte Rechte je Job selbst an (`packages: write`, `pages: write`, `contents: write` nur im Release).
4. **Branch-Schutz für `main` (Vorschlag):** Pull Request erforderlich, Statusprüfungen „Swift build and tests (SQLite)“, „Swift tests (MariaDB 12.3)“, „Contract checks“, „Shell checks and compose/stack config“; in der PWA „Check, unit tests, build“, „Playwright (mock API)“, „Playwright (production build, service worker)“; Apple erst, wenn ein Runner mit Xcode 27 läuft.
5. **Sicherheit:** Private Schwachstellenmeldung und Dependabot-Alerts aktivieren; Code scanning (CodeQL) wird durch die Workflows befüllt.
6. **Environment `testflight`** (Apple-Repository) mit Pflichtfreigabe anlegen, bevor der Workflow benutzt wird.

### Secrets und Variablen (Namen, keine Werte)

| Repository | Name | Art | Verwendung |
| --- | --- | --- | --- |
| alle | `GITHUB_TOKEN` | automatisch | GHCR-Push, Release, Pages |
| PWA | `BACKEND_REPO_TOKEN` | Secret, optional | Checkout des privaten Backends im Echt-E2E-Job |
| Apple | `APPLE_RUNNER` | Variable, optional | Runner-Label (z. B. selbst gehosteter Mac mit Xcode 27) |
| Apple | `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY` (Inhalt der `.p8`), `APPLE_TEAM_ID` | Secrets, nur TestFlight | App-Store-Connect-API-Schlüssel; Signierung automatisch per API-Schlüssel |

## Lokal nachstellen

**Linux-Lauf lokal reproduzieren** (Docker/Colima, eigenes Build-Volume, nie das macOS-`.build` mounten). `--cpuset-cpus 0,1` bildet die zwei Kerne der GitHub-Runner nach; die Zahl der Kerne bestimmt die Zahl der Event Loops und damit der SQLite-Pool-Verbindungen:

```sh
docker run --rm --cpuset-cpus 0,1 -v "$PWD":/work -v timetrack-dev-l1-build:/build -w /work swift:6.3-noble \
  bash -lc "swift test --build-system native --scratch-path /build"   # ggf. --filter <Test>; erster Build ca. 3-10 Minuten
```
Für MariaDB zusätzlich `--network timetrack-dev_default --env-file <Datei mit MARIADB_TEST_*>` (eigene Datenbank, `MARIADB_TEST_DB`). Unter Rosetta (amd64) stürzt der Swift-Compiler ab; dort nicht bauen.

```sh
# Backend
swift build --build-system native && swift test --build-system native      # SQLite
eval "$(scripts/dev-env.sh test-db | grep ^export)"; swift test --build-system native   # MariaDB, siehe EINRICHTUNG.md
scripts/check-all.sh --fast                          # Vertrag, Shell, Compose/Stack
scripts/contract-json.sh && git diff --exit-code Tests/TimetrackKitTests/Contract/openapi.contract.json
docker build -t timetrack-ci:local . && scripts/ci-smoke.sh timetrack-ci:local
actionlint .github/workflows/*.yml                   # brew install actionlint
# Website
cd site && npm ci && npm run build                   # Ausgabe: site/.vitepress/dist
SITE_BASE=/ npx vitepress preview --port 19300       # Vorschau
# PWA
npm ci && npm run check && npm test && npm run build && npm run test:e2e:mock && npm run test:e2e:pwa
# Apple
xcodegen generate && git diff --exit-code Timetrack.xcodeproj
(cd Packages/TimetrackCore && swift test --build-system native)
xcodebuild -project Timetrack.xcodeproj -scheme TimetrackIOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Website (`site/`)

VitePress, Versionen fest in `site/package.json`, Lockfile eingecheckt. `npm run build` führt zuerst `scripts/sync-docs.mjs` aus: Es kopiert die vorhandenen deutschen Dokumente (Konzept, Architektur, Umsetzung, Design, MCP, Einrichtung, Betrieb, CI, Entwicklungsablauf, Lizenzen, ADRs; `docs/DEPLOYMENT.md` nur falls vorhanden; optional PWA-Kurzbefehle über `PWA_DOCS_DIR`) nach `site/docs-src/` (nicht eingecheckt), schreibt relative Links um (auf Seitenrouten oder GitHub-Quellen) und ersetzt interne Bezeichner (Testdomain, Team-ID, Bundle-IDs, lokale Pfade, LAN-Adresse); bleibt ein solcher Bezeichner übrig, bricht der Bau ab. Handoffs und Reviews werden nicht übernommen. Danach rendert `scripts/build-api.mjs` den OpenAPI-Vertrag mit Redocly als eigenständige Seite unter `/api/` (ohne Fremdanfragen). `SITE_BASE` (Standard `/timetrack-backend/`) setzt den Basispfad. Screenshots unter `site/public/screenshots/` stammen aus dem Apple-Repository (`docs/screenshots/`, erfundene Beispieldaten, einzeln angesehen).

## Versionierung und Release

1. Vertragsversion in `contracts/openapi.yaml` und Stand in `docs/STATUS.md` pflegen.
2. Tag setzen: `git tag v0.15.0 && git push origin v0.15.0` (nicht automatisch; Push ist eine bewusste Handlung).
3. `release.yml` ruft die CI auf und erstellt bei Erfolg das Release (`gh release create --generate-notes`; Tags mit `-` im Namen werden als Vorabversion markiert) mit Quellarchiv, `openapi-<Tag>.yaml`, `THIRD-PARTY-NOTICES-<Tag>.txt` (Lizenztexte der SwiftPM-Pins, erzeugt in einem `swift:6.3-noble`-Container mit `scripts/third-party-notices.sh`) und `SHA256SUMS`. Der Text enthält das AGPL-Quellcode-Angebot.
4. `docker.yml` baut parallel dasselbe Tag als Image (`ghcr.io/<Eigentümer>/timetrack-backend:<Version>`, `latest`). Im Swarm-Stack `TIMETRACK_IMAGE` auf dieses Tag setzen (`docs/BETRIEB.md`).
5. Pages werden bei Änderungen auf `main` neu gebaut, nicht erst beim Tag.

## Nicht geprüft

- Kein Workflow ist auf GitHub gelaufen; geprüft sind Syntax und Ausdrücke mit actionlint sowie die enthaltenen Befehle lokal, soweit möglich (siehe `docs/handoffs/W1.md`).
- Nicht belegt: Verfügbarkeit von `swift:6.3-noble`, `mariadb:12.3` und `ubuntu-24.04-arm` im Konto, der Swift-Build in der Container-Umgebung der Actions, das Zusammenführen der Digests, Provenance/SBOM, Pages-Deployment, Release-Erstellung.
- Das Echt-E2E der PWA in CI und der gesamte Apple-Workflow (Runner mit Xcode 27) sind ungetestet; `testflight.yml` ist ein Gerüst, das erst mit aktivem Developer-Konto sinnvoll prüfbar ist.

- **Versionsangaben im Image (V1, ADR-0023):** `docker.yml` übergibt `APP_VERSION` (Tag ohne `v`, `pr-<Nr>` oder Branchname), `GIT_SHA` (`github.sha`), `BUILD_DATE` (UTC) sowie `PWA_VERSION` und `PWA_REVISION` an das Dockerfile; daraus entstehen die Umgebungsvariablen `TIMETRACK_VERSION`/`_REVISION`/`_BUILD_DATE`, die OCI-Labels `version`/`revision`/`created` und `build/version.json` der PWA. `scripts/ci-smoke.sh` prüft mit `EXPECT_REVISION`, dass `/health` die gebaute Revision meldet. Nicht auf GitHub gelaufen.
