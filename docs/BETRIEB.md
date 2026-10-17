# Betrieb: Backup, Restore, Swarm-Stack, Reverse Proxy

Stand: 17.10.2026 (Paket B3, ergänzt durch D2). Schritt-für-Schritt-Anleitung für die Produktionsinstanz (Datenbank anlegen, Secrets, Proxy-Beispiele, erster Admin, Go-Live): [DEPLOYMENT.md](DEPLOYMENT.md); dieses Dokument bleibt maßgeblich für Backup, Restore und Hintergründe. Dieses Dokument ist maßgeblich für Sicherung, Wiederherstellung und den produktionsnahen
Stack. Es beschreibt, was die Skripte und die Stack-Datei leisten, was ausgeführt und belegt wurde und was offen bleibt
(Abschnitt 8). Belegter Stand insgesamt: [STATUS.md](STATUS.md); lokale Entwicklung: [../EINRICHTUNG.md](../EINRICHTUNG.md);
Architektur der Speicherung: [ARCHITEKTUR.md](ARCHITEKTUR.md), Abschnitt 6.

## 1. Was gesichert werden muss

| Bestandteil | Wo | Sicherung | Im Backup-Archiv? |
| --- | --- | --- | --- |
| Datenbank (alle Fachdaten, Metadaten, Sitzungs-Hashes, Passkey-Public-Keys, DB-Blobs) | MariaDB oder SQLite-Datei | `scripts/backup.sh` | ja |
| Lokale Dateien (Speicherregel „local“) | Verzeichnis aus `storage_settings.local_path` | `scripts/backup.sh --local-files` | ja (`files.tar.gz`) |
| S3-Objekte (Speicherregel „s3“) | Bucket | Werkzeug der Wahl (Abschnitt 3), versioniertes Bucket | **nein** |
| `STORAGE_SECRET_KEY` | Docker-Secret `tt_storage_secret_key` | getrennt, z. B. Passwortmanager | **nein, nie** |
| `VAPID_PRIVATE_KEY` | Docker-Secret `tt_vapid_private_key` | getrennt | **nein, nie** |
| DB-Passwort, `SMTP_PASSWORD`, `OIDC_CLIENT_SECRET` | Docker-Secrets | getrennt (wiederherstellbar durch neues Passwort, kein Datenverlust) | **nein, nie** |
| Stack-Variablen (`stack.env`), Proxy-Konfiguration | Betreiber | im Konfigurations-Repository des Betreibers | nein |
| Gebaute PWA, Image | Registry, PWA-Repo | reproduzierbar aus den Quellen | nein |

Folgen fehlender Secrets:

- **`STORAGE_SECRET_KEY` verloren**: das gespeicherte S3-Secret ist nicht mehr entschlüsselbar, S3-Dateien sind unlesbar
  (HTTP 503 `storage_unavailable`), bis ein Admin die S3-Zugangsdaten neu einträgt (mit neuem Schlüssel). DB- und
  lokale Dateien sind nicht betroffen. Belegt in `scripts/test-restore.sh` (falscher Schlüssel).
- **`VAPID_PRIVATE_KEY` verloren**: bestehende Push-Abonnements sind an den Schlüssel gebunden; Push funktioniert erst nach
  neuem Schlüssel und erneutem Abonnieren der Geräte. Sonst keine Datenfolgen.
- **Passkeys** hängen an `WEBAUTHN_RP_ID`, nicht an einem Secret. Die RP-ID muss nach einer Wiederherstellung identisch sein.

Das Archiv enthält personenbezogene Daten (Zeiten, Abwesenheiten, Anhänge) und Hashes von Sitzungs-Tokens. Es gehört
verschlüsselt (z. B. `age` oder `gpg`, Wahl des Betreibers) und mit Zugriffsrechten `go-rwx` abgelegt; die Skripte setzen
`chmod -R go-rwx` auf das Backup-Verzeichnis, verschlüsseln aber nicht selbst.

## 2. Backup

