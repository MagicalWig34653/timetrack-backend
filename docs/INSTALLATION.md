# Installation: in 10 Minuten zum Laufen

Dies ist der Einstieg für alle, die Timetrack selbst betreiben. Der Weg unten nutzt **Docker Compose auf einem Server**, mit mitgelieferter MariaDB. Beispieldomain: `timetrack.example.org`, ersetze sie durch deine.

**Du brauchst:** einen Linux-Server (amd64 oder arm64) mit Docker und dem Compose-Plugin, eine Domain mit HTTPS über einen Reverse Proxy (siehe Kasten unten) und `curl` sowie `openssl`.

## Schritte

**1. Dateien holen** (nur diese drei, kein Klonen nötig):

```sh
mkdir timetrack && cd timetrack
B=https://github.com/MagicalWig34653/timetrack-backend/raw/main/deploy/compose
curl -fsSLO $B/compose.yaml && curl -fsSLO $B/init-secrets.sh && curl -fsSL -o .env $B/.env.example
chmod +x init-secrets.sh
```

**2. `.env` anpassen** (`nano .env`). Das sind die Werte, die du ändern musst:

- `DB_HOST=db` und `DB_TLS=off`: nutzt die mitgelieferte Datenbank, die nur im Compose-Netz erreichbar ist.
- `PUBLIC_BASE_URL=https://timetrack.example.org`: die öffentliche Adresse.
- `WEBAUTHN_RP_ID=timetrack.example.org`: nur der Host, ohne `https://`. Er lässt sich später nicht ändern, ohne alle Passkeys zu entwerten.
- `WEBAUTHN_ORIGIN=https://timetrack.example.org`: genau die Adresse aus der Browserzeile.
- `VAPID_SUBJECT=mailto:du@example.org`: Kontaktadresse für Push-Dienste.
- Läuft dein Reverse Proxy auf demselben Server, setze zusätzlich `BIND_ADDR=127.0.0.1`.

`TIMETRACK_IMAGE` bleibt, wie es ist (`ghcr.io/magicalwig34653/timetrack-backend:main`). Das Image enthält die Web-App; Dateien liegen standardmäßig in der Datenbank.

**3. Geheimnisse erzeugen:**

```sh
./init-secrets.sh --generate-db-password
```

Das legt `./secrets/` an (Datenbankpasswort, Speicher- und Push-Schlüssel). Werte werden nie angezeigt.

**4. Starten:**

```sh
docker compose --profile db up -d
```

Zuerst läuft die Migration, danach startet das Backend.

**5. Prüfen:**

```sh
curl -fsS http://127.0.0.1:18080/ready
```

Kommt eine Antwort mit Status 200, läuft es. (Das dauert nach dem Start bis zu 30 Sekunden. Bei `PUBLISHED_PORT=...` den Port anpassen.)

**6. Ersten Admin anlegen:**

```sh
docker compose run --rm --no-deps -T backend bootstrap-admin --env production
```

Der Befehl gibt einen **Einladungslink** aus (`https://timetrack.example.org/invite/...`, 72 Stunden gültig, einmalig). Behandle ihn wie ein Passwort. Öffne ihn im Browser deines Handys oder Computers und lege den **Passkey** an. Wichtig: `docker exec ... bootstrap-admin` funktioniert **nicht** (Fehler `executable file not found in $PATH`). Nimm den Befehl oben.

### Fertig, wenn

- [ ] `/ready` antwortet mit 200
- [ ] `https://timetrack.example.org` zeigt die Anmeldeseite
- [ ] Der Passkey ist angelegt und du bist als Admin angemeldet
- [ ] `secrets/tt_storage_secret_key` und `secrets/tt_vapid_private_key` liegen zusätzlich im Passwortmanager

## Reverse Proxy in 2 Minuten

Der Proxy terminiert HTTPS und leitet alles an `127.0.0.1:18080` weiter. **Eine Regel ist wichtig:** `/.well-known/apple-app-site-association` muss unverändert durchgereicht werden, ohne Weiterleitung (nur für die iOS-App nötig; die Datei liefert das Backend, wenn `APPLE_APP_IDS` gesetzt ist).

Caddy (holt das Zertifikat selbst, reicht alles unverändert durch):

```
timetrack.example.org {
    reverse_proxy 127.0.0.1:18080
}
```

nginx (Zertifikat z. B. über certbot):

