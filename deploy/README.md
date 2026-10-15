# Lokale Container und spätere Swarm-Auslieferung

Stand: 15.10.2026. Vorhanden ist ausschließlich die **Entwicklungsumgebung** (Compose-Projekt `timetrack-dev`);
ein produktionsnahes Compose-/Swarm-Stack-File gibt es noch nicht (Backlog in `../docs/ARBEITSPLAN.md`).

## Was vorhanden ist

| Datei | Zweck |
| --- | --- |
| `../compose.yaml` | Dev-Compose: Dienste `db` (MariaDB 12.3), `backend` (Profil `app`), `backend-sqlite` (Profil `sqlite`), `mailpit` (`mail`), `s3mock` (`s3`), `dex` (`oidc`) |
| `../Dockerfile` | Mehrstufiger Build (`swift:*-noble` → `-noble-slim`), Healthcheck `/health`, Einstieg `/app/App serve` auf Port 8080 |
| `../scripts/dev-env.sh` | Start/Stopp/Status/Multi-Arch-Build der Dev-Umgebung (nie `-v`, nie `prune`) |
| `../.env.example` | Vorlage der Konfiguration; `scripts/dev-env.sh init` erzeugt `.env` |
| `dex/config.yaml` | Konfiguration des Dex-Testproviders |
| `pwa-empty/` | leeres Standardverzeichnis, das als `/srv/pwa` eingebunden wird, bis eine gebaute PWA bereitgestellt wird (`PWA_STATIC_HOST_DIR`) |
| `pwa-static/` | lokale, ignorierte Kopie des PWA-Builds für die Testdomain (nicht versioniert) |

Host-Ports (alle `127.0.0.1`, per `*_BIND_ADDR` änderbar): Backend 18080, MariaDB 13306, Mailpit 18025/11025,
S3Mock 19090/19191, Dex 15556. Volumes: `timetrack-dev-db`, `timetrack-dev-sqlite`, `timetrack-dev-s3mock`.
Befehle und Konfiguration: `../EINRICHTUNG.md`, Testdienste: `../docs/TESTUMGEBUNGEN.md`.

## Offen (Produktionsziel)

- Swarm-/Produktions-Stack mit Secrets (statt `.env`), Healthchecks, Logging/Metriken, Update-Strategie.
- Einmaliger, koordinierter Migrationsschritt statt `AUTO_MIGRATE` in jedem Replikat; MariaDB für mehrere Replikate,
  SQLite nur als eine Instanz auf persistentem Volume (nie geteilt).
- Vertrauenswürdige Proxy-Header für die Client-IP (Rate-Limits nutzen derzeit die Peer-IP).
- Backup/Restore (DB, Dateien, `STORAGE_SECRET_KEY`), amd64-Nachweis für den aktuellen Stand (bisher nur emuliert, SQLite, Stand 14.10.).

Ziele: Linux amd64/arm64, MariaDB empfohlen, statische PWA ohne Node-Laufzeit. Entwurf: `../docs/ARCHITEKTUR.md`.
Reverse Proxy, Domains und TLS stellt der Betreiber; das Projekt provisioniert sie nicht.