```sh
# SQLite (Online-Backup über die SQLite-Backup-API, Backend darf laufen)
scripts/backup.sh --driver sqlite --sqlite-path /pfad/timetrack.sqlite --local-files /pfad/files --out /backups

# MariaDB im Container (mariadb-dump läuft im Container, Root-Passwort bleibt dort, z. B. Dev-Compose)
scripts/backup.sh --driver mariadb --db-container timetrack-dev-db-1 --db-name timetrack --local-files /pfad/files --out /backups

# MariaDB auf einem anderen Host (Client auf dem Backup-Host; Zugangsdaten nur über die Umgebung des Aufrufs)
DB_HOST=db.example.test DB_USER=backup DB_PASSWORD_FILE=/pfad/zur/datei scripts/backup.sh --driver mariadb --db-name timetrack --out /backups
```

Ergebnis ist ein Verzeichnis `timetrack-backup-<UTC>` mit:

| Datei | Inhalt |
| --- | --- |
| `MANIFEST` | flache `key=value`-Zeilen: Format, Zeit, Treiber, DB-Name, Serverversion, Anzahl und Hash der Migrationen, lokaler Wurzelpfad, Zähler je Speicherart, S3-Endpunkt/Bucket (kein Secret) |
| `db.sql.gz` / `db.sqlite.gz` | `mariadb-dump --single-transaction --quick --hex-blob` bzw. SQLite-`.backup` (mit `integrity_check` geprüft) |
| `files.tar.gz`, `files.list`, `files.sha256` | lokale Dateien, Dateiliste und SHA-256 je Datei (Liste und Archiv stammen aus derselben Dateiliste) |
| `migrations.txt`, `row_counts.tsv` | angewandte Fluent-Migrationen, Zeilenzahl je Tabelle |
| `SHA256SUMS` | Prüfsummen aller anderen Dateien |

Konsistenz DB ↔ Dateien: lokale Dateien werden einmalig geschrieben (temp + rename) und erst nach dem Löschen der Zeile
entfernt. Das Skript sichert **zuerst die Datenbank, dann die Dateien** und bricht ab, wenn eine Zeile `stored_files`
(`backend=local`, `state=stored`) kein Objekt im Archiv hat (Upload/Löschen lief dazwischen); dann Schreiber anhalten
oder wiederholen (`--allow-inconsistent` nur bewusst). Zusätzliche Dateien ohne Zeile sind harmlos (Waisen). Die
Zeilenzahlen in `row_counts.tsv` werden unmittelbar nach dem Dump gezählt; bei laufendem Betrieb können sie von der
Momentaufnahme abweichen. Deshalb prüft `restore.sh` sie nur mit `--strict-counts` hart; Prüfsummen und Migrationen
immer. Für ein exaktes Abbild das Backend kurz anhalten (`docker service scale timetrack_backend=0`).

Nicht enthalten und nicht per Skript gesichert: S3-Objekte, alle Secrets (Abschnitt 1). Die Skripte schreiben keine
Secret-Werte in Archiv, Manifest oder Logs (belegt: der Test sucht den Speicher-Schlüssel, das S3-Secret und das Sitzungs-Token im entpackten Archiv und findet sie nicht).

### S3-Objekte sichern

Das Projekt bringt dafür bewusst keine Abhängigkeit mit. Die Objekte sind unveränderlich (Schlüssel = Datei-ID, nur
Schreiben und Löschen), daher genügt ein einseitiger Abgleich in ein zweites Bucket oder Verzeichnis, ohne Löschen am Ziel,
oder ein versioniertes Bucket mit Lebenszyklusregel. Beispiele (nicht ausgeführt, Werkzeug und Zugangsdaten sind Sache des Betreibers):

```sh
aws s3 sync s3://timetrack-prod s3://timetrack-prod-backup --endpoint-url https://s3.example.test
mc mirror --preserve myminio/timetrack-prod backupminio/timetrack-prod-backup
rclone copy s3src:timetrack-prod s3dst:timetrack-prod-backup
```

