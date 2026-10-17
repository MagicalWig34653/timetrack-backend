# Aktualisieren und Datenbank-Migrationen

Kurzfassung: **erst sichern, dann die Migration mit dem neuen Image ausführen, dann das Backend wechseln.** Das Backend migriert nie von selbst.

## Wie Migrationen funktionieren

- Neue Versionen können das Datenbankschema ändern (neue Tabellen, Spalten, Indizes). Das erledigt der Befehl `migrate`; er führt nur Migrationen aus, die noch fehlen. Ein zweiter Lauf ohne neue Migrationen ändert nichts (idempotent).
- Das Backend startet mit `AUTO_MIGRATE=false` und migriert **nicht**. Passt das Schema nicht zur Version, meldet `/ready` den Status 503 und der Healthcheck lässt den neuen Container nicht „healthy" werden. Ein Update ohne Migration bleibt so folgenlos hängen, statt Fehler an Nutzer auszuliefern.
- Migrationen sind **additiv** (Hinzufügen, nicht Entfernen oder Umbenennen). Dadurch läuft die alte Version kurz mit dem neuen Schema weiter, etwa während eines Rolling-Updates oder nach einem Rollback.
- Ein „Complete" beim Migrations-Job gilt nur für das Image, mit dem er lief. Bei einer neuen Version muss er **erneut** laufen.

## Compose (ein Server)

```sh
cd deploy/compose                 # dein Ordner mit compose.yaml und .env
# 1. Backup der Datenbank (siehe unten)
# 2. in .env den neuen Tag eintragen, z. B. TIMETRACK_IMAGE=ghcr.io/magicalwig34653/timetrack-backend:0.1.1
docker compose pull
docker compose --profile db up -d         # ohne gebündelte Datenbank: ohne --profile db
docker compose logs migrate               # zeigt, welche Migrationen liefen
```

Compose startet den Migrationsdienst bei jedem `up -d` vor dem Backend (`service_completed_successfully`). Es ist keine weitere Handlung nötig.

## Swarm (Cluster)

```sh
cd <dein-Ordner-mit-stack.env>
# 1. Backup der Datenbank (siehe unten)
# 2. in stack.env den neuen Tag eintragen (TIMETRACK_IMAGE=…), dann laden:
set -a; . ./stack.env; set +a

# 3. Migration mit dem NEUEN Image; abwarten bis „Complete"
docker service update --force --with-registry-auth --image "$TIMETRACK_IMAGE" timetrack_migrate
docker service ps timetrack_migrate
docker service logs timetrack_migrate      # welche Migrationen liefen; bei Fehler: NICHT weitermachen

# 4. Backend wechseln (Rolling Update, start-first, Rückfall bei Fehlschlag)
docker service update --with-registry-auth --image "$TIMETRACK_IMAGE" timetrack_backend
docker service ps timetrack_backend
```

`--force` ist beim Migrations-Job nötig, wenn das Image unverändert bleibt (zum Beispiel bei `:latest`). Bei einem neuen Tag startet er auch ohne. Wer lieber `docker stack deploy` benutzt, setzt vorher `BACKEND_REPLICAS=0`, wartet die Migration ab und skaliert danach wieder hoch.

## Prüfen

- `https://deine-domain/ready` antwortet mit `{"status":"ok"}`.
- `docker service ps timetrack_backend` zeigt die neue Version als `Running`, die alte als `Shutdown`.
- Die PWA ist Teil des Images: Browser und Service Worker holen die neue Oberfläche beim nächsten Besuch, eine installierte PWA nach dem nächsten Start (Seite einmal neu laden).

## Zurück zur alten Version

```sh
docker service rollback timetrack_backend
# oder bewusst: --image …:<alter-Tag>
```

Das **Schema wird dabei nicht zurückgedreht**. Das ist meist unproblematisch, weil Migrationen additiv sind und die alte Version damit läuft. Ein echtes Zurückdrehen (`migrate --revert`) ist nur in Ausnahmefällen und nach einem Backup sinnvoll.

## Sicherung vor dem Update

Bei der mitgelieferten MariaDB:

```sh
docker compose exec -T db sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$(cat /run/secrets/tt_db_password)" --single-transaction "$MARIADB_DATABASE"' | gzip > timetrack-$(date +%F).sql.gz
```

Bei eigener MariaDB mit `mariadb-dump --single-transaction` auf der Datenbank. Dateien liegen in der Datenbank und sind damit enthalten. Gesamtverfahren, Wiederherstellung und die Skripte `scripts/backup.sh` und `scripts/restore.sh`: [Betrieb und Backup](BETRIEB.md).

## Welche Version?

Für Produktion einen festen Tag verwenden (`0.1.0`, `sha-<kurz>`), nicht `:latest` oder `:main`. Neue Versionen und ihre Änderungen stehen im [Änderungsprotokoll](https://github.com/MagicalWig34653/timetrack-backend/blob/main/CHANGELOG.md) und bei den GitHub-Releases. Ausführlich zu Swarm und Proxy: [Deployment-Anleitung](DEPLOYMENT.md).
