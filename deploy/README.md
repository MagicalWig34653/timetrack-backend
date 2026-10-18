# Lokale Container und spätere Swarm-Auslieferung

Stand: 17.10.2026. Vorhanden ist ausschließlich die **Entwicklungsumgebung** (Compose-Projekt `timetrack-dev`);
das produktionsnahe Swarm-Stack-File `swarm/stack.yaml` (Paket B3) ist als Vorlage vorhanden, aber noch nicht in einem Swarm deployt. Betrieb, Backup, Reverse Proxy: [../docs/BETRIEB.md](../docs/BETRIEB.md).

## Was vorhanden ist

| Datei | Zweck |
| --- | --- |
| `../compose.yaml` | Dev-Compose: Dienste `db` (MariaDB 12.3), `backend` (Profil `app`), `backend-sqlite` (Profil `sqlite`), `mailpit` (`mail`), `s3mock` (`s3`), `dex` (`oidc`) |
| `../Dockerfile` | Mehrstufiger Build (`swift:*-noble` → `-noble-slim`), Healthcheck `/health`, Einstieg `/app/App serve` auf Port 8080 |
| `../scripts/dev-env.sh` | Start/Stopp/Status/Multi-Arch-Build der Dev-Umgebung (nie `-v`, nie `prune`) |
| `../.env.example` | Vorlage der Konfiguration; `scripts/dev-env.sh init` erzeugt `.env` |
| `swarm/stack.yaml`, `swarm/.env.example`, `swarm/create-secrets.sh` | Swarm-Stack ohne Datenbank-Container (Backend + einmaliger Migrationsjob, Docker-Secrets, Healthcheck, Update/Rollback, Limits), alle Variablen mit Beispielwerten, Skript zum Anlegen der Docker-Secrets (`--dry-run`); per `docker stack config` geprüft. Anleitung: [../docs/installation/swarm.md](../docs/installation/swarm.md), Referenz [../docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md) |
| `../scripts/backup.sh`, `restore.sh`, `test-restore.sh` | Sicherung/Wiederherstellung und Beweislauf (`../docs/BETRIEB.md`) |
| `../scripts/docker-entrypoint.sh` | Image-Einstiegspunkt: `VAR_FILE` (Docker-Secrets) nach `VAR`, dann `/app/App` |
| `../scripts/check-all.sh`, `test-image-smoke.sh` | Gesamtprüfung; Container-Smoke-Test des Produktions-Images |
| `dex/config.yaml` | Konfiguration des Dex-Testproviders |
| `pwa-empty/` | leeres Standardverzeichnis, das als `/srv/pwa` eingebunden wird, bis eine gebaute PWA bereitgestellt wird (`PWA_STATIC_HOST_DIR`) |
| `pwa-static/` | lokale, ignorierte Kopie des PWA-Builds für die Testdomain (nicht versioniert) |

Host-Ports (alle `127.0.0.1`, per `*_BIND_ADDR` änderbar): Backend 18080, MariaDB 13306, Mailpit 18025/11025,
S3Mock 19090/19191, Dex 15556. Volumes: `timetrack-dev-db`, `timetrack-dev-sqlite`, `timetrack-dev-s3mock`.
Befehle und Konfiguration: `../EINRICHTUNG.md`, Testdienste: `../docs/TESTUMGEBUNGEN.md`.

## Offen (Produktionsziel)

- Reales Swarm-Deployment der Vorlage (Secrets-Einhängung, Job, Rollback) ist nicht erprobt.
- Vertrauenswürdige Proxy-Header: umgesetzt (`TRUSTED_PROXY_CIDRS`, ADR-0018); ohne Konfiguration nutzen Rate-Limits die Peer-IP (`../docs/BETRIEB.md`, Abschnitt 6). Mit echtem Proxy nicht erprobt.
- Bekannte Lücken der Produktions-Anleitung: `../docs/DEPLOYMENT.md`, Abschnitt 17.
- Metriken (kein `/metrics`), zeitgesteuerte Backups, S3-Backup gegen echtes S3, amd64-Nachweis siehe `../docs/handoffs/B3.md`.

Ziele: Linux amd64/arm64, MariaDB empfohlen, statische PWA ohne Node-Laufzeit. Entwurf: `../docs/ARCHITEKTUR.md`.
Reverse Proxy, Domains und TLS stellt der Betreiber; das Projekt provisioniert sie nicht.

Produktions-Stack (`swarm/`): ohne Volumes und ohne Knotenbindung; die PWA ist im Image (Dockerfile, Build-Kontext `pwa-src`), Dateien liegen in der Datenbank. Die Entwicklungs-Compose-Umgebung bindet weiterhin `pwa-static/` bzw. `pwa-empty/` nach `/srv/pwa` ein (überlagert die PWA im Image).