Reihenfolge: **zuerst Datenbank-Backup, dann S3-Abgleich** (so existiert zu jeder gesicherten Zeile ein Objekt; Objekte ohne
Zeile sind Waisen). Aus dem Manifest (`s3_endpoint_bucket`, `files_s3_rows`) ergibt sich, welches Bucket zum Stand gehört.

## 3. Restore

Backend vorher anhalten (Swarm: `docker service scale timetrack_backend=0`; SQLite-Datei nie unter einem laufenden Prozess ersetzen).

```sh
# SQLite
scripts/restore.sh --from /backups/timetrack-backup-<UTC> --sqlite-path /pfad/timetrack.sqlite --files-target /pfad/files
# MariaDB (Container oder Host-Modus wie beim Backup; die Zieldatenbank muss leer sein oder nicht existieren)
scripts/restore.sh --from /backups/timetrack-backup-<UTC> --db-container timetrack-dev-db-1 --db-name timetrack --files-target /pfad/files
```

Ablauf und Schutzmaßnahmen:

1. Prüfsummen (`SHA256SUMS`), Manifest-Format und Migrationsliste werden geprüft, **bevor** etwas verändert wird. Ein manipuliertes Archiv bricht ab.
2. Alle Ziele werden vorab geprüft: Eine nicht leere Datenbank, SQLite-Datei oder ein nicht leeres Dateiverzeichnis wird **nicht**
   überschrieben, ohne `--force-overwrite`. Mit dem Schalter wird die MariaDB-Datenbank per `DROP DATABASE` ersetzt; die SQLite-Datei
   und das Dateiverzeichnis werden nur umbenannt (`*.pre-restore-<UTC>`), nie gelöscht.
3. Datenbank und Dateien werden in einem Lauf wiederhergestellt; danach werden Migrationsliste, Dateiprüfsummen (und mit `--strict-counts` die Zeilenzahlen) gegen das Manifest geprüft. Bei Abweichung endet das Skript mit Fehler: Backend nicht auf diese Daten starten.
4. Backend mit den **ursprünglichen** Secrets (`STORAGE_SECRET_KEY`, VAPID) und derselben `WEBAUTHN_RP_ID` starten. Bei einem neueren Image zuerst den Migrationsschritt ausführen (Abschnitt 5).

Wichtig für lokale Dateien: Das Backend bindet jede Datei beim Schreiben an den **echten Pfad** des Speicherverzeichnisses
(`stored_files.storage_location = local:<realpath>`). Wird auf einen anderen Pfad wiederhergestellt, sind diese Dateien
unlesbar (`storage_unavailable`), bis `storage_location` per SQL umgeschrieben wird. Deshalb: gleicher Pfad. Das Skript warnt bei Abweichung.
Sitzungen bleiben nach dem Restore gültig (sie liegen in der Datenbank); nach einem Vorfall mit Kompromittierung Sitzungen widerrufen.
S3: Bucket und Objekte getrennt wiederherstellen (Abschnitt 2); das S3-Secret in der Datenbank wird mit dem ursprünglichen `STORAGE_SECRET_KEY` entschlüsselt.

## 4. Restore-Nachweis (`scripts/test-restore.sh`)

`scripts/test-restore.sh [sqlite|mariadb|all]` legt je Treiber über das echte Backend synthetische Daten an, sichert, löscht,
stellt wieder her und prüft. Ressourcen: Datenbank `timetrack_restore_test` im Dev-Container `timetrack-dev-db-1`
(wird am Ende gelöscht), Backend-Wegwerfinstanzen auf den Ports 18150 (SQLite) und 18151 (MariaDB), temporäre Verzeichnisse,
eigene Objekte im S3Mock (werden per API wieder gelöscht). Voraussetzung: `swift build --build-system native --product App`.

