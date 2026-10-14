# Handoff L3a: Image-Builds und Container-Läufe (arm64 / amd64)

Branch `l3a-images`. Geänderte Dateien: `Dockerfile`, `compose.yaml`, `.env.example`, dieses Dokument.

## Dockerfile-Korrekturen

- `COPY Tests ./Tests`: SwiftPM validiert deklarierte Test-Targets auch bei `--product App`; ohne `Tests/`
  scheiterte der Build mit "target 'TimetrackKitTests' has overlapping sources".
- Neue Stage `deps` (`--platform=$BUILDPLATFORM`): `swift package resolve` läuft nativ; unter QEMU stürzte es
  mit SIGILL ab (Exit 132). Git war im Builder-Image vorhanden, Netzwerk funktioniert.
- `RUN taskset -c 0 swift package describe` vor dem Build: SwiftPM lädt Manifeste mit tausenden Threads, was
  unter QEMU-User-Emulation abstürzt ("Signal 4", "failed to suspend thread N"). Einzel-CPU-Ladevorgang hilft.
- `taskset -c 0-1 swift build ... -j 2`: ohne Begrenzung stürzte auch der Build-Prozess selbst nach ca. 12-75 s ab.
  Auf arm64 nativ ist die Begrenzung unnötig und kostet Zeit; Verbesserungsidee: per Build-Arg nur für
  Fremdarchitektur setzen (offen).
- `compose.yaml` / `.env.example`: `DB_TLS` war `false`, das Backend erwartet `off|required` und brach beim Start ab.
  Jetzt `off`.
- Keine `*.resources`-Bundles vorhanden (Kopierschritt bleibt harmlos). Nutzer uid 10001, Healthcheck, `/data` beschreibbar
  für `timetrack`: bestätigt. Statisches Linken (`--static-swift-stdlib`) nicht untersucht (offen, würde Image verkleinern).

## arm64 (nativ): verifiziert

- Build `docker build --platform linux/arm64`: ca. 2 min 03 s (Dependency-Layer warm), Image 611 MB, Binary `App` 135 MB,
  `uname -m` = aarch64, Prozess läuft als uid 10001.
- `scripts/dev-env.sh up-app` (MariaDB, `AUTO_MIGRATE=true`): `/health` und `/ready` auf 127.0.0.1:18080 je 200 `{"status":"ok"}`,
  Container `healthy`, Log nur "Server started", keine Secrets.
- Explizite Migration: `docker compose -p timetrack-dev -f compose.yaml --profile app run --rm -e AUTO_MIGRATE=false backend migrate --yes`
  ("No new migrations", da Auto-Migrate zuvor lief).
- `... run --rm backend bootstrap-admin` und `docker exec ... /app/App bootstrap-admin`: Ausgabe `http://localhost:18080/invite/<token>`
  (Format bestätigt, Token nicht gespeichert). Die Bootstrap-Einladungen bleiben in Dev-MariaDB und Dev-SQLite bis zum Ablauf bestehen
  (nicht widerrufen).
- `up-sqlite` (app-Profil vorher per `rm -sf backend` entfernt): `/health`, `/ready` 200; `/data/timetrack.sqlite` angelegt.
  Persistenz: Einladung vor `docker restart` und nach Entfernen und Neuanlegen des Containers weiterhin abrufbar
  (`GET /api/v1/invitations/<token>` 200), Volume `timetrack-dev-sqlite` bleibt.
- PWA im Container: Build aus `timetrack-pwa` (Branch l3b-e2e, `npm run build`, adapter-static; ein paralleler Lauf mit l3b
  lieferte einmal einen Fehler, Wiederholung ok) nach `.build/pwa-static` kopiert und als `PWA_STATIC_HOST_DIR` gemountet:
  `/` 200 text/html, `/invite/xyz` 200 und byte-identisch zu `index.html`, `/health` JSON, `/api/v1/nonexistent` 404 JSON,
  `/robots.txt` 200. Hinweise: (1) Mounts funktionieren nur unter `$HOME` (Colima mountet nur Home; `/private/tmp` erscheint leer),
  ein Mount direkt auf `timetrack-pwa/build` war leer, weil `build/` beim Neubauen ersetzt wird; Kopie verwenden.
  (2) `/_app/nonexistent.js` liefert den SPA-Fallback (200 HTML) statt 404; Verbesserung für C-Paket vorgeschlagen.

## amd64 (QEMU unter Colima, kein Rosetta konfiguriert): Stand

- `docker run --platform linux/amd64 alpine uname -m` = x86_64 (Emulation vorhanden).
- Erster Versuch: `swift package resolve` Exit 132 (SIGILL). Mit `deps`-Stage umgangen. Danach `swift build`:
  Manifest-Kompilierung stürzt ab ("Invalid manifest ... Signal 4"), auch mit `QEMU_CPU=max` und `-j 2`.
  `--cpuset-cpus=0` (nproc=1) lädt Manifeste fehlerfrei (ca. 4 min).
- Aktueller Build mit `taskset`-Begrenzung (Dockerfile oben) kompiliert; bei Übergabe Schritt 913/922 nach ca. 28 min
  (Schätzung gesamt 35 bis 45 min). Ergebnis zum Zeitpunkt der Übergabe unbekannt; Log im Scratchpad
  (`amd64-build.log`). Nicht verifiziert: amd64-Image-Lauf, `uname -m` im Container, `/health`+`/ready` unter amd64.
- `scripts/dev-env.sh build-multiarch` nicht ausgeführt (dauert wegen amd64 ebenso lange). Offen.

## Offen

amd64-Abschluss und Smoke-Run (`timetrack-dev-amd64-smoke`, SQLite), `build-multiarch`, Build-Arg für die QEMU-Begrenzung,
statisches Linken, SPA-Fallback für unbekannte `/_app/*`-Dateien, Compose-Anonymvolume für `/data` im app-Profil.
