# Aktualisieren und Datenbank-Migrationen

- **Wofür:** Eine laufende Instanz auf eine neue Version bringen, inklusive Datenbank-Migration und Rückweg.
- **Voraussetzungen:** laufende Installation ([Compose](installation/compose.md) oder [Swarm](installation/swarm.md)) und eine aktuelle [Sicherung](installation/backup.md).
- **Dauer:** 5 bis 15 Minuten.

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
cd <dein-Ordner-mit-.env>
# 1. Backup der Datenbank (siehe unten)
# 2. in .env den neuen Tag eintragen (TIMETRACK_IMAGE=…), dann laden:
set -a; . ./.env; set +a

# 3. Migration mit dem NEUEN Image; abwarten bis „Complete"
docker service update --force --with-registry-auth --image "$TIMETRACK_IMAGE" timetrack_migrate
docker service ps timetrack_migrate
docker service logs timetrack_migrate      # welche Migrationen liefen; bei Fehler: NICHT weitermachen

# 4. Backend wechseln (Rolling Update, start-first, Rückfall bei Fehlschlag)
docker service update --with-registry-auth --image "$TIMETRACK_IMAGE" timetrack_backend
docker service ps timetrack_backend
```

Während eines Rolling Updates laufen kurz alte und neue Replikas nebeneinander. Nutzer sehen dabei unter Umständen kurz den Update-Hinweis oder (selten) die Meldung „Die Anwendung konnte nicht geladen werden. Es läuft gerade ein Update.“; ein erneutes Laden nach wenigen Sekunden genügt. Dafür sollten alle Replikas dasselbe, eindeutige Image-Tag (kein `latest`) verwenden, siehe [Weiße Seite / MIME-Type](installation/probleme.md).

`--force` ist beim Migrations-Job nötig, wenn das Image unverändert bleibt (zum Beispiel bei `:latest`). Bei einem neuen Tag startet er auch ohne. Wer lieber `docker stack deploy` benutzt, setzt vorher `BACKEND_REPLICAS=0`, wartet die Migration ab und skaliert danach wieder hoch.

### Update-Skript (Swarm)

`deploy/swarm/update.sh` erledigt die Schritte 2 bis 4 in einem Lauf: Es sucht auf GHCR den neuesten `sha-<Commit>`-Tag (den Tag, der auf denselben Stand wie `latest` zeigt), schreibt ihn als `TIMETRACK_IMAGE` in deine `.env` (Sicherung als `.env.bak`), führt den Migrations-Job mit dem neuen Image aus, wartet auf „Complete“ und stellt erst danach das Backend per Rolling Update um. Schlägt die Migration fehl, bleibt das Backend unverändert.

```sh
deploy/swarm/update.sh --env-file ./.env --dry-run   # nur anzeigen, was passieren würde
deploy/swarm/update.sh --env-file ./.env             # fragt vorher nach der Datenbanksicherung
deploy/swarm/update.sh --tag sha-6c074f7 --yes            # bestimmten Stand erzwingen, ohne Rückfrage
```

Optionen: `--stack NAME` (Standard `timetrack`), `--force` (auch ohne Tag-Wechsel neu starten), `--skip-migrate`. Braucht `curl` und `docker` auf einem Swarm-Manager.

## Neues Image erzwingen (Swarm)

Swarm zieht ein Image nur, wenn sich die Zuordnung ändert. Bei einem beweglichen Tag wie `:latest` oder `:main` erzwingst du es so:

```sh
docker service update --force --with-registry-auth \
  --image ghcr.io/magicalwig34653/timetrack-backend:latest timetrack_backend
docker service inspect timetrack_backend --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'   # zeigt Tag@sha256:… des neuen Standes
```

`--image` löst den Tag beim Aufruf neu in einen Digest auf und `--force` startet die Tasks auch dann neu, wenn der Digest gleich bleibt. Die Option `--resolve-image always` gibt es nur bei `docker stack deploy` (nicht bei `docker service update`; dort heißt das Gegenstück `--no-resolve-image`). Der Stack merkt sich den beim letzten Deploy aufgelösten Digest, deshalb zieht ein erneutes `stack deploy` mit demselben Tag nicht zwingend ein neueres Image. Der sichere Weg ist `docker service update --force --image …` wie oben. Für Produktion sind feste Tags (`0.1.0`, `sha-<kurz>`) besser, dann ist der Stand immer eindeutig.

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