Geprüft je Treiber (18 Prüfpunkte): CLI `bootstrap-admin`; Konto/Sitzung per SQL gesät; Speicherregeln (≤ 2 KiB Datenbank, ≤ 200 000 B lokal,
größer S3 gegen S3Mock); drei PDF-Anhänge an einer Abwesenheit; zwei Kalendertage; Backup bei laufendem Backend; Ablehnung des
Restores in ein nicht leeres Ziel; Ablehnung eines manipulierten Archivs; Löschen von Datenbank und Dateien; Restore mit `--strict-counts`;
Backend-Start mit `AUTO_MIGRATE=false` und `/ready` = 200; alte Sitzung gültig; alle drei Anhänge über die API mit identischem SHA-256;
Änderung nach dem Backup ist weg; mit **falschem** `STORAGE_SECRET_KEY` ist die S3-Datei nicht lesbar, DB- und lokale Datei schon.
Ergebnis des letzten Laufs: Abschnitt 8 und `handoffs/B3.md`.

Nicht belegt: echtes S3 (nur S3Mock, nur der Zugangsdaten-Pfad; der Objektinhalt liegt nicht im Backup), Daten im Produktionsumfang
(Testdaten sind klein: Archiv ca. 140 KiB), Last während des Backups (der Dump lief bei ruhigem Backend), Wiederherstellung unter Linux amd64,
Restore in eine andere MariaDB-Hauptversion, SQLite-Backup eines Docker-Volumes (Hinweis: die Backend-Image enthält keine `sqlite3`-CLI; das Skript läuft auf dem Host
gegen einen Host-Pfad oder ein Bind-Mount, für ein benanntes Volume ein Hilfscontainer mit `sqlite3`, nicht ausgeführt).

## 5. Swarm-Stack (`deploy/swarm/stack.yaml`)

Produktionsvorlage ohne Datenbank-Container (Stand D2: zusätzlich dokumentierte Variablen, Skript `create-secrets.sh`), **nicht in einem Swarm deployt** (kein Swarm vorhanden, nichts provisioniert). Geprüft ist die
Darstellung per `docker stack config` und das Containerverhalten per `scripts/test-image-smoke.sh` (Abschnitt 5.5).

Dienste: `migrate` (einmaliger Job, `replicated-job`, nur DB-Zugang) und `backend` (`AUTO_MIGRATE=false`).
Das Image kommt aus `TIMETRACK_IMAGE` (kein `build:`). Die Datenbank ist die vorhandene MariaDB (`DB_HOST`); SQLite ist im
Swarm nicht vorgesehen (eine Datei darf nicht von Replikaten geteilt werden).

### 5.1 Voraussetzungen (vom Betreiber)

```sh
# Image bauen und in eine vom Swarm erreichbare Registry legen (Beispiel; Multi-Arch siehe Abschnitt 7)
docker buildx build --platform linux/amd64,linux/arm64 -t registry.example.test/timetrack-backend:1.0.0 --push .

# Overlay-Netz, an dem auch der Reverse Proxy hängt (Name per PROXY_NETWORK änderbar)
docker network create --driver overlay --attachable timetrack-proxy

# Secrets: bequemer und mit Prüfungen per deploy/swarm/create-secrets.sh (--dry-run, überschreibt nie). Manuell (Werte über stdin, nie als Argument):
openssl rand -base64 32                    | docker secret create tt_storage_secret_key -
openssl ecparam -name prime256v1 -genkey -noout | openssl ec -outform DER 2>/dev/null | tail -c +8 | head -c 32 | base64 | tr '+/' '-_' | tr -d '=\n' | docker secret create tt_vapid_private_key -
docker secret create tt_db_password /pfad/zur/datei-mit-dem-db-passwort
```

Außerdem: leere Datenbank samt Benutzer auf dem MariaDB-Server, die gebaute PWA ist im Image enthalten (kein Kopieren auf den Knoten), und
`deploy/swarm/stack.env.example` nach `stack.env` kopieren und ausfüllen. Docker-Secrets sind unveränderlich: zum Rotieren neues Secret
mit neuem Namen anlegen, Stack-Datei anpassen, neu ausrollen. `STORAGE_SECRET_KEY` nie rotieren, ohne S3-Zugangsdaten neu einzutragen.

