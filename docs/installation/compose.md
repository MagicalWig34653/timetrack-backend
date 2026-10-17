# Docker Compose (ein Server)

- **Wofür:** Timetrack auf einem einzelnen Linux-Server mit Docker Compose betreiben, wahlweise mit mitgelieferter oder eigener MariaDB.
- **Voraussetzungen:** Docker mit Compose-Plugin, `curl`, `openssl`, eine Domain mit Reverse Proxy ([Reverse Proxy und TLS](proxy.md)). Für Variante B zusätzlich eine [vorbereitete MariaDB](mariadb.md).
- **Dauer:** etwa 15 Minuten. Danach weiter mit der [Ersteinrichtung](ersteinrichtung.md).

Beispieldomain: `timetrack.example.org`. Du brauchst nur drei Dateien aus dem Repository, kein Klonen.

## 1. Dateien holen

```sh
mkdir timetrack && cd timetrack
B=https://github.com/MagicalWig34653/timetrack-backend/raw/main/deploy/compose
curl -fsSLO $B/compose.yaml && curl -fsSLO $B/init-secrets.sh && curl -fsSL -o .env $B/.env.example
chmod +x init-secrets.sh
```

Prüfen: `ls -a` zeigt `compose.yaml`, `init-secrets.sh` und `.env`.

## 2. `.env` anpassen

Öffne `.env` (`nano .env`). Diese Werte musst du setzen oder prüfen (alle Variablen: [Konfigurationsreferenz](konfiguration.md)):

| Variable | Wert |
| --- | --- |
| `TIMETRACK_IMAGE` | `ghcr.io/magicalwig34653/timetrack-backend:0.1.0`. Die Vorlage enthält `:latest`; für Produktion eine feste Version eintragen. Hinweise zu Tags: [Überblick](../INSTALLATION.md). |
| `DB_HOST` und `DB_TLS` | Variante A (mitgelieferte DB): `DB_HOST=db`, `DB_TLS=off`. Variante B (eigene DB): Name deines Servers, `DB_TLS=required`. |
| `PUBLIC_BASE_URL` | `https://timetrack.example.org` |
| `WEBAUTHN_RP_ID` | `timetrack.example.org`: nur der Host, ohne `https://`. Er lässt sich später nicht ändern, ohne alle Passkeys zu entwerten. |
| `WEBAUTHN_ORIGIN` | `https://timetrack.example.org`: genau die Adresse aus der Browserzeile. |
| `VAPID_SUBJECT` | `mailto:du@example.org`: Kontaktadresse für Push-Dienste. |
| `BIND_ADDR` | `127.0.0.1`, wenn der Reverse Proxy auf demselben Server läuft (der Port ist dann nicht von außen erreichbar). |
| `TRUSTED_PROXY_CIDRS` | Netz, aus dem der Proxy den Container erreicht. Siehe [Reverse Proxy und TLS](proxy.md#trusted-proxy-cidrs-bestimmen). Kann nach dem ersten Start nachgetragen werden. |

Dateien liegen standardmäßig in der Datenbank; das Image enthält die Web-App.

## 3. Geheimnisse erzeugen

Variante A (mitgelieferte Datenbank, Passwort wird erzeugt):

```sh
./init-secrets.sh --generate-db-password
```

Variante B (eigene Datenbank): `./init-secrets.sh` ohne Option fragt das Passwort deines Datenbankbenutzers ab (Eingabe unsichtbar).

Das legt `./secrets/` an: Datenbankpasswort, Speicherschlüssel (`tt_storage_secret_key`), Push-Schlüssel (`tt_vapid_private_key`). Werte werden nie angezeigt, vorhandene Dateien nie überschrieben.

**Sichere `secrets/tt_storage_secret_key` und `secrets/tt_vapid_private_key` jetzt im Passwortmanager.** Ohne den Speicherschlüssel sind gespeicherte S3-Zugangsdaten nicht wiederherstellbar.

## 4. Starten

Variante A, mitgelieferte MariaDB (Profil `db`):

```sh
docker compose --profile db up -d
```

Variante B, eigene MariaDB (ohne Profil; Datenbank und Benutzer vorher nach [Eigene MariaDB vorbereiten](mariadb.md) anlegen):

```sh
docker compose up -d
```

Compose startet zuerst den Migrationsdienst (`migrate`) und danach das Backend. Das Backend wird nach bis zu 30 Sekunden `healthy`.

Prüfen:

```sh
docker compose ps                         # migrate: exited (0), backend: healthy
curl -fsS http://127.0.0.1:18080/ready    # Status 200
```

Bei `BIND_ADDR=0.0.0.0` und anderem `PUBLISHED_PORT` den Port anpassen. Bleibt `/ready` bei 503: `docker compose logs migrate backend`.

## 5. Reverse Proxy einrichten

Richte den Proxy auf `http://127.0.0.1:18080` aus ([Reverse Proxy und TLS](proxy.md)). Danach `TRUSTED_PROXY_CIDRS` in `.env` setzen und neu starten:

```sh
docker compose --profile db up -d      # ohne eigene DB: ohne --profile db
```

Prüfen: `https://timetrack.example.org/` zeigt die Anmeldeseite.

## 6. Weiter

Ersten Admin anlegen und die Instanz einrichten: **[Ersteinrichtung](ersteinrichtung.md)**.

## Mehr zu Compose

- **Aktualisieren:** `TIMETRACK_IMAGE` ändern, `docker compose pull && docker compose --profile db up -d`. Die Migration läuft dabei vor dem Backend: [Aktualisieren und Migrationen](../UPDATE.md).
- **Optionale Dienste** (SMTP, OpenID Connect): die auskommentierten Zeilen in `compose.yaml` aktivieren, siehe [Ersteinrichtung](ersteinrichtung.md).
- **Lokale Dateiablage:** die Volume-Zeilen in `compose.yaml` einkommentieren; Standard ist die Datenbank.
- `secrets/` und `.env` gehören nie in ein Repository.
- Getestet: `docker compose config` und ein Lauf mit der mitgelieferten Datenbank. Nicht getestet: eigene MariaDB mit TLS, Proxy, echte Domain.
