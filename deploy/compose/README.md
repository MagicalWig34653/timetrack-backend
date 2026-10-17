# Einfache Docker-Compose-Variante

Für **einen** Server ohne Swarm. Im Swarm-Cluster nutzen Sie stattdessen [`../swarm/stack.yaml`](../swarm/stack.yaml).

```sh
cd deploy/compose
cp .env.example .env            # Pflichtwerte eintragen (Image, DB_HOST, Domain, VAPID_SUBJECT)
./init-secrets.sh               # legt ./secrets/ an: DB-Passwort (Abfrage oder --generate-db-password), Speicher- und VAPID-Schlüssel
docker compose up -d            # Migration (einmalig), dann das Backend
# ohne vorhandene MariaDB (nur Einzelserver): DB_HOST=db und DB_TLS=off in .env, dann:
docker compose --profile db up -d
```

- Das Image enthält die PWA; Dateien liegen in der Datenbank (oder S3, im Admin-Bereich). Lokale Dateiablage: Volume-Zeilen in `compose.yaml` einkommentieren.
- Der Port ist `127.0.0.1:18080` oder `0.0.0.0:18080` (`BIND_ADDR`, `PUBLISHED_PORT` in `.env`); der Reverse Proxy zeigt darauf. `TRUSTED_PROXY_CIDRS` (mehrere kommagetrennt) auf das Netz des Proxys setzen.
- Erster Admin: `docker compose run --rm --no-deps -T backend bootstrap-admin --env production` (gibt einen einmaligen Einladungslink aus; nur solange noch kein Admin existiert). Per `docker exec` im laufenden Container nur mit Einstiegspunkt: `docker exec -it <container> /app/docker-entrypoint.sh bootstrap-admin --env production`; ohne `/app/docker-entrypoint.sh` scheitert es mit `executable file not found in $PATH`.
- Schritt für Schritt und mit Reverse Proxy: [`docs/INSTALLATION.md`](../../docs/INSTALLATION.md).
- Updates: `TIMETRACK_IMAGE` ändern, `docker compose pull && docker compose up -d` (die Migration läuft vor dem Backend).
- Sicherung: `secrets/` (besonders `tt_storage_secret_key`, `tt_vapid_private_key`) und die Datenbank; siehe `docs/BETRIEB.md`.
- `secrets/` und `.env` stehen in `.gitignore` und gehören nie ins Repository.

Ausführlich: [`docs/DEPLOYMENT.md`](../../docs/DEPLOYMENT.md). Getestet: `docker compose config`, ein Lauf mit der gebündelten Datenbank (Migration beendet, Backend `healthy`, `/ready` 200). Nicht getestet: externe MariaDB mit TLS, Proxy, echte Domain.