### 5.2 Erstes Deployment und Updates

```sh
set -a; . deploy/swarm/stack.env; set +a
docker stack config -c deploy/swarm/stack.yaml >/dev/null        # Darstellung prüfen
docker stack deploy --with-registry-auth -c deploy/swarm/stack.yaml timetrack
docker service logs timetrack_migrate                            # je Migration eine Zeile "Finished prepare"; Job-Status "Complete"
```

Update auf ein neues Image (empfohlener Ablauf, weil Swarm keine Reihenfolge zwischen Diensten kennt):

1. Backup (Abschnitt 2).
2. Migration zuerst (Erstinstallation: `BACKEND_REPLICAS=0` deployen, Migration abwarten, dann `docker service scale timetrack_backend=1`, siehe DEPLOYMENT.md Abschnitt 7): `docker service update --force --image "$NEUES_IMAGE" timetrack_migrate` (startet den Job neu; so in der Docker-Dokumentation beschrieben, hier nicht in einem Swarm erprobt), Ende abwarten (`docker service ps timetrack_migrate`: `Complete`). Der Job ist idempotent; ohne offene Migrationen tut er nichts.
3. Dann Backend: `docker service update --image "$NEUES_IMAGE" timetrack_backend` (oder `docker stack deploy` mit neuer `TIMETRACK_IMAGE`).

Das Backend meldet `/ready` = 503, solange Migrationen offen sind oder die DB fehlt; der Container-Healthcheck nutzt `/ready`.
Ein neues Image ohne durchgeführte Migration wird deshalb nie „healthy“, der Rollout (`update_config`: eine Instanz,
`start-first`, 60 s Überwachung, `failure_action: rollback`) stoppt und rollt zurück. Nachteil: Fällt die Datenbank aus, werden die
Tasks ebenfalls ungesund und neu gestartet (Neustartschleife mit Obergrenze, kommt mit der DB zurück).

Rollback des Images ist ohne Datenverlust möglich, **Rollback des Schemas nicht** (es gibt keinen automatisierten Migrationsrückweg im Betrieb): dafür
Restore aus dem Backup vor Schritt 2. Während Schritt 2→3 läuft das alte Backend kurz gegen das neue Schema; das ist nur sicher, wenn Migrationen
abwärtskompatibel (additiv) sind. Das ist **keine geprüfte Zusage** des Projekts; bei zerstörenden Migrationen das Backend vorher auf 0 skalieren.

### 5.3 Konfiguration der Vorlage

- **Healthcheck**: `curl /ready` alle 15 s, 5 Versuche, 30 s Anlaufzeit (Image-Healthcheck ist `/health`).
- **Ressourcen**: Backend 1 CPU / 768 MiB (Reservierung 0,1 CPU / 128 MiB), Migrationsjob 1 CPU / 512 MiB. **Nicht gemessen**: Uploads bis 64 MiB werden im Speicher gesammelt; die Werte sind Startwerte, unter Last zu prüfen.
- **Update/Rollback**: siehe 5.2; `rollback_config` mit `start-first`.
- **Logging**: `json-file` mit Rotation (10 MiB × 5), Backend loggt auf stdout. Für zentrale Logs Treiber (z. B. `gelf`, `syslog`) pro Dienst austauschen. Invite-URLs werden nicht protokolliert (Backend ersetzt die Standard-Logging-Middleware).
- **Volumes**: keine. Die PWA ist im Image (`/srv/pwa`), Dateien liegen in der Datenbank (Admin: Speicherregel „alles → Datenbank“, globales Upload-Limit). Die Speicherart „Lokal“ ist im Stack nicht verfügbar; wer sie braucht, ergänzt selbst einen Bind-Mount (dann knotenfeste Platzierung über `BACKEND_PLACEMENT`). Keine Knotenbindung nötig.
- **Härtung**: `read_only: true` mit `tmpfs /tmp`, Benutzer uid 10001 (aus dem Image). Keine veröffentlichten Ports; der Proxy erreicht `http://backend:8080` über das Overlay-Netz `PROXY_NETWORK`.
- **Replikate**: Standard 1. MariaDB erlaubt mehrere; der Erinnerungs-Scheduler nutzt eine Lease. Eine globale `auth_lock`-Serialisierung begrenzt den Durchsatz der Anmeldung (bekannt, `STATUS.md`).

