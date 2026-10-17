# Sichern und Wiederherstellen

- **Wofür:** Daten und Schlüssel so sichern, dass du die Instanz nach einem Ausfall wiederherstellen kannst.
- **Voraussetzungen:** Zugriff auf den Server; für die Skripte ein Checkout oder die Dateien `scripts/backup.sh` und `scripts/restore.sh` aus dem Repository; ein Ablageort außerhalb des Servers.
- **Dauer:** Einrichtung 20 Minuten; ein Restore-Test auf einer Kopie lohnt sich einmal vor dem Ernstfall.

Das Projekt liefert **keinen Zeitplan** und verschlüsselt nichts selbst. Lege Sicherungen per cron oder systemd-Timer an und verschlüssele die Archive (z. B. `age` oder `gpg`).

## Was gesichert werden muss

| Was | Wo | Hinweis |
| --- | --- | --- |
| Datenbank | MariaDB | Enthält alle Fachdaten, Passkey-Public-Keys und, bei der Standardeinstellung, auch hochgeladene Dateien. |
| Geheimnisse | `secrets/tt_storage_secret_key`, `secrets/tt_vapid_private_key` (Compose) bzw. Docker-Secrets (Swarm: einmal im Passwortmanager ablegen, Docker zeigt Werte nie wieder) | **Nicht** im Datenbank-Archiv. Ohne den Speicherschlüssel sind gespeicherte S3-Zugangsdaten verloren; ohne VAPID-Schlüssel müssen Geräte Push neu abonnieren. |
| Konfiguration | `.env` / `stack.env`, Proxy-Konfiguration | Dieselbe `WEBAUTHN_RP_ID` wie vorher, sonst sind Passkeys wertlos. |
| S3-Objekte | Bucket | Nur wenn du S3 nutzt; getrennt sichern. |
| Lokale Dateien | Volume | Nur wenn du „Lokal“ aktiviert hast. |

## Schnell: Datenbank-Dump

Mitgelieferte MariaDB (Compose):

```sh
docker compose exec -T db sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$(cat /run/secrets/tt_db_password)" --single-transaction "$MARIADB_DATABASE"' | gzip > timetrack-$(date +%F).sql.gz
```

Eigene MariaDB: `mariadb-dump --single-transaction` gegen die Datenbank, am besten mit einem eigenen Benutzer mit Leserechten ([Eigene MariaDB](mariadb.md)).

## Mit den Skripten

`scripts/backup.sh` erzeugt ein Verzeichnis `timetrack-backup-<UTC>` mit Datenbank-Dump, Prüfsummen und Manifest; `scripts/restore.sh` prüft die Prüfsummen vor jeder Änderung und überschreibt keine nicht leere Zieldatenbank ohne `--force-overwrite`. Beispiel für eine MariaDB auf einem anderen Host:

```sh
DB_HOST=db.internal.example.test DB_USER=ttbackup DB_PASSWORD_FILE=/pfad/zur/datei \
  scripts/backup.sh --driver mariadb --db-name timetrack --out /backups
```

Alle Optionen, das Archivformat und die Nachweise: [Betrieb und Backup](../BETRIEB.md), Abschnitte 1 bis 4.

## Wiederherstellen

1. Backend anhalten (Swarm: `docker service scale timetrack_backend=0`; Compose: `docker compose stop backend`).
2. `scripts/restore.sh --from /backups/timetrack-backup-<UTC> --db-name timetrack` gegen eine leere Datenbank (Optionen wie beim Backup).
3. Mit den **ursprünglichen** Geheimnissen und derselben `WEBAUTHN_RP_ID` wieder starten; bei einem neueren Image zuerst die Migration ([Aktualisieren](../UPDATE.md)).

## Gelöschte Konten bleiben in alten Sicherungen

Löscht jemand sein Konto (Selbstlöschung oder durch den Admin), verschwinden die Daten aus der Datenbank, **nicht** aus bereits angelegten Archiven. Bewahre Sicherungen nur so lange auf, wie nötig, und lösche alte Archive regelmäßig. Spielst du ein altes Archiv ein, sind gelöschte Konten wieder da.

## Prüfen

Spiele eine Sicherung einmal auf einer Kopie ein und melde dich an. Eine ungeprüfte Sicherung ist keine.
