# Image selbst bauen

- **Wofür:** Das Container-Image aus dem Quellcode bauen, etwa für eigene Änderungen oder die eigene Registry.
- **Voraussetzungen:** Docker mit BuildKit (`docker buildx`), die Repositories `timetrack-backend` und `timetrack-pwa` nebeneinander ausgecheckt, ausreichend Geduld (der Swift-Build ist lang).
- **Dauer:** nativ deutlich länger als ein Pull (Swift-Build); emuliert ein Vielfaches.

::: tip Du musst das nicht tun
Standardmäßig nutzen alle Anleitungen das fertige, öffentliche Image `ghcr.io/magicalwig34653/timetrack-backend` (Tags `0.1.0`, `sha-<kurz>`, `latest`; amd64 und arm64; mit Web-App). Selbst bauen brauchst du nur, wenn du den Code änderst oder aus Prinzip aus den Quellen baust.
:::

## Ablage

```
<workspace>/timetrack-backend
<workspace>/timetrack-pwa
```

## Einfacher Build (eine Plattform, mit Web-App)

```sh
cd timetrack-backend
docker build --build-context pwa-src=../timetrack-pwa -t timetrack-backend:local .
```

Die Web-App wird in einer eigenen Stufe auf dem Builder gebaut (Node, `npm ci && npm run build`) und nach `/srv/pwa` kopiert. Prüfen: `docker run --rm --entrypoint ls timetrack-backend:local /srv/pwa` zeigt `index.html`.

## Build-Argumente

| Argument | Standard | Bedeutung |
| --- | --- | --- |
| `SWIFT_VERSION` | `6.3` | Version des Swift-Basisimages (`swift:<Version>-noble`). Muss zu `Package.swift` passen. |
| `NODE_VERSION` | `26.5.0` | Node-Version für den Build der Web-App (nur im Build, nicht im fertigen Image). |
| `PWA_REVISION` | leer | Wird als Image-Label `org.opencontainers.image.pwa.revision` gespeichert (z. B. der Commit der Web-App). |
| `QEMU_LIMIT` | `0` | `1` begrenzt den Swift-Build auf wenige CPUs und `-j 2` (nur für emulierte Fremdarchitektur nötig, sonst stürzt SwiftPM ab). |

Beispiel: `docker build --build-context pwa-src=../timetrack-pwa --build-arg PWA_REVISION=$(git -C ../timetrack-pwa rev-parse HEAD) -t timetrack-backend:local .`

## Ohne Web-App

Ohne `--build-context` bleibt `/srv/pwa` leer: `docker build -t timetrack-backend:local .` baut nur das Backend. API, MCP und `/health` funktionieren, `/` liefert 404. Das ist für Entwicklung gedacht, nicht für den Betrieb.

## Mehrere Plattformen (buildx)

```sh
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-context pwa-src=../timetrack-pwa -t registry.example.org/timetrack/timetrack-backend:0.1.0 --push .
```

Nativ auf einer Architektur ist das schnell. Die Fremdarchitektur läuft über QEMU und ist sehr langsam (ein amd64-Build auf einem arm64-Mac wurde nach 60 Minuten abgebrochen). Dafür `--build-arg QEMU_LIMIT=1` setzen, ohne den Wert stürzt SwiftPM unter Emulation mit `SIGILL` ab. Besser: je Plattform auf einer nativen Maschine bauen (wie es der GitHub-Workflow tut) oder nur die eigene Plattform bauen. Hintergrund: [Betrieb und Backup](BETRIEB.md), Abschnitt 7.

## Über GitHub bauen (Workflow `docker.yml`)

Der Workflow `.github/workflows/docker.yml` baut amd64 und arm64 auf nativen Runnern, fasst sie zu einem Multi-Arch-Tag zusammen und veröffentlicht nach `ghcr.io/<Eigentümer>/timetrack-backend`. Er checkt das Repository `<Eigentümer>/timetrack-pwa` aus; die Referenz (Branch oder Tag) legt die Repository-Variable `PWA_REF` fest, sonst `main`. Willst du das Image mit einem Fork bauen, forke beide Repositories und starte den Workflow (Push auf `main`, Tag `v*` oder manuell). Details, Tags und Einstellungen: [CI, Images und Website](CI.md).

## Eigenes Image verwenden

Trage das Image in die Konfiguration ein:

- Compose: `TIMETRACK_IMAGE=registry.example.org/timetrack/timetrack-backend:0.1.0` in `.env`.
- Swarm: dieselbe Variable in `.env`; bei privater Registry `docker login` auf jedem Knoten bzw. `docker stack deploy --with-registry-auth`.
- Ein lokal gebautes Image (`timetrack-backend:local`) funktioniert nur auf dem Rechner, auf dem es gebaut wurde. Für mehrere Knoten in eine Registry pushen.

Danach läuft alles wie in der [Installation](INSTALLATION.md). Die Entwicklungsumgebung (Dev-Compose, Tests) steht in [Einrichtung für Entwicklung](../EINRICHTUNG.md).