### 5.4 Secrets: `*_FILE`-Konvention

**Das Backend liest nur Umgebungsvariablen** (`Configuration.swift`, `StorageService.swift`, `NotificationRuntime.swift`); `*_FILE` wird
vom Swift-Code **nicht** unterstützt. Betroffen: `DB_PASSWORD`, `STORAGE_SECRET_KEY`, `VAPID_PRIVATE_KEY`, `SMTP_PASSWORD`, `OIDC_CLIENT_SECRET`.
Gelöst ohne Swift-Änderung durch den Image-Einstiegspunkt `scripts/docker-entrypoint.sh` (liegt im Image als `/app/docker-entrypoint.sh`): Er liest
für diese fünf Variablen `<NAME>_FILE`, exportiert `<NAME>` und führt dann `/app/App` aus; beide gleichzeitig gesetzt sind ein Fehler (Exit 64),
eine nicht lesbare Datei ebenfalls (Exit 66). Die Werte erscheinen weder auf der Konsole noch in Argumenten. Die `*_FILE`-Variable wird entfernt.
Die kleinste Alternative im Swift-Code wäre eine Hilfsfunktion in `Configuration`, die jede Variable zuerst als Datei liest; sie wurde nicht umgesetzt (kein Eingriff in `Sources/`),
weil der Einstiegspunkt sie überflüssig macht.

### 5.5 Container-Nachweis (`scripts/test-image-smoke.sh`)

Startet das gebaute Image mit `--read-only`, `tmpfs /tmp`, Secrets als Dateien unter `/run/secrets/`, gegen eine Wegwerf-Datenbank
`timetrack_smoke_test` im Dev-MariaDB (Netz `timetrack-dev_default`, Container `timetrack-dev-b3-smoke`, Port 18152). Geprüft: Migrationsjob füllt die leere DB
und ist beim zweiten Lauf ein No-op; Exit 64/66 des Einstiegspunkts; `/health`, `/ready`, Docker-Healthcheck „healthy“;
`/.well-known/apple-app-site-association` antwortet 200 ohne Redirect; alle drei Secrets liegen mit Dateilänge in der Prozessumgebung, `*_FILE` nicht; uid 10001; kein Secret im Log.
Nicht geprüft: echter Swarm (Secrets-Einhängung, `replicated-job`, Rollback-Verhalten, Overlay-Netz), `docker stack deploy`.

## 6. Reverse Proxy (nicht provisioniert; Anforderungen)

Der Proxy terminiert TLS und leitet an `http://backend:8080` (Overlay `timetrack-proxy`). Anforderungen:

