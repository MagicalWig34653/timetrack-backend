# ADR-0023: Versionsangaben von Server und Oberfläche

Status: Umsetzungsentscheidung von Paket V1 (Nutzerwunsch 18.10.2026: in der PWA unter Hilfe Version von Front- und Backend als Versionsnummer und Image-SHA-ID anzeigen); Lead-Prüfung offen. Alles, was nicht aus dem Wunsch folgt, sind Annahmen des Pakets.

## Entscheidungen

1. **Build-Metadaten im Image.** Dockerfile-Build-Argumente `APP_VERSION` (Standard `dev`), `GIT_SHA` (Standard `unknown`), `BUILD_DATE` (Standard leer) werden zu den Umgebungsvariablen `TIMETRACK_VERSION`, `TIMETRACK_REVISION`, `TIMETRACK_BUILD_DATE` und zu den OCI-Labels `org.opencontainers.image.version/.revision/.created`. `docker.yml` setzt sie in beiden Build-Jobs (Matrix und PR-Smoke): Version = Tag ohne `v`, `pr-<Nr>` oder Branchname; Revision = `github.sha`; Datum = UTC (ISO 8601). Lokale Builds ohne Argumente melden `dev`/`unknown`.
2. **„Image-ID“ ist die Git-Revision.** Der Digest (`sha256:…`) eines Images entsteht erst nach dem Build; der laufende Container kann ihn nicht enthalten. Die PWA zeigt deshalb Commit-ID (7 Zeichen, Kopieren-Knopf für die volle SHA) und nennt dem Betreiber den Befehl für den Digest: `docker service inspect timetrack_backend --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'`.
3. **`GET /api/v1/system/info`** (Vertrag v0.19.0, additiv): jedes angemeldete Konto, nicht modulgesteuert, keine Geheimnisse. `backend` = `version`, `revision`, `revisionShort`, `buildDate` (null bei lokalem Build), `apiVersion` (Konstante, per Test an `info.version` des Vertrags gebunden), `database`, `schemaMigrations` (Zeilen in `_fluent_migrations`), `migrationsPending`, `uptimeSeconds`, `replicaId` (Hostname = Container-Id; zeigt bei zwei Replikaten, welches antwortete). `pwa` = Inhalt von `version.json` im PWA-Verzeichnis oder `null`.
4. **`GET /health`** liefert zusätzlich `version` und `revision` (Schema `Health`; `/ready` bleibt `Status`).
5. **PWA-Seite.** Der PWA-Build schreibt `build/version.json` (`version`, `revision`, `buildDate`) und bettet dieselben Werte ein. Im Docker-Build kommen sie aus den Argumenten `PWA_VERSION` (Tag ohne `v` oder `main`), `PWA_REVISION` (der Checkout hat kein `.git`) und `BUILD_DATE`. Weicht die vom Server gemeldete PWA-Revision von der geladenen ab (alter Service-Worker-Cache), zeigt die Hilfe einen Hinweis mit Knopf „Neu laden / Aktualisieren“ (Service Worker abmelden, Caches leeren, neu laden).
6. **Ältere Server** ohne den Endpunkt (404): die Hilfe zeigt nur die Oberflächen-Angaben und einen Hinweis.

## Native Apps

Nicht Teil von V1. Die Endpunkte sind für sie nutzbar: `GET /api/v1/system/info` (Sitzung oder Gerätetoken wie bei den übrigen Lese-Endpunkten des Kerns) und `GET /health`.