```nginx
server {
    listen 443 ssl;
    server_name timetrack.example.org;
    ssl_certificate     /etc/letsencrypt/live/timetrack.example.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/timetrack.example.org/privkey.pem;
    client_max_body_size 70m;                      # Datei-Uploads

    location = /.well-known/apple-app-site-association {   # kein Redirect, kein Umschreiben
        proxy_pass http://127.0.0.1:18080;
        proxy_set_header Host $host;
    }
    location / {
        proxy_pass http://127.0.0.1:18080;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Trage in `.env` außerdem `TRUSTED_PROXY_CIDRS=` mit der Adresse bzw. dem Netz ein, von dem der Proxy den Container erreicht, und starte neu (`docker compose --profile db up -d`). Sonst teilen sich alle Nutzer ein Anmelde-Limit. Mehr dazu (inkl. Traefik und Zusatzregeln): [Ausführliche Anleitung](DEPLOYMENT.md).

## Mit eigener MariaDB

Drei Unterschiede zu oben: Lege Datenbank und Benutzer selbst an (Rechte siehe [Ausführliche Anleitung](DEPLOYMENT.md)); setze in `.env` `DB_HOST` auf deinen Server und lass `DB_TLS=required` (Zertifikatsname muss passen); starte ohne Profil: `docker compose up -d`. `./init-secrets.sh` ohne Option fragt dann nach dem Passwort deines Datenbankbenutzers.

## Im Swarm-Cluster

Dateien liegen in `deploy/swarm/`; die vollständige Anleitung ist die [Ausführliche Anleitung](DEPLOYMENT.md). Die Unterschiede:

- Werte stehen in `stack.env` (Vorlage `stack.env.example`); `docker stack deploy` liest keine `.env`, also zuerst `set -a; . ./stack.env; set +a`.
- Secrets legt `create-secrets.sh` als Docker-Secrets an; die MariaDB ist immer extern.
- `PUBLISHED_PORT` ist über das Routing-Mesh auf jedem Knoten erreichbar; per Firewall nur für den Proxy öffnen.
- `TRUSTED_PROXY_CIDRS` ist das Subnetz des `ingress`-Netzes (`docker network inspect ingress --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'`).
- Erstes Ausrollen mit `BACKEND_REPLICAS=0`, warten bis `timetrack_migrate` abgeschlossen ist, dann `docker service scale timetrack_backend=1`.
- Erster Admin: `docker exec -it "$(docker ps -q -f name=timetrack_backend | head -n 1)" /app/docker-entrypoint.sh bootstrap-admin --env production`

## Aktualisieren

Kurz: **erst sichern, dann die Migration mit dem neuen Image ausführen, dann das Backend wechseln.** Compose erledigt die Migration bei `docker compose pull && docker compose --profile db up -d` selbst (ohne eigene DB das Profil weglassen). Im Swarm läuft sie nur, wenn du den Job erneut startest: `docker service update --force --image "$TIMETRACK_IMAGE" timetrack_migrate`, danach `docker service update --image "$TIMETRACK_IMAGE" timetrack_backend`. Für Produktion einen festen Tag verwenden. Alle Schritte, Prüfung und Rollback: [Aktualisieren und Migrationen](UPDATE.md).

## Sichern

Sichere `secrets/` und die Datenbank (bei der mitgelieferten: `docker compose exec -T db sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$(cat /run/secrets/tt_db_password)" --single-transaction "$MARIADB_DATABASE"' | gzip > timetrack.sql.gz`). Dateien liegen in der Datenbank und sind damit enthalten. Wiederherstellung und Backup-Skripte: [Betrieb und Backup](BETRIEB.md).

## Probleme?

- **`docker exec … bootstrap-admin`: `executable file not found in $PATH`**: Das ist keine Programmdatei im Container. Aufruf als `/app/docker-entrypoint.sh bootstrap-admin --env production` oder per `docker compose run --rm --no-deps -T backend bootstrap-admin --env production`.
- **Swarm: Variablen leer, „set TIMETRACK_IMAGE“**: `docker stack deploy` ignoriert `.env`. Zuerst `set -a; . ./stack.env; set +a`.
- **`network … could not be found`**: Alte Stack-Version. Die aktuelle `stack.yaml` laden und neu ausrollen.
- **Passkey lässt sich nicht anlegen oder nutzen**: `WEBAUTHN_RP_ID` und `WEBAUTHN_ORIGIN` müssen exakt zur Browseradresse passen (kein `www`, kein Port, `https`). Nach Änderung neu starten; nach RP-ID-Wechsel sind alte Passkeys unbrauchbar.
- **„Zu viele Anfragen“ für alle hinter dem Proxy**: `TRUSTED_PROXY_CIDRS` fehlt oder passt nicht zum Netz des Proxys. Eintragen, neu starten, 5 Minuten warten.
- **`/ready` bleibt 503**: Migration nicht fertig oder Datenbank nicht erreichbar: `docker compose logs migrate backend`.

Weitere Fälle, MariaDB-Rechte, Proxy-Details und Checklisten: **[Ausführliche Anleitung (Swarm, MariaDB-Rechte, Proxy-Details, Checklisten)](DEPLOYMENT.md)**.