| Thema | Anforderung |
| --- | --- |
| Host/TLS | Genau der Host aus `PUBLIC_BASE_URL`/`WEBAUTHN_ORIGIN` (HTTPS). Das Backend baut OAuth-/Redirect-URLs aus `PUBLIC_BASE_URL`, nicht aus dem Host-Header. Das Sitzungs-Cookie ist `Secure`, wenn `PUBLIC_BASE_URL` mit `https` beginnt. HSTS am Proxy setzen. |
| `/.well-known/` | **Ohne Redirect, ohne Authentifizierung und ohne Umschreiben** durchreichen: `/.well-known/apple-app-site-association` (Passkeys der Apps; Apple verlangt `200` direkt, `application/json`, kein Redirect; bei leerem `APPLE_APP_IDS` antwortet das Backend 404) sowie `/.well-known/oauth-*` (MCP/OAuth). Kein SPA-Fallback und keine Cache-Überschreibung. |
| Pfade | `/api/`, `/oauth/`, `/mcp`, `/health`, `/ready`, `/.well-known/` und alle PWA-Pfade gehen an das Backend (es liefert die PWA aus). `/health` und `/ready` besser nicht öffentlich. |
| Uploads | Anfragekörper bis **64 MiB** Datei + 64 KiB Multipart-Aufschlag (`StorageLimits`): Proxy-Limit mindestens 65 MiB (z. B. nginx `client_max_body_size 65m;`), Timeouts für Lesen/Senden ≥ 120 s, Request-Buffering aus oder ausreichend Platz. Das Backend sammelt den Körper im Speicher (siehe Ressourcen). |
| WebSocket | Nicht erforderlich. MCP ist Streamable HTTP, nur `POST`, JSON-Antworten (kein SSE); keine Upgrade-Header nötig. |
| Header | Der Proxy muss `X-Forwarded-For` **anhängen** (Standard bei nginx `$proxy_add_x_forwarded_for`, Traefik, Caddy) oder ersetzen, nie unverändert durchreichen; alternativ `X-Real-IP` setzen (dann `TRUSTED_PROXY_HEADER=X-Real-IP`, ein einzelner Wert, vom Proxy überschrieben). Das Backend wertet den Header nur aus, wenn `TRUSTED_PROXY_CIDRS` gesetzt ist (nächster Abschnitt). |

### Client-IP und Rate-Limit (ADR-0018)

Alle IP-bezogenen Grenzen (Auth-Middleware, OAuth, OIDC) verwenden eine zentrale Auflösung (`Request.clientRateLimitKey`, `Sources/TimetrackKit/TrustedProxies.swift`).
Ohne Konfiguration gilt wie bisher die Socket-Gegenstelle. **Hinter einem Proxy muss `TRUSTED_PROXY_CIDRS` gesetzt werden**, sonst teilen alle Clients
einen Zähler (60 Ereignisse je 5 Minuten, Schlüssel `ip:<Hash>`) und ein Angreifer sperrt die Anmeldung für alle. Die Pro-Handle-Grenzen (15 je 5 Minuten) gelten unabhängig davon.

Einrichtung:

1. Netz des Proxys bestimmen, so eng wie möglich. Im Swarm ist das das Subnetz des Overlay-Netzes `PROXY_NETWORK`:
   `docker network inspect timetrack-proxy --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'`. Ein ganzes Netz zu vertrauen ist nur dann sicher, wenn dort ausschließlich der Proxy (und keine
   anderen, von Angreifern erreichbaren Dienste) Verbindungen zum Backend aufbauen kann. Besser ist ein eigenes Netz nur für Proxy und Backend oder die feste Proxy-Adresse als `/32`.
2. `TRUSTED_PROXY_CIDRS=<Netz>[,<Netz>...]` in `stack.env` (bzw. `.env`) setzen; optional `TRUSTED_PROXY_HEADER`. Ein ungültiger Eintrag verhindert den Start (Fehler nennt den Schlüssel).
3. Prüfen: Zwei Clients nacheinander gegen den Proxy (`POST /api/v1/auth/login/options`, mehr als 60-mal von Client A) dürfen Client B nicht sperren.

Regeln der Auflösung:

- Gegenstelle nicht in der Liste (oder Liste leer): Header werden vollständig ignoriert (kein Spoofing von außen).
- Gegenstelle vertrauenswürdig: `X-Forwarded-For` wird **von rechts** gelesen; vertrauenswürdige Hops werden übersprungen, die erste nicht vertrauenswürdige Adresse ist der Client.
  Vom Angreifer vorangestellte Einträge links davon werden nie gelesen. Fehlt der Header, ist ein Eintrag keine IP (Ports `1.2.3.4:5` und `[v6]:5` werden toleriert) oder sind alle Hops vertrauenswürdig, gilt die Gegenstelle.
