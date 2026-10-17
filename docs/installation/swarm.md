# Docker Swarm (Cluster)

- **Wofür:** Timetrack als Swarm-Stack mit Docker-Secrets, Rolling-Updates und eigener MariaDB betreiben.
- **Voraussetzungen:** Docker mit aktivem Swarm (`docker info` zeigt `Swarm: active`), Zugriff auf einen Manager-Knoten, eine [vorbereitete MariaDB](mariadb.md), ein Reverse Proxy ([Reverse Proxy und TLS](proxy.md)), `openssl` und `curl`.
- **Dauer:** etwa 45 Minuten. Für einen einzelnen Server ist [Docker Compose](compose.md) einfacher.

Der Stack enthält keinen Datenbank-Container: Die MariaDB ist immer extern. Das Image enthält die Web-App; Dateien liegen standardmäßig in der Datenbank, deshalb braucht der Stack keine Volumes und keine feste Knotenbindung. Dies ist die Kurzfassung der Schritte; die ausführliche Referenz mit allen Hintergründen, Sicherheits- und Go-Live-Checkliste steht in der [Deployment-Anleitung](../DEPLOYMENT.md).

## 1. Dateien holen

Auf dem Manager-Knoten:

```sh
mkdir -p ~/timetrack-deploy && cd ~/timetrack-deploy
B=https://github.com/MagicalWig34653/timetrack-backend/raw/main/deploy/swarm
curl -fsSLO $B/stack.yaml && curl -fsSLO $B/create-secrets.sh && curl -fsSL -o stack.env $B/stack.env.example
chmod 600 stack.env && chmod +x create-secrets.sh
```

## 2. Datenbank vorbereiten

Lege Datenbank und Benutzer an: [Eigene MariaDB vorbereiten](mariadb.md). Das Passwort erzeugt der nächste Schritt.

## 3. Secrets anlegen

```sh
./create-secrets.sh --dry-run --generate-db-password /root/tt-db-password.txt      # Probelauf, legt nichts an
mkdir -m 700 /root/tt-keys
./create-secrets.sh --generate-db-password /root/tt-db-password.txt --save-generated /root/tt-keys
```

Das Skript legt `tt_db_password`, `tt_storage_secret_key` und `tt_vapid_private_key` als Docker-Secrets an, zeigt nie Werte an und überschreibt nie vorhandene Secrets. Trage das Passwort aus `/root/tt-db-password.txt` in das `CREATE USER` der Datenbank ein, übernimm die Dateien aus `/root/tt-keys` in den Passwortmanager und lösche beide danach. Weitere Optionen (`--smtp-password-file`, `--oidc-client-secret-file`, `--prefix`) und die Folgen eines Verlusts: [Deployment-Anleitung](../DEPLOYMENT.md), Abschnitt 4.

Prüfen: `docker secret ls` zeigt `tt_db_password`, `tt_storage_secret_key`, `tt_vapid_private_key`.

## 4. `stack.env` ausfüllen

Pflicht sind die ersten Zeilen: `TIMETRACK_IMAGE`, `DB_HOST`, `PUBLIC_BASE_URL`, `WEBAUTHN_RP_ID`, `WEBAUTHN_ORIGIN`, `VAPID_SUBJECT`. Setze für Produktion eine feste Version:

```
TIMETRACK_IMAGE=ghcr.io/magicalwig34653/timetrack-backend:0.1.0
```

Außerdem wichtig:

- `PUBLISHED_PORT` (Standard `18080`) ist über das Routing-Mesh auf **jedem Knoten** erreichbar. Öffne ihn per Firewall nur für den Reverse Proxy, sonst könnten Clients `X-Forwarded-For` fälschen.
- `TRUSTED_PROXY_CIDRS` ist das Subnetz des `ingress`-Netzes:

  ```sh
  docker network inspect ingress --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
  ```

- `BACKEND_REPLICAS=0` beim ersten Ausrollen (nächster Schritt).

Alle Variablen: [Konfigurationsreferenz](konfiguration.md). `docker stack deploy` liest keine `.env`; die Datei wird von der Shell eingelesen, also keine Leerzeichen um `=` und Werte mit Leerzeichen in Anführungszeichen.

## 5. Ausrollen: Migration, dann Start

Swarm kennt keine Reihenfolge zwischen Diensten. Deshalb startet das Backend zuerst mit 0 Replikaten:

```sh
set -a; . ./stack.env; set +a
docker stack config -c stack.yaml > /dev/null && echo "Konfiguration ok"

BACKEND_REPLICAS=0 docker stack deploy --with-registry-auth -c stack.yaml timetrack
docker service ps timetrack_migrate          # warten bis Complete
docker service logs timetrack_migrate        # bei Failed: Ursache beheben, NICHT weitermachen

docker service scale timetrack_backend=1
docker service ps timetrack_backend          # Running, nach ca. 30 s healthy
```

Wichtig: `docker stack deploy` setzt die Replikazahl aus der Datei zurück; für spätere Läufe gilt `BACKEND_REPLICAS` aus `stack.env`. Schlägt die Migration fehl, hilft [Probleme und Lösungen](probleme.md); nach der Korrektur `docker service update --force timetrack_migrate`.

Prüfen (auf dem Knoten, auf dem das Backend läuft):

```sh
docker exec "$(docker ps -q -f name=timetrack_backend | head -n 1)" curl -fsS http://127.0.0.1:8080/ready
```

## 6. Reverse Proxy

Der Proxy verbindet sich mit `http://<Knoten-IP>:18080`. Beispiele für nginx, Traefik und Caddy: [Reverse Proxy und TLS](proxy.md).

## 7. Weiter

Ersten Admin anlegen und einrichten: **[Ersteinrichtung](ersteinrichtung.md)** (dort steht auch der Swarm-Befehl für `bootstrap-admin`).

## Aktualisieren

Sichern, dann Migration mit dem neuen Image, dann Backend wechseln: [Aktualisieren und Migrationen](../UPDATE.md).

## Grenzen

Stack und Anleitung sind nicht auf einem echten Swarm erprobt (geprüft sind `docker stack config` und das Containerverhalten). Die vollständige Liste: [Deployment-Anleitung](../DEPLOYMENT.md), Abschnitt 17.
