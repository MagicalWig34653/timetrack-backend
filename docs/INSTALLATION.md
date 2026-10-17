# Installation: Überblick und Auswahl

- **Wofür:** Timetrack auf einem eigenen Server betreiben, vom Download des Images bis zum ersten Login.
- **Voraussetzungen:** ein Linux-Server mit Docker, eine Domain mit HTTPS (Reverse Proxy) und optional eine eigene MariaDB.
- **Dauer:** etwa 15 Minuten mit Docker Compose, etwa 45 Minuten im Swarm.

Beispieldomain in allen Anleitungen: `timetrack.example.org`. Ersetze sie durch deine.

## Was du bekommst

Ein einziges Container-Image enthält das Backend (Swift/Vapor) und die Web-App (PWA). Es spricht intern nur HTTP, ein Reverse Proxy davor liefert HTTPS. Die Daten liegen in MariaDB; hochgeladene Dateien standardmäßig ebenfalls in der Datenbank (alternativ S3 oder ein lokaler Pfad, einstellbar im Admin-Bereich).

```
Browser / App ──HTTPS──> Reverse Proxy ──HTTP──> Timetrack (Port 18080) ──> MariaDB
```

## Das Image

Standardmäßig wird das fertige, öffentliche Image verwendet. Du musst nichts bauen:

```
ghcr.io/magicalwig34653/timetrack-backend:0.1.0
```

- Multi-Arch: läuft auf `linux/amd64` und `linux/arm64`. Es enthält die Web-App.
- Tags: `0.1.0` (feste Version, **für Produktion empfohlen**), `sha-<kurz>` (ein bestimmter Stand) und `latest` bzw. `main` (jüngster Stand der Entwicklung).
- Bis das erste Release `0.1.0` veröffentlicht ist, funktionieren `:latest` und `:main`. Die Beispieldateien nutzen `:latest` und weisen auf das Festlegen einer Version hin.
- Das Image selbst bauen (eigene Registry, eigene Änderungen): [Image selbst bauen](IMAGE-BAUEN.md). Nur dann.

## Voraussetzungen

| Voraussetzung | Hinweis |
| --- | --- |
| Linux-Server, amd64 oder arm64 | Docker Engine mit Compose-Plugin (Compose) bzw. aktivem Swarm (Swarm). |
| Domain mit HTTPS | Passkeys funktionieren nur über HTTPS (Ausnahme `localhost`). Den Reverse Proxy betreibst du selbst: [Reverse Proxy und TLS](installation/proxy.md). |
| MariaDB | Entweder die mitgelieferte (nur Compose, Profil `db`) oder deine eigene: [Eigene MariaDB vorbereiten](installation/mariadb.md). SQLite wird unterstützt, ist aber nur für Tests und Einzelinstanzen gedacht. |
| `curl` und `openssl` | Für die Hilfsskripte. |

## Compose oder Swarm?

| | Docker Compose | Docker Swarm |
| --- | --- | --- |
| Geeignet für | **ein** Server, einfachster Weg | mehrere Knoten, Rolling Updates, Docker-Secrets |
| Datenbank | mitgelieferte (`--profile db`) **oder** eigene | immer eine eigene, externe MariaDB |
| Geheimnisse | Dateien in `./secrets/` | Docker-Secrets |
| Aufwand | gering | höher (Secrets-Skript, Routing-Mesh, Ingress-Netz) |
| Anleitung | [Docker Compose](installation/compose.md) | [Docker Swarm](installation/swarm.md) |

Im Zweifel: Compose.

## Schnellstart (Compose, mitgelieferte Datenbank)

```sh
mkdir timetrack && cd timetrack
B=https://github.com/MagicalWig34653/timetrack-backend/raw/main/deploy/compose
curl -fsSLO $B/compose.yaml && curl -fsSLO $B/init-secrets.sh && curl -fsSL -o .env $B/.env.example && chmod +x init-secrets.sh
nano .env      # Domain, TIMETRACK_IMAGE, DB_HOST=db, DB_TLS=off, VAPID_SUBJECT eintragen
./init-secrets.sh --generate-db-password && docker compose --profile db up -d
```

Danach: Reverse Proxy einrichten, `/ready` prüfen, ersten Admin anlegen. Alle Schritte mit Erklärung stehen auf den Seiten unten.

## Die Seiten der Installation

1. **[Docker Compose (ein Server)](installation/compose.md)**: Schritt für Schritt, mit gebündelter oder eigener Datenbank.
2. **[Docker Swarm (Cluster)](installation/swarm.md)**: Stack, Docker-Secrets, Migration vor dem Start.
3. **[Eigene MariaDB vorbereiten](installation/mariadb.md)**: Datenbank, Benutzer mit minimalen Rechten, TLS.
4. **[Reverse Proxy und TLS](installation/proxy.md)**: Caddy, nginx, Traefik, Apple-Datei, Client-Adresse.
5. **[Ersteinrichtung](installation/ersteinrichtung.md)**: erster Admin, Passkey, Onboarding, Einladungen, Speicher, optionale Dienste, Apps, Import, KI-Anbindung.
6. **[Aktualisieren und Migrationen](UPDATE.md)**
7. **[Sichern und Wiederherstellen](installation/backup.md)**
8. **[Probleme und Lösungen](installation/probleme.md)**
9. **[Konfigurationsreferenz](installation/konfiguration.md)**: alle Umgebungsvariablen.
10. [Image selbst bauen](IMAGE-BAUEN.md) (nur, wenn du nicht das fertige Image nutzen willst).

Hintergrund und Checklisten für Produktion: [Ausführliche Deployment-Anleitung](DEPLOYMENT.md) (Swarm-Referenz, Sicherheits- und Go-Live-Checkliste, bekannte Lücken).