- IPv4-gemappte IPv6-Adressen (`::ffff:a.b.c.d`) werden zu IPv4. Für das Rate-Limit werden IPv6-Clients nach **/64** zusammengefasst (ein Anschluss besitzt üblicherweise ein ganzes /64; sonst ließe sich die Grenze mit beliebigen Adressen umgehen). IPv4 bleibt pro Adresse. Hinter CGNAT teilen sich viele Nutzer eine IPv4-Adresse und damit einen Zähler; das ist hier nicht lösbar.
- `/0`-Netze (`0.0.0.0/0`, `::/0`) werden abgelehnt (Startfehler), weil sie jeden Absender als Proxy behandeln würden.
- Im Swarm kann das Routing Mesh die Quelladresse verändern (SNAT); der Proxy sollte im Overlay-Netz direkt angesprochen werden, sonst sieht das Backend nur eine Mesh-Adresse.

Weiterhin sinnvoll: zusätzliches Rate-Limit am Proxy für `/api/v1/auth/`, `/api/v1/me/recovery/`, `/oauth/`, und das Backend nicht öffentlich veröffentlichen.
Nicht geprüft: Verhalten mit echtem Proxy (nginx/Traefik) und Swarm-Overlay; geprüft sind die Auflösung und ein HTTP-Test mit Socket-Gegenstelle 127.0.0.1 als Proxy.

## 7. amd64-Build (Emulation) und Multi-Arch

Entwicklungsrechner ist arm64; Produktionsziele sind amd64 und arm64. `scripts/dev-env.sh build-multiarch` baut beide Plattformen per `docker buildx`
(Builder `colima`, QEMU für die Fremdarchitektur) und schreibt ein OCI-Archiv (nicht gepusht). `QEMU_LIMIT=1` (Standard im Skript) bindet SwiftPM unter
Emulation an wenige CPUs und `-j 2`, weil das Manifest-Laden sonst mit `SIGILL` abstürzt; die Auflösung der Abhängigkeiten läuft auf der nativen Plattform.

```sh
scripts/dev-env.sh build-multiarch                       # amd64 + arm64, OCI-Archiv in einem Temp-Verzeichnis
QEMU_LIMIT=0 scripts/dev-env.sh build-multiarch          # nativ/ohne Begrenzung (nur auf echter amd64-Maschine sinnvoll)
# nur amd64 emuliert, in den lokalen Docker geladen (Beispiel B3):
docker buildx build --platform linux/amd64 --build-arg QEMU_LIMIT=1 -t timetrack-dev-b3-amd64 --load .
```

Für Produktion ist ein nativer amd64-Build (CI auf amd64 oder der Intel/AMD-vServer) vorzuziehen; Emulation ist langsam.

Ergebnis des B3-Versuchs (16.10.2026, QEMU auf arm64-Mac, `QEMU_LIMIT=1`): nach ca. 60 Minuten abgebrochen, **nicht abgeschlossen**. Die Abhängigkeitsstufe hatte 966 von 968 Schritten
kompiliert, der eigene Code und der Link fehlten noch. Der Befehl ist damit lauffähig (kein SIGILL, kein Abbruch durch SwiftPM), aber für den
Betrieb zu langsam; ein amd64-Nachweis für den aktuellen Stand steht aus (nativer Build, siehe `handoffs/B3.md`).

## 8. Stand und offene Punkte

Siehe `handoffs/B3.md` für die ausgeführten Läufe mit Zahlen. Offen: Swarm-Deployment real erproben, `--strict-counts` ohne Ruhefenster,
S3-Backup gegen echtes S3, Backups verschlüsseln/zeitgesteuert ablegen (Betreiber), Trusted-Proxy-Konfiguration im Backend (Abschnitt 6),
Metriken (es gibt keinen `/metrics`-Endpunkt; Überwachung bisher nur über `/health`/`/ready` und Logs), periodische Aufräumjobs (Backlog 4),
Prüfung abwärtskompatibler Migrationen für Rolling Updates.
