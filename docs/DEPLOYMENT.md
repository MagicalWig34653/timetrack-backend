# Deployment-Anleitung: Timetrack in Produktion (Docker Swarm, eigene MariaDB, eigener Reverse Proxy)

Stand: 17.10.2026 (Paket D2). Diese Anleitung führt Schritt für Schritt zu einer laufenden Instanz unter
`https://timetrack.example.org`. Sie ersetzt nicht [BETRIEB.md](BETRIEB.md) (Backup, Restore, Hintergründe, Nachweise),
sondern verweist dorthin. Für den Einstieg: [Installation](INSTALLATION.md) (Auswahl Compose oder Swarm, Ersteinrichtung). Diese Seite ist die ausführliche Referenz für den Swarm. Beispielwerte (`timetrack.example.test`, `db.internal.example.test`, `ABCDE12345`) sind
**Platzhalter**; ersetzen Sie sie. Alles Genannte ist aus dem Code und den Skripten abgeleitet; was **nicht** auf einem echten
Swarm, einem echten Proxy oder gegen die echte MariaDB 12.3.3 ausprobiert wurde, steht in Abschnitt 17 („Bekannte Lücken“) und ist an den Stellen mit
„nicht erprobt“ markiert.

Zielbild:

```
Internet ──TLS──> Reverse Proxy (nginx/Traefik, eigene Verwaltung)
                      │  http://<Knoten>:18080  (Routing Mesh, auf jedem Knoten)
                      ▼
                Swarm-Dienst  timetrack_backend  (Port 8080, liefert API + PWA)
                      │  TCP 3306 (TLS)
                      ▼
                vorhandene MariaDB 12.3.3 (nicht Teil des Stacks)
```

Dateien: [../deploy/swarm/stack.yaml](../deploy/swarm/stack.yaml) (Stack ohne Datenbank-Container),
[../deploy/swarm/.env.example](../deploy/swarm/.env.example) (alle Variablen mit Beispielwerten),
[../deploy/swarm/create-secrets.sh](../deploy/swarm/create-secrets.sh) (Docker-Secrets anlegen).

## 1. Voraussetzungen

| Voraussetzung | Hinweis |
| --- | --- |
| Linux-Server, amd64, Docker (Engine) mit **aktivem Swarm** (`docker info` zeigt `Swarm: active`) | Ein Knoten genügt. `docker swarm init` ist Sache des Betreibers; diese Anleitung provisioniert nichts. |
| Zugriff auf ein **Manager**-Knoten-Terminal | Secrets und Stack werden dort angelegt. |
| DNS-Eintrag `timetrack.example.org` → Server (A/AAAA) | Muss öffentlich auflösen, wenn die iOS/macOS-App Passkeys nutzen soll (Abschnitt 11). |
| TLS-Zertifikat für den Host, am Reverse Proxy | Das Backend spricht intern nur HTTP. Browser und Passkeys brauchen HTTPS (Ausnahme nur `localhost`). |
| Reverse Proxy (nginx, Traefik o. ä.), den Sie selbst betreiben | Anforderungen und Beispiele: [Reverse Proxy und TLS](installation/proxy.md). |
| Vorhandene MariaDB 12.3.3 | Vom Stack aus per TCP erreichbar, TLS empfohlen ([Eigene MariaDB](installation/mariadb.md)). Wird nicht verändert außer um eine neue Datenbank und einen neuen Benutzer. |
| Container-Image des Backends | Z. B. `ghcr.io/<owner>/timetrack-backend:<tag>` (Veröffentlichung durch Paket W1). Jede Registry geht, die die Knoten erreichen; bei privater Registry `docker login` und `--with-registry-auth`. Selbst bauen: BETRIEB.md Abschnitt 5.1 und 7 (nativer amd64-Build empfohlen). |
| Gebaute PWA | Teil des Container-Images: Die CI baut das Image aus Backend **und** PWA (Repository `timetrack-pwa`, Referenz `PWA_REF`, Standard `main`). Nichts auf den Knoten zu kopieren; Node wird nur beim Bauen gebraucht, nicht im Betrieb. Selbst bauen: `docker build --build-context pwa-src=../timetrack-pwa -t ... .` (EINRICHTUNG.md). |
| `openssl`, `curl` auf dem Server | Für `create-secrets.sh` und die Prüfungen. |

Das Backend und die PWA müssen zueinander passen (Vertragsversion). Das Image enthält beides; der PWA-Stand steht im Image-Label `org.opencontainers.image.pwa.revision`. Bauen Sie aus zusammengehörigen Ständen; der Vertrag steht im Kopf von
[../contracts/openapi.yaml](../contracts/openapi.yaml), der Stand der PWA in deren Repository.

## 2. Repository-Dateien auf den Server bringen

Sie brauchen nur drei Dateien aus `deploy/swarm/`. Am einfachsten das Repository (oder nur diesen Ordner) auf den Manager-Knoten kopieren:

```sh
mkdir -p ~/timetrack-deploy && cd ~/timetrack-deploy
# z. B. per scp/rsync: stack.yaml, .env.example, create-secrets.sh
cp .env.example .env
chmod 600 .env
chmod +x create-secrets.sh
```

**Skript und Stack-Datei vom `deploy`-Branch holen.** Der Branch `deploy` enthält nur Betriebsdateien (kein Quellcode) und wird bei jeder Änderung an `deploy/swarm/` automatisch aus `main` neu erzeugt (Workflow `deploy-branch.yml`). Zwei Wege, immer die neueste Fassung von `update.sh` und `stack.yaml` zu haben:

```sh
# a) Klon des Branches (empfohlen): einmal klonen, später nur ziehen
git clone --branch deploy --single-branch --depth 1 https://github.com/OWNER/timetrack-backend.git timetrack-deploy
cd timetrack-deploy && git pull --ff-only          # holt die neuesten Skripte; .env liegt daneben und ist nicht im Git

# b) nur das Skript, wenn es schon kopiert vorliegt: ersetzt sich selbst, zeigt vorher die Unterschiede
./update.sh --self-update                           # fragt nach, behält die alte Fassung als update.sh.prev
./update.sh --self-update --dry-run                 # nur anzeigen
./update.sh --self-update --script-ref <Commit>     # einen bestimmten Commit festnageln (Commit-Pin)
```

`OWNER` ist der GitHub-Konto-/Organisationsname aus deinem Image (`ghcr.io/OWNER/timetrack-backend`); `--self-update` leitet die Quelle (`raw.githubusercontent.com/OWNER/timetrack-backend/deploy/deploy/swarm/update.sh`) daraus ab, `--script-url` überschreibt sie. Das Skript ersetzt sich nie ungefragt: Es lädt in eine Temporärdatei, prüft Kopfzeile, Version, Endmarke und `bash -n`, zeigt Version, sha256 und `diff`, fragt (außer mit `--yes`) und sichert die alte Fassung. Beim normalen Start weist es nur mit einer Warnung darauf hin, wenn auf dem Branch eine andere Fassung liegt (abschaltbar mit `--no-self-check` oder `UPDATE_SELF_CHECK=0`). Vertrauensanker ist TLS zu GitHub; wer mehr will, pinnt mit `--script-ref` einen geprüften Commit. Nach einem `--self-update` das Skript neu starten. Im Klon liegen die Dateien unter `deploy/swarm/` (dort `./update.sh`, `./create-secrets.sh`, `.env`). `stack.yaml` muss neben `update.sh` liegen (der Klon liefert sie mit); sie wird gebraucht, wenn ein Dienst wiederhergestellt werden muss, optional mit Overlay-Dateien (`--stack-override`, `STACK_OVERRIDE_FILES`). Ein vorhandenes, von Hand gewachsenes Verzeichnis umstellen: nächster Unterabschnitt.

`.env` enthält keine Passwörter, kann aber interne Adressen verraten: nicht ins öffentliche Repository, in ein privates Konfigurations-Repository ist in Ordnung.

### Bestehendes Verzeichnis auf den deploy-Branch umstellen

Für einen Manager, auf dem schon ein Stack läuft und das Verzeichnis von Hand gewachsen ist (zum Beispiel `create-secrets.sh`, eine umbenannte und selbst veränderte Stack-Datei wie `timetrack-stack.yml`, ein alter `update.sh`, dazu die versteckten Dateien `.env` und `.env.bak`). Ziel: Skripte und Stack-Datei kommen per `git pull --ff-only` bzw. `update.sh --self-update` aus dem Branch `deploy`, die eigenen Änderungen bleiben erhalten, der laufende Stack wird nicht unterbrochen. Der Plan ändert das alte Verzeichnis nie; der Rückweg ist jederzeit der alte `docker stack deploy`-Aufruf. Es ändert sich nichts an Datenbank, Secrets und Daten.

**Was der Branch enthält und was `update.sh` erwartet.** Der Klon hat die Dateien **in Unterordnern**, nicht im Wurzelverzeichnis:

| Pfad im Klon | Inhalt |
|---|---|
| `deploy/swarm/stack.yaml` | offizielle Stack-Datei (heißt **`stack.yaml`**, nicht `timetrack-stack.yml`) |
| `deploy/swarm/update.sh` | Update-Skript (Version 2.x) |
| `deploy/swarm/create-secrets.sh` | Secrets anlegen (`--add-only` für bestehende Stacks) |
| `deploy/swarm/.env.example` | Vorlage der `.env` |
| `deploy/swarm/override.example.yaml` | Vorlage für ein Overlay mit lokalen Ergänzungen |
| `deploy/swarm/migrate-dir.sh` | lesender Vergleich alter Dateien mit dem Branch (ändert nichts) |
| `docs/`, `README.md`, `LICENSE` | Betriebsdokumentation |

`update.sh` sucht die Stack-Datei **nur** unter dem festen Namen `stack.yaml` (neben dem Skript, sonst im aktuellen Verzeichnis) oder über `--stack-file FILE`; sie wird nur gebraucht, wenn der Dienst `timetrack_migrate` fehlt und wiederhergestellt werden muss. Beim normalen Update liest das Skript die Stack-Datei nicht: es schreibt das neue Image in die `.env`, startet den Migrationsjob per `docker service update` und rollt das Backend per `docker service update --image` aus. **Eine veränderte Stack-Datei bleibt daher bei Updates unberührt**, wirkt aber nur, wenn man selbst `docker stack deploy` ausführt. Die `.env` sucht das Skript in `./.env` (aktuelles Verzeichnis), sonst neben dem Skript (`deploy/swarm/.env`) oder über `--env-file FILE`. Pflicht in der `.env` sind `TIMETRACK_IMAGE` (das Skript braucht daraus Registry und Repository), `DB_HOST`, `PUBLIC_BASE_URL`, `WEBAUTHN_RP_ID` und `WEBAUTHN_ORIGIN` (die Stack-Datei verweigert sonst das Rendern). Alles andere ist optional. Die Secrets liegen als Swarm-Secrets (`tt_db_password`, `tt_storage_secret_key`, `tt_vapid_private_key` sowie `tt_smtp_password`, `tt_oidc_client_secret`, `tt_apns_private_key`) im Cluster, **nicht** im Verzeichnis (`create-secrets.sh` liest sie nur einmalig ein und zeigt sie nie wieder); im Klon muss deshalb nichts davon liegen. **Alle sechs müssen im Cluster existieren**, sonst scheitert `docker stack deploy`; die drei optionalen legt `create-secrets.sh --add-only` bei Bedarf als Platzhalter an (Abschnitt 4).

**Alles steuert die `.env`.** Seit ENV-STACK reicht `stack.yaml` jede Backend-Variable durch (leer = nicht gesetzt) und das Backend entscheidet selbst, welche optionalen Funktionen laufen; ein Block zum Einkommentieren und ein Overlay für APNs, SMTP oder OIDC sind nicht mehr nötig:

| Eigene Änderung in der alten Stack-Datei | Jetzt |
|---|---|
| APNs (`APNS_*`, Secret `tt_apns_private_key`) | `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_IDS` in der `.env`; das Secret existiert schon (Schlüssel) |
| SMTP (E-Mail-Wiederherstellung) | `SMTP_HOST`, `SMTP_PORT`, `SMTP_TLS`, `SMTP_FROM`, `SMTP_FROM_NAME`, `SMTP_USER` in der `.env`; Secret `tt_smtp_password` |
| OIDC | `OIDC_*` in der `.env`; Secret `tt_oidc_client_secret` |
| `TRUSTED_PROXY_*`, `PWA_CSP_MODE`, `DB_*`, `PUBLISHED_PORT`, `BACKEND_REPLICAS`, `BACKEND_PLACEMENT`, `APPLE_APP_IDS`, `SESSION_*`, `PUSH_ALLOWED_HOSTS`, `MODULES_DISABLED`, Wartungs- und Aufbewahrungswerte | nur `.env` (Liste: `.env.example`) |
| Schalter je Funktion | `SMTP_ENABLED`, `OIDC_ENABLED`, `APNS_ENABLED`, `WEB_PUSH_ENABLED`, `APPLE_APP_IDS_ENABLED`: `true`, `false` oder leer (automatisch) |
| Lokales Dateispeicher-Volume | Overlay (`override.example.yaml`), dazu `BACKEND_PLACEMENT` auf einen Knoten |
| Eigene Netzwerke (`networks:`), zusätzliche Labels, andere Ressourcenlimits, Variablen, die `stack.yaml` nicht kennt | Overlay |

**Overlay nur für Sonderfälle.** Wer die Datei im Klon bearbeitet, bekommt beim `git pull --ff-only` Konflikte oder Abbrüche. Besser bleibt `stack.yaml` unverändert; Sonderfälle (Netzwerke, Labels, Limits, Volumes) stehen in einer ungetrackten Datei `override.yaml` (Vorlage `override.example.yaml`; `.env`, `.env.bak` und `override.yaml` sind nicht im Git). Sie wird als zweite Compose-Datei angegeben: `docker stack deploy -c stack.yaml -c override.yaml timetrack`. Compose führt die Dateien zusammen: `environment` pro Schlüssel (das Overlay gewinnt), `secrets` und `ports` als Listen, einzelne Werte (zum Beispiel `replicas`) werden ersetzt; ein Eintrag der Basisdatei lässt sich per Overlay nicht entfernen. Mit `docker stack config -c stack.yaml -c override.yaml` sieht man vorher das Ergebnis. `update.sh` braucht das Overlay nur bei der Wiederherstellung eines fehlenden Migrationsdienstes: `--stack-override override.yaml` (wiederholbar) oder `STACK_OVERRIDE_FILES="override.yaml"` (durch Leerzeichen getrennt) ab Version 2.1.0. **Ohne Sonderfall brauchst du keine `override.yaml`.**

**Schritt für Schritt.** Alles auf dem Manager-Knoten; `ALT` ist das bisherige Verzeichnis (hier `~/timetrack`), `NEU` das neue Nachbarverzeichnis. `OWNER` und die Repository-URL aus dem Image-Namen übernehmen. Nichts davon ändert das alte Verzeichnis oder den laufenden Stack, bis Schritt 8.

```sh
# 1. Sichern: ganzes Verzeichnis (inkl. versteckter Dateien) und den Ist-Zustand des Clusters festhalten
BK=~/timetrack.backup-$(date +%Y%m%d)
cp -a ~/timetrack "$BK" && ls -la "$BK"                  # .env und .env.bak müssen dabei sein
docker stack services timetrack > "$BK/ist-services.txt"
docker stack ps timetrack --no-trunc > "$BK/ist-tasks.txt"
docker service inspect timetrack_backend --pretty > "$BK/ist-backend.txt"
docker service inspect timetrack_backend --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'   # Image notieren (Rückweg)
docker service inspect timetrack_backend --format '{{.Spec.Mode.Replicated.Replicas}}'            # Replikas notieren
docker secret ls                                          # tt_db_password, tt_storage_secret_key, tt_vapid_private_key (+ optionale) müssen existieren
# Datenbank-Backup wie in Abschnitt 14 (die Umstellung ändert kein Schema, ein frisches Backup ist trotzdem Pflicht)

# 2. Branch in ein NEUES Nachbarverzeichnis klonen (nicht in das alte)
cd ~ && git clone --branch deploy --single-branch --depth 1 https://github.com/OWNER/timetrack-backend.git timetrack-deploy
cd ~/timetrack-deploy/deploy/swarm && ./update.sh --version       # erwartet: update.sh Version 2.x

# 3. .env und lokale Dateien übernehmen (kopieren, nicht verschieben)
cp -p ~/timetrack/.env ~/timetrack/.env.bak ~/timetrack-deploy/deploy/swarm/
chmod 600 ~/timetrack-deploy/deploy/swarm/.env
# Secrets: nichts zu kopieren, sie liegen als Swarm-Secrets im Cluster. Die neue stack.yaml referenziert immer alle sechs;
# fehlende optionale legt das Skript als Platzhalter an (bestehende bleiben unberührt, nichts wird überschrieben):
cd ~/timetrack-deploy/deploy/swarm
./create-secrets.sh --add-only --dry-run                  # zeigt, was fehlt
./create-secrets.sh --add-only

# 4. Alt gegen neu vergleichen (lesend; ändert nichts). Der Abschnitt ".env-Vorschlag" nennt die Zeilen, die in die .env gehören
./migrate-dir.sh --old-stack ~/timetrack/timetrack-stack.yml --old-env ~/timetrack/.env
diff -u ~/timetrack/timetrack-stack.yml stack.yaml | less        # vollständiger Vergleich; alt = "-", neu = "+"

# 5. Vorgeschlagene Zeilen in die .env übernehmen (kein override.yaml nötig; nur für Sonderfälle: cp override.example.yaml override.yaml)
${EDITOR:-nano} .env

# 6. Gerenderte Stack-Konfiguration prüfen (rendert nur, deployt nichts) und mit dem Ist-Zustand vergleichen
set -a; . ./.env; set +a
docker stack config -c stack.yaml > ~/neu-gerendert.yml        # nur mit Sonderfall-Overlay: zusätzlich -c override.yaml
docker stack config -c ~/timetrack/timetrack-stack.yml > ~/alt-gerendert.yml
diff -u ~/alt-gerendert.yml ~/neu-gerendert.yml | less    # jede Zeile erklären können; nur Gewolltes darf übrig bleiben

# 7. Zustand prüfen und Trockenlauf des Updates im neuen Verzeichnis
./update.sh --status                                      # .env gegen laufendes Image; muss "ok" melden
./update.sh --dry-run --tag sha-4b42364                   # ändert nichts; zeigt Tag, Ablauf und fehlenden Migrationsdienst

# 8. Deploy mit der neuen Datei. TIMETRACK_IMAGE in .env muss das AKTUELL laufende Image bleiben (Schritt 1),
#    damit dieser Schritt nur Konfiguration angleicht und kein Update ist.
docker stack deploy --with-registry-auth --resolve-image never -c stack.yaml timetrack     # mit Sonderfall-Overlay: zusätzlich -c override.yaml
docker stack services timetrack; ./update.sh --status

# 9. Erst danach das eigentliche Update, mit festgenageltem Tag (siehe Hinweis unten)
./update.sh --tag sha-4b42364
```

**Erwartung zu Schritt 8.** `docker stack deploy` ändert nur Dienste, deren Spezifikation sich gegenüber dem laufenden Zustand unterscheidet. Zeigt der Vergleich in Schritt 6 keinen Unterschied am Backend, bleibt es unberührt. Jede Abweichung (zum Beispiel ein anderer Standardwert, ein anderes Limit, ein neues Netzwerk) löst ein Rolling Update (`start-first`, Rollback bei Fehlschlag) des Backends aus, **ohne Ausfall bei einem gesunden Replikat**; der Migrationsjob läuft nur erneut, wenn sich sein Image oder seine Spezifikation ändert. Das Backend startet nur, wenn `/ready` 200 liefert (Schema aktuell). Datenverlust ist ausgeschlossen: Der Stack hat keine Volumes, die Daten liegen in der externen Datenbank.

**Image pinnen.** Der Tag `sha-4b42364` (Stand vor dem `__Host-`-Cookie, SEC-15b) ist der letzte, den die Apple-App noch ohne Anpassung versteht; neuere Tags setzen bei HTTPS das Cookie `__Host-tt_session`, dafür muss die Apple-App angepasst sein (`docs/handoffs/SEC-15B.md`), und alle Nutzer müssen sich einmal neu anmelden. Bis die angepasste App verteilt ist: immer mit `--tag` aufrufen, **nie** ohne (ohne `--tag` nimmt `update.sh` das neueste Image). `update.sh --dry-run --tag sha-4b42364` bestätigt, dass der Tag in der Registry existiert; gibt es nur die eindeutige Form `sha-4b42364-<PWA-Commit>`, diese mit `--tag` angeben. Später ohne `--tag` aktualisieren.

**Rückweg.** Das alte Verzeichnis `~/timetrack` bleibt unverändert liegen. Hat Schritt 8 etwas Unerwünschtes bewirkt: `docker service rollback timetrack_backend` (Image und Konfiguration des Backends zurück), oder den alten Stand per `docker stack deploy` wiederherstellen:

```sh
cd ~/timetrack && set -a; . ./.env; set +a              # .env.bak enthält die vorherige Fassung
docker stack deploy --with-registry-auth --resolve-image never -c timetrack-stack.yml timetrack
```

Das Image-Tag aus Schritt 1 notiert zu haben genügt, um jederzeit auf den alten Stand zu kommen (`TIMETRACK_IMAGE` in der `.env` setzen oder `docker service update --image <notiertes Image> timetrack_backend`). Das Datenbankschema wird dabei **nicht** zurückgesetzt (Abschnitt 13). Das neue Verzeichnis kann bei Bedarf gelöscht werden, das alte nur, wenn der neue Weg einige Wochen fehlerfrei lief.

**Was in der eigenen Stack-Datei zu prüfen ist** (Ergebnis von Schritt 4 und 6):

1. Lokale `environment`-Einträge, die `stack.yaml` nicht kennt (nur eigene Variablen; APNs, SMTP und OIDC sind jetzt `.env`-Variablen) und die zugehörigen Einträge unter `secrets:`.
2. Die `image:`-Zeilen: in `stack.yaml` kommen sie aus `TIMETRACK_IMAGE` (kein fester Tag in der Datei).
3. `ports:` (Port, `mode: ingress` oder `host`) und `PUBLISHED_PORT`, die Firewallregel und `TRUSTED_PROXY_CIDRS` (Abschnitt 9).
4. `deploy:` (Replikas, `placement.constraints`, Ressourcenlimits, `update_config`, `rollback_config`, `restart_policy`) und die Healthcheck-Zeilen.
5. `networks:` und `volumes:` (die offizielle Datei hat keine eigenen Netzwerke und keine Volumes; ein Volume für lokalen Dateispeicher steht als auskommentierter Block bereit).
6. Namen der Secrets (`tt_*`; bei einem anderen `--prefix` beim Anlegen müssen die Namen in Stack- oder Overlay-Datei dazu passen).
7. Zeilen, die der Vergleich als „nur in der alten Datei“ meldet, ob sie noch gebraucht werden (ältere Fassungen enthielten Übergangslösungen).
8. In der `.env`: `TIMETRACK_IMAGE`, `PUBLIC_BASE_URL`, `WEBAUTHN_RP_ID`, `WEBAUTHN_ORIGIN`, `DB_HOST`, außerdem `VAPID_SUBJECT` (sonst bleibt Web Push aus), die APNs-/SMTP-/OIDC-Zeilen laut Vorschlag, `PWA_CSP_MODE` (Standard `enforce`) und `TRUSTED_PROXY_CIDRS`.

## 3. Datenbank vorbereiten (vorhandene MariaDB)

Ausgelagert auf die Seite **[Eigene MariaDB vorbereiten](installation/mariadb.md)**: Datenbank und Benutzer mit minimalen Rechten (SQL), starkes Passwort, `max_allowed_packet`, TLS-Regeln und Verbindungstest.

## 4. Secrets anlegen

Das Backend liest Geheimnisse aus Docker-Secrets (`/run/secrets/...`, Konvention `<NAME>_FILE`, siehe BETRIEB.md Abschnitt 5.4).
Das Skript erzeugt Zufallswerte lokal, legt Secrets über stdin an, gibt **nie** Werte aus, überschreibt **nie** vorhandene Secrets und bricht vorher ab, wenn eines existiert.

```sh
# 1. Probelauf: erzeugt und prüft alles im Speicher, legt nichts an und schreibt nichts
./create-secrets.sh --dry-run --generate-db-password /root/tt-db-password.txt

# 2. Echt: Datenbankpasswort erzeugen UND in eine 0600-Datei schreiben (für CREATE USER),
#    Speicher- und VAPID-Schlüssel zusätzlich in ein Verzeichnis sichern (für den Passwortmanager)
mkdir -m 700 /root/tt-keys
./create-secrets.sh --generate-db-password /root/tt-db-password.txt --save-generated /root/tt-keys
```

Danach:

1. Passwort für [Eigene MariaDB](installation/mariadb.md) aus `/root/tt-db-password.txt` entnehmen (nicht in den Shell-Verlauf kopieren; Editor öffnen und in die SQL-Sitzung einfügen), dann die **Datei löschen**: `shred -u /root/tt-db-password.txt` (oder `rm`).
2. `/root/tt-keys/tt_storage_secret_key` und `tt_vapid_private_key` in den Passwortmanager übernehmen und das Verzeichnis löschen. **Docker zeigt Secret-Werte nie wieder an.**
3. Prüfen: `docker secret ls` zeigt `tt_db_password`, `tt_storage_secret_key`, `tt_vapid_private_key`.

Weitere Optionen: `--db-password-file DATEI` (vorhandenes Passwort), `--smtp-password-file`, `--oidc-client-secret-file`, `--apns-private-key-file`, `--prefix` (anderer Namensprefix), `--no-placeholders`, `--name-suffix`. Ohne `--db-password-file`/`--generate-db-password` fragt das Skript das Passwort ohne Echo ab.

| Secret | Inhalt | Folge des Verlusts |
| --- | --- | --- |
| `tt_db_password` | Passwort des DB-Benutzers | Neues Passwort setzen und neues Secret anlegen; kein Datenverlust. |
| `tt_storage_secret_key` | Base64 von 32 Zufallsbytes (AES-256-GCM) | **Gespeicherte S3-Zugangsdaten nicht mehr entschlüsselbar**: S3-Dateien unlesbar (HTTP 503 `storage_unavailable`), bis ein Admin die S3-Daten neu einträgt. DB und lokale Dateien nicht betroffen. Auch **nicht ohne Not rotieren**. Wird S3 nie verwendet, ist der Schaden gering, der Schlüssel muss aber gesetzt sein. |
| `tt_vapid_private_key` | P-256-Schlüssel (32 Byte, Base64url) | Push-Abonnements ungültig; Geräte müssen neu abonnieren. |
| `tt_smtp_password`, `tt_oidc_client_secret` | nur falls genutzt, sonst Platzhalter | Neu eintragen. |
| `tt_apns_private_key` | nur falls APNs genutzt (sonst Platzhalter): PEM-Text des Apple-`.p8`-Schlüssels (EC P-256) | Push an die Apple-Apps fällt aus; Schlüssel bei Apple neu erzeugen (oder aus dem Passwortmanager) und als neues Secret anlegen. |

**Platzhalter für optionale Secrets (ENV-STACK).** `stack.yaml` referenziert `tt_smtp_password`, `tt_oidc_client_secret` und `tt_apns_private_key` immer, weil Swarm einen Stack mit nicht vorhandenen Secrets nicht ausrollt. `create-secrets.sh` legt deshalb jedes dieser drei, das nicht mit einem echten Wert angelegt wird, als **Platzhalter** an (Inhalt `TIMETRACK_PLACEHOLDER_UNSET`, Docker erlaubt keine leeren Secrets). Der Einstiegspunkt des Images und das Backend behandeln Platzhalter wie „nicht gesetzt“; die Funktion bleibt aus. Beim ersten Anlegen geschieht das automatisch; für einen bestehenden Stack:

```sh
./create-secrets.sh --add-only --dry-run     # zeigt, welche Platzhalter fehlen; ändert nichts
./create-secrets.sh --add-only               # legt nur fehlende an; vorhandene (auch echte) Secrets bleiben unberührt, idempotent
```

Ein Platzhalter lässt sich nicht an Ort und Stelle durch einen echten Wert ersetzen (Docker-Secrets sind unveränderlich). Für eine Funktion, die später dazukommt, legst du das echte Secret unter neuem Namen an und zeigst die Stack-Datei darauf; das Skript druckt die nötige Zeile:

```sh
./create-secrets.sh --add-only --oidc-client-secret-file /pfad/secret.txt --name-suffix _2
#  -> created secret: tt_oidc_client_secret_2
#  -> add to .env:  SECRET_OIDC_CLIENT_SECRET_NAME=tt_oidc_client_secret_2
# Zeile in die .env, OIDC_ISSUER/OIDC_CLIENT_ID setzen, dann: docker stack deploy ...
```

Bewertung der Alternativen: `docs/handoffs/ENV-STACK.md`.

**APNs-Push für die Apple-Apps (optional, ADR-0030).** Ohne diese Schritte bleibt APNs aus (`apnsAvailable:false`), das ist der Normalfall. Aktivieren:

1. Den `.p8`-Schlüssel im Apple-Developer-Konto erzeugen (APNs-Schlüssel) und als Datei sicher ablegen; Key-ID und Team-ID notieren. Den Schlüssel nie ins Repository legen.
2. Secret anlegen: `./create-secrets.sh --apns-private-key-file /pfad/AuthKey_XXXX.p8` (bei einem bestehenden Stack **mit `--add-only`**, sonst bricht das Skript ab, weil `tt_db_password`, `tt_storage_secret_key` und `tt_vapid_private_key` schon existieren und nie überschrieben werden: `./create-secrets.sh --add-only --apns-private-key-file …`; erst `--dry-run`). Existiert `tt_apns_private_key` schon als Platzhalter, verweigert das Skript das Überschreiben und nennt `--name-suffix _2` (siehe oben). Das Skript prüft mit openssl, ohne etwas auszugeben, dass die Datei ein unverschlüsselter EC-P-256-Schlüssel im PEM-Format ist, übergibt den Inhalt per stdin und überschreibt nie ein vorhandenes Secret. Danach die Datei aus dem Arbeitsverzeichnis entfernen (Kopie im Passwortmanager).
3. `stack.yaml` bleibt unverändert (das Secret und die Variablen sind schon durchgereicht).
4. In `.env` `APNS_KEY_ID`, `APNS_TEAM_ID` (je 10 Zeichen) und `APNS_BUNDLE_IDS` (kommagetrennt) setzen; alle vier Werte inklusive Schlüssel sind nötig. Unvollständig: im automatischen Modus (`APNS_ENABLED` leer) bleibt APNs aus und das Log warnt mit den fehlenden Variablen; mit `APNS_ENABLED=true` startet das Backend nicht und nennt sie.
5. Stack neu ausrollen (Variablen: Abschnitt 6). **Wichtig:** `deploy/swarm/update.sh` genügt dafür nicht, es tauscht nur das Image aus; Änderungen an `stack.yaml` und `.env` kommen nur mit `docker stack deploy` an. Prüfen: der Administrator sieht unter „Push (Apple)“ (`/admin/apns`) die Einstellungen und kann die Verbindung zu Apple prüfen; außerdem `GET /api/v1/push/config` meldet `apnsAvailable:true` (angemeldete Sitzung). Eine echte Zustellung ist erst mit den Apple-Apps und einem Testgerät prüfbar.

**VAPID-Schlüssel**: Das Backend bringt keinen Befehl dafür mit (die CLI kennt nur `serve`, `migrate`, `bootstrap-admin`, `maintenance`).
Das Skript erzeugt ihn mit dem dokumentierten openssl-Verfahren: `openssl ecparam -name prime256v1 -genkey -noout | openssl ec -outform DER | tail -c +8 | head -c 32 | base64 | tr '+/' '-_' | tr -d '=\n'`
(roher Skalar, 43 Zeichen Base64url ohne Padding). Der öffentliche Schlüssel ergibt sich daraus; die PWA holt ihn über `GET /api/v1/push/config`.

Secrets sind unveränderlich. Rotation: neues Secret mit anderem Namen anlegen (`--name-suffix` für die optionalen, sonst `--prefix`), den Namen in der `.env` setzen (`SECRET_DB_PASSWORD_NAME`, `SECRET_STORAGE_KEY_NAME`, `SECRET_VAPID_KEY_NAME`, `SECRET_SMTP_PASSWORD_NAME`, `SECRET_OIDC_CLIENT_SECRET_NAME`, `SECRET_APNS_KEY_NAME`), neu ausrollen, das alte entfernen. Der Pfad im Container (`/run/secrets/tt_...`) bleibt gleich.

## 5. Port und Netzwerk

> **Ohne Swarm?** Für einen einzelnen Server gibt es eine einfache Variante: [`deploy/compose/`](../deploy/compose/README.md) (Compose-Datei, `.env.example`, `init-secrets.sh`, optional eine gebündelte MariaDB).

> **Dateispeicher:** Standard ohne Volumes: Dateien in der Datenbank (oder S3). Für lokale Dateiablage enthält `stack.yaml` einen auskommentierten Volume-Block (Dienst und Ende der Datei), dazu `BACKEND_PLACEMENT` auf einen festen Knoten setzen.

Der Stack veröffentlicht den Port des Backends auf **jedem Swarm-Knoten** (Routing Mesh, `mode: ingress`, Standard `PUBLISHED_PORT=18080`). Jeder Knoten leitet an ein gesundes Replikat weiter, egal auf welchem Knoten es läuft. Ein vorab angelegtes Overlay-Netz ist **nicht** nötig; der Stack nutzt nur sein eigenes Standardnetz.

- Der Reverse Proxy (außerhalb oder innerhalb von Swarm) verbindet sich mit `http://<Knoten-IP>:18080` (mehrere Knoten: als Upstream-Liste oder über eine virtuelle IP).
- **Firewall (Pflicht):** Erlauben Sie den Port nur Ihrem Proxy. Wer ihn direkt erreicht, kann `X-Forwarded-For` fälschen und damit alle Adresszähler umgehen (siehe [Reverse Proxy und TLS](installation/proxy.md#trusted-proxy-cidrs-bestimmen)).
- Das Subnetz für `TRUSTED_PROXY_CIDRS` ist hier das des `ingress`-Netzes ([Reverse Proxy und TLS](installation/proxy.md#trusted-proxy-cidrs-bestimmen)):

```sh
docker network inspect ingress --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
```

Sie können den Stack alternativ an ein gemeinsames Overlay-Netz mit einem Proxy im Swarm hängen. Dafür ergänzen Sie im Stack ein externes Netz und `networks:` am Dienst; das ist nicht die Voreinstellung und nicht erprobt.

## 6. Variablen eintragen (`.env`)

Alle Variablen mit Pflicht/optional, Standardwert und Bedeutung stehen in der **[Konfigurationsreferenz](installation/konfiguration.md)**. Für den Swarm gilt zusätzlich: Öffne `.env` (Vorlage `.env.example`) und ersetze die Beispielwerte; **Pflicht** sind die ersten Zeilen (`TIMETRACK_IMAGE`, `DB_HOST`, `PUBLIC_BASE_URL`, `WEBAUTHN_RP_ID`, `WEBAUTHN_ORIGIN`); `VAPID_SUBJECT` sollte gesetzt sein (sonst bleibt Web Push aus). Jede Variable des Backends ist in der Vorlage enthalten und wird immer durchgereicht; **leer bedeutet „nicht gesetzt“**. Optionale Funktionen (SMTP, OIDC, APNs, Web Push, Apple-App-IDs) haben je einen Schalter `<FUNKTION>_ENABLED` (`true` = muss laufen, sonst Startfehler; `false` = aus; leer = automatisch an, wenn die Pflichtwerte gesetzt sind). Das Backend loggt beim Start eine Übersicht aller Funktionen (an/aus und warum, ohne Geheimnisse). Die Datei wird von der Shell eingelesen (`set -a; . ./.env; set +a`): keine Leerzeichen um `=`, Werte mit Leerzeichen in Anführungszeichen. Das Backend loggt bei ungültiger Konfiguration einen Fehler mit dem Namen der Variable (z. B. `Invalid configuration for WEBAUTHN_RP_ID: must be a lowercase hostname`) und startet nicht.

Dateispeicher in der Datenbank: Der Stack hat **keine Volumes**. Hochgeladene Dateien liegen in der Datenbank (und damit im DB-Backup). Stelle nach dem ersten Login im Admin-Bereich bei den Speicherregeln „alles → Datenbank“ ein und setze ein globales Upload-Limit (Beispiel: 50 MiB). Die Speicherart „Lokal“ steht im Stack nicht zur Verfügung (kein beschreibbarer Pfad, Root-Dateisystem schreibgeschützt); S3 ist über den Admin-Bereich weiterhin möglich.

## 7. Erstes Deployment

Reihenfolge: **Migration → Dienst → Gesundheitsprüfung.** Swarm kennt keine Reihenfolge zwischen Diensten, deshalb startet das Backend zuerst mit 0 Replikaten.

```sh
cd ~/timetrack-deploy
set -a; . ./.env; set +a

# 1. Darstellung prüfen (bereitet nichts vor; fehlende Pflichtvariablen werden benannt)
docker stack config -c stack.yaml > /dev/null && echo "Konfiguration ok"

# 2. Deployen mit 0 Backend-Replikaten: nur der Migrationsjob läuft
BACKEND_REPLICAS=0 docker stack deploy --with-registry-auth -c stack.yaml timetrack

# 3. Auf den Migrationsjob warten und prüfen
docker service ps timetrack_migrate                 # erwartet: Complete
docker service logs timetrack_migrate               # je Migration eine Zeile "Finished prepare"; keine Passwörter

# 4. Backend starten
docker service scale timetrack_backend=1
docker service ps timetrack_backend                 # erwartet: Running (nach ca. 30 s "healthy")
docker service logs --tail 50 timetrack_backend
```

Schlägt der Migrationsjob fehl (`Failed`, `Rejected`): `docker service logs timetrack_migrate`. Häufig: DB nicht erreichbar, TLS-Fehler, fehlende Rechte ([Probleme und Lösungen](installation/probleme.md)). Nach der Korrektur den Job erneut starten: `docker service update --force timetrack_migrate`.

Wichtig: `docker stack deploy` setzt `replicas` aus der Datei zurück. Wenn Sie später erneut deployen, ohne `BACKEND_REPLICAS` zu setzen, gilt der Wert aus `.env` (hier `1`).

Gesundheit des Dienstes (der Container-Healthcheck ruft `/ready` auf: Datenbank erreichbar und alle Migrationen angewendet):

```sh
docker ps --filter name=timetrack_backend --format '{{.Names}} {{.Status}}'        # (healthy)
docker exec "$(docker ps -q -f name=timetrack_backend)" curl -fsS http://127.0.0.1:8080/ready
docker exec "$(docker ps -q -f name=timetrack_backend)" curl -fsS http://127.0.0.1:8080/health
```

(`docker exec` und `docker ps` zeigen nur Container des **eigenen** Knotens.)

## 8. Reverse Proxy

Ausgelagert auf die Seite **[Reverse Proxy und TLS](installation/proxy.md)**: Anforderungen, Beispiele für Caddy, nginx und Traefik.

## 9. `TRUSTED_PROXY_CIDRS` bestimmen

Ausgelagert auf die Seite **[Reverse Proxy und TLS](installation/proxy.md#trusted-proxy-cidrs-bestimmen)**.

**Pflicht (SEC-01):** `TRUSTED_PROXY_CIDRS` setzen **und** den veröffentlichten Port per Knoten-Firewall ausschließlich dem Proxy öffnen. Beides gehört zusammen: Ohne gesetzte Liste teilen alle Clients eine Adresssperre; mit Ingress-Netz in der Liste, aber offenem Port, kann jeder Absender seine Adresse per `X-Forwarded-For` fälschen (Routing Mesh). Der Prüfschritt steht in [Betrieb](BETRIEB.md), Abschnitt 6, Schritt 4.

## 10. Passkeys und Domainregeln

- Passkeys sind an die **RP-ID** gebunden (`WEBAUTHN_RP_ID`, hier `timetrack.example.org`). Ein späterer Wechsel macht alle Passkeys unbrauchbar; Konten müssen dann über die Wiederherstellung neue Passkeys anlegen. Passkeys der Testinstanz (`timetracker-test...`) sind nicht übertragbar (ADR-0015).
- `WEBAUTHN_ORIGIN` muss exakt die Adresse sein, die der Browser anzeigt (`https://timetrack.example.org`, kein Pfad, kein abschließender Schrägstrich nötig, kein Port außer dem Standard). Abweichungen (www-Präfix, anderer Port, `http`) führen zu Fehlern bei der Passkey-Anmeldung.
- Das Backend akzeptiert zusätzlich `https://<RP-ID>` als Origin für native Apple-Clients (nur wenn die RP-ID einen Punkt enthält). Mehr nicht (keine Subdomains, keine Ports).
- Zugriff nur über HTTPS. Der Browser verweigert Passkeys auf HTTP und in eingebetteten Frames anderer Domains.
- Die RP-ID darf kürzer sein als der Host (z. B. `example.org`, dann gelten Passkeys auch für Subdomains). Das ist hier **nicht** vorgesehen; bleiben Sie bei der vollen Domain.

## 11. Apple App Site Association (iOS/macOS-App)

Voraussetzungen: öffentlich erreichbare Domain mit gültigem TLS-Zertifikat und `APPLE_APP_IDS` gesetzt. Die Datei erzeugt das Backend (keine Datei auf dem Server pflegen):

```json
{"webcredentials":{"apps":["ABCDE12345.com.example.timetrack"]}}
```

Team-ID: im Apple-Entwicklerkonto unter „Membership“ (10 Zeichen, Großbuchstaben/Ziffern). **Hinweis aus ADR-0015**: Mit einem *persönlichen* Entwicklerteam sind Associated Domains (damit Passkeys in den Apps) nicht möglich; dafür ist das bezahlte Apple Developer Program nötig. Der Server kann die Datei trotzdem schon ausliefern.

Prüfen (von einem Rechner im Internet):

```sh
# 1. Direkt, ohne Redirect: erwartet HTTP/2 200, content-type: application/json, Body wie oben
curl -sSI https://timetrack.example.org/.well-known/apple-app-site-association
curl -sS  https://timetrack.example.org/.well-known/apple-app-site-association; echo

# 2. Apples CDN (so lädt iOS die Datei tatsächlich): erwartet 200 und denselben Inhalt
curl -sSI https://app-site-association.cdn-apple.com/a/v1/timetrack.example.org
curl -sS  https://app-site-association.cdn-apple.com/a/v1/timetrack.example.org; echo
```

- 404 vom Server: `APPLE_APP_IDS` leer oder Stack nicht neu ausgerollt.
- Weiterleitung (301/302): Der Proxy leitet um (z. B. HTTP→HTTPS am falschen Pfad, `www`, SPA-Fallback). Apple folgt keinen Weiterleitungen.
- Die CDN-Anfrage scheitert (404/Zeitüberschreitung), obwohl der Server antwortet: Die Domain ist nicht öffentlich erreichbar, Firewall/Geo-Block, ungültiges oder selbstsigniertes Zertifikat, oder die CDN hat noch keinen Stand: Apple aktualisiert den Cache nicht sofort (Stunden bis Tage). Der Server sendet `Cache-Control: public, max-age=3600`.
- Auf Entwicklungsgeräten kann `webcredentials:timetrack.example.org?mode=developer` die CDN umgehen (Entwicklermodus des Geräts nötig, ADR-0015).

## 12. Erster Administrator

Nach grünem Healthcheck und funktionierendem Proxy: `bootstrap-admin` erzeugt **einen** Einladungslink für die Admin-Rolle (72 Stunden gültig, einmalig, nur der Hash wird gespeichert). Er klappt nur, solange **noch kein Konto existiert**; ein erneuter Aufruf macht frühere, unbenutzte Bootstrap-Links ungültig.

Der Link ist ein Zugang zum Admin-Konto. Wer ihn zuerst öffnet, wird Admin. Behandeln Sie ihn wie ein Passwort: nur im Terminal anzeigen, nicht in Tickets, Chats, Logs oder Shell-Verlauf ablegen, unmittelbar im Browser öffnen und dort den Passkey registrieren.

Auf dem Knoten, der das Backend ausführt (der laufende Container hat die Secrets bereits eingehängt; `docker exec` startet einen neuen Prozess im selben Container, der Einstiegspunkt liest die Secrets wie beim normalen Start):

```sh
docker exec -it "$(docker ps -q -f name=timetrack_backend | head -n 1)" \
  /app/docker-entrypoint.sh bootstrap-admin --env production
```

Ausgabe: `https://timetrack.example.org/invite/<token>`. Link im Browser öffnen, Anzeigenamen und Passkey anlegen (siehe Wiederherstellungsoption in der PWA wählen).
Der Befehl schreibt den Link nur auf die Konsole; das Backend protokolliert Einladungs-URLs nicht. Dieser Weg ist **nicht auf einem echten Swarm erprobt**; im Compose-Betrieb ist `docker compose run --rm --no-deps -T backend bootstrap-admin --env production` belegt (mit dem Image und der gebündelten Datenbank geprüft).

**Wichtig:** `docker exec … bootstrap-admin` (ohne `/app/docker-entrypoint.sh`) schlägt fehl mit `executable file not found in $PATH`, weil `bootstrap-admin` ein Unterbefehl des Einstiegspunkts ist, keine Programmdatei. Der Einstiegspunkt muss mit angegeben werden, oder man nutzt `docker compose run`.

Alternative, wenn das Backend nicht läuft oder auf einem anderen Knoten: einen einmaligen Dienst starten, der das Secret einhängt (Link steht dann in `docker service logs`; danach sofort den Dienst entfernen):

```sh
docker service create --name tt-bootstrap --restart-condition none \
  --secret tt_db_password \
  -e DATABASE_DRIVER=mariadb -e DB_HOST="$DB_HOST" -e DB_PORT="${DB_PORT:-3306}" -e DB_NAME="${DB_NAME:-timetrack}" \
  -e DB_USER="${DB_USER:-timetrack}" -e DB_TLS="${DB_TLS:-required}" -e DB_PASSWORD_FILE=/run/secrets/tt_db_password \
  -e PUBLIC_BASE_URL="$PUBLIC_BASE_URL" -e WEBAUTHN_RP_ID="$WEBAUTHN_RP_ID" -e WEBAUTHN_ORIGIN="$WEBAUTHN_ORIGIN" \
  "$TIMETRACK_IMAGE" bootstrap-admin --env production
docker service logs tt-bootstrap          # Link kopieren
docker service rm tt-bootstrap            # entfernt auch die Logs
```

Danach: weitere Personen lädt der Admin in der PWA ein (Registrierung nur per Einladung).

## 13. Updates und Rollback

Kurzfassung mit Compose und Swarm: [Aktualisieren und Migrationen](UPDATE.md). Vorher ein Backup (Abschnitt 14).

```sh
cd ~/timetrack-deploy
set -a; . ./.env; set +a
export NEUES_IMAGE=ghcr.io/OWNER/timetrack-backend:1.1.0    # neue Version; in .env nachführen

# 1. Migration zuerst (idempotent; ohne offene Migrationen passiert nichts)
docker service update --force --image "$NEUES_IMAGE" timetrack_migrate
docker service ps timetrack_migrate                          # Complete abwarten; bei Fehler: Logs lesen, NICHT weitermachen

# 2. Backend aktualisieren (Rolling Update, start-first, Rollback bei Fehlschlag)
docker service update --with-registry-auth --image "$NEUES_IMAGE" timetrack_backend
docker service ps timetrack_backend
```

Oder: `TIMETRACK_IMAGE` in `.env` ändern, `docker stack deploy ...` erneut ausführen (Migrationsjob **vor** dem Backend abwarten; mit `BACKEND_REPLICAS=0` beginnen, wenn das Schema geändert wird).

Verhalten: Das neue Backend wird erst „healthy“, wenn `/ready` 200 liefert (Datenbank erreichbar, alle Migrationen angewendet). Ohne vorherige Migration bleibt es ungesund; `update_config` rollt automatisch zurück (`failure_action: rollback`, 60 s Beobachtung). Tritt das ein, ist der Dienst auf der alten Version geblieben.

Manueller Rollback des Images: `docker service rollback timetrack_backend`. **Das Schema wird nicht zurückgerollt.** Ein Rückgang auf eine ältere Version nach einer angewendeten Migration ist nur sicher, wenn die Migration abwärtskompatibel war (nicht zugesichert); im Zweifel Restore aus dem Backup vor Schritt 1 (BETRIEB.md [Eigene MariaDB](installation/mariadb.md)). Bei Migrationen mit zerstörenden Änderungen (Release-Hinweise lesen) das Backend vorher auf 0 skalieren: `docker service scale timetrack_backend=0`.

**`update.sh` im Alltag (ab Version 2).** `update.sh --status` zeigt Stand (`.env` gegen laufendes Image), Replikas, Rollout, Migrationsdienst und `/ready`/`/health` und endet mit Exit 1, wenn etwas nicht stimmt. `--dry-run` ändert nichts (nur lesende `docker`-Aufrufe) und meldet auch einen fehlenden Migrationsdienst. `--rollback` stellt das Backend auf das Image aus `.env.bak` zurück (oder `--tag`), ohne das Schema anzufassen; die vorherige `.env` wird dabei zur neuen `.env.bak`, ein zweiter `--rollback` geht also wieder vor. `UPDATE_BACKUP_CMD='<Befehl>'` führt vor der Migration einen Sicherungsbefehl aus (Fehlschlag bricht ab). Jeder Lauf hängt eine Zeile an `update-history.log` neben der `.env` an. **Das Skript endet nie still:** bei jedem Abbruch steht eine deutsche Meldung mit Schritt, Befehl, Zeile und Exit-Code da, gefolgt von Hinweisen.

**Dienst `timetrack_migrate` fehlt** (zum Beispiel weil er hing und gelöscht wurde): Version 1 des Skripts beendete sich dann ohne Meldung nach Schritt 3/6 (siehe `docs/handoffs/UPDATE-V2.md`). Ab Version 2 erkennt `update.sh` den fehlenden Dienst vor dem Schreiben der `.env` und stellt ihn in Schritt 4 per `docker stack deploy -c stack.yaml` wieder her, mit Image und Replikazahl des laufenden Backends (das Backend ändert sich dadurch nicht, außer die `.env` enthält sonst Änderungen an der Stack-Konfiguration). Manuell auf dem Manager (ohne neues Skript):

```sh
cd ~/timetrack-deploy
set -a; . ./.env; set +a
export TIMETRACK_IMAGE="$(docker service inspect timetrack_backend --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' | sed 's/@sha256:.*//')"
export BACKEND_REPLICAS="$(docker service inspect timetrack_backend --format '{{.Spec.Mode.Replicated.Replicas}}')"
docker stack deploy --with-registry-auth --resolve-image never -c stack.yaml timetrack   # legt timetrack_migrate neu an
docker service ps timetrack_migrate                                                      # Complete abwarten
```

**`update.sh` hängt oder bricht ab (Fehlersuche beim Update).** Das Skript begrenzt jeden Abschnitt (Migration 300 s, Rollout 600 s, jeder einzelne `docker`/`curl`-Aufruf 60 s bzw. 30 s; über `MIGRATE_TIMEOUT` und `ROLLOUT_TIMEOUT` in Sekunden anpassbar) und zeigt bei Fehlschlag `docker service ps --no-trunc`, die letzten Logzeilen und Rückfallbefehle. Ein zweiter Lauf wird durch eine Sperre (`$TMPDIR` oder `/tmp`, `timetrack-update-<Stack>.lock`) verhindert, weil jeder Lauf den Migrationsjob **neu startet** (`service update --force`): Der Dienst `timetrack_migrate` erscheint im Log also nach jedem Skriptlauf erneut, auch wenn „No new migrations.“ gemeldet wird; Swarm startet einen fertigen Job nicht von selbst neu (`replicated-job`, `restart_policy: none`). Diagnose auf dem Manager:

```sh
docker service ps timetrack_migrate --no-trunc          # Complete? oder Running trotz fertigem Log
docker service inspect timetrack_migrate --format '{{json .JobStatus}} {{json .Spec.TaskTemplate.ForceUpdate}}'
docker service logs --tail 50 timetrack_migrate
docker service inspect timetrack_backend --format '{{json .UpdateStatus}}'
docker service ps timetrack_backend --no-trunc          # Tasks "Starting"/"Unhealthy"? Ursache bei Rollout-Timeout
docker service logs --tail 100 timetrack_backend        # /ready 503, Pool-Zeitüberschreitungen
```

Abbrechen: `Strg+C` beendet nur das Skript (es zeigt dann die Hinweise); Swarm führt Job und Rolling Update weiter. Ein laufendes Rolling Update stoppt oder macht man rückgängig mit `docker service rollback timetrack_backend`; die alte Image-Zeile steht in `.env.bak`. Zeigt `timetrack_migrate` dauerhaft `Running`, obwohl das Log „No new migrations.“ meldet, hängt der Prozess beim Beenden: `docker service rm timetrack_migrate` ist unkritisch (der Job hält keine Daten; die Migration ist durch), danach `docker stack deploy` mit der aktuellen `.env` legt ihn neu an, oder das Backend mit `update.sh --skip-migrate --tag <Tag> --yes` ausrollen, nachdem `/ready` des laufenden Backends bzw. das Migrationslog die aktuelle Schemaversion bestätigt. Schlägt das Rollout fehl, obwohl die Migration lief, liegt es fast immer an `/ready` (Datenbank nicht erreichbar, Pool-Zeitüberschreitungen im Backend-Log).

PWA aktualisieren: Die PWA ist Teil des Images, ein Update ist ein neues Image-Tag. In GitHub baut der Docker-Workflow die PWA aus dem Repository `timetrack-pwa` (Referenz: Repository-Variable `PWA_REF`, Standard `main`); für eine neue PWA-Version den Workflow neu starten (Push auf `main`, Tag `v*` oder manuell) und das neue Tag wie ein Backend-Update ausrollen (Abschnitt oben). Browser und Service Worker holen die neue Version beim nächsten Besuch.

**Hinweis zum Update auf Vertrag 0.43.0 (SEC-15b):** Das Sitzungscookie heißt bei HTTPS jetzt `__Host-tt_session`; alle Nutzer müssen sich einmalig neu anmelden (kein Datenverlust, Sitzungen unter dem alten Namen werden bewusst nicht mehr akzeptiert). Native Apps benötigen die passende App-Version. Der Reverse Proxy darf `Set-Cookie` nicht umschreiben (`Domain`/`Path`).

## 14. Backup und Restore

Verbindliche Beschreibung, Archivformat, Nachweise: [BETRIEB.md](BETRIEB.md) Abschnitte 1 bis 4. Kurzfassung für diese Installation:

1. **Backup-Benutzer** (nur lesen) in MariaDB: `CREATE USER 'ttbackup'@'192.0.2.%' IDENTIFIED BY '...' REQUIRE SSL; GRANT SELECT, SHOW VIEW, TRIGGER ON timetrack.* TO 'ttbackup'@'192.0.2.%';` (Rechtemenge nicht gegen den Produktionsserver geprüft; `mariadb-dump --single-transaction` braucht in der Regel `SELECT`).
2. **Datenbank** sichern (Host-Modus, Client `mariadb-dump` auf dem Backup-Host nötig, Passwort aus Datei):
   `DB_HOST=db.internal.example.test DB_USER=ttbackup DB_PASSWORD_FILE=/root/tt-backup-pw scripts/backup.sh --driver mariadb --db-name timetrack --out /backups`
3. **Dateien**: Liegen sie in der Datenbank (Empfehlung, Stack ohne Volumes), sind sie im Datenbank-Backup enthalten; `--local-files` entfällt. Nur wenn Sie den Stack selbst um einen Bind-Mount für die Speicherart „Lokal“ erweitern, gilt: das Backend speichert den **echten Pfad im Container** in der Datenbank, das Skript prüft gegen den Host-Pfad; nur mit identischem Pfad auf Host und Container sinnvoll, nicht erprobt.
4. **S3-Objekte** separat sichern (BETRIEB.md Abschnitt 2).
5. **Nicht im Archiv, getrennt aufbewahren**: `STORAGE_SECRET_KEY`, VAPID-Schlüssel, DB-Passwort, `.env`, Proxy-Konfiguration.
6. Archive verschlüsseln (`age`/`gpg`), außerhalb des Servers ablegen, zeitgesteuert (cron/systemd-Timer) laufen lassen. **Das Projekt liefert keinen Zeitplan.**
7. Restore: Backend auf 0 skalieren, `scripts/restore.sh` (Ziel-DB leer), mit den **ursprünglichen** Secrets und derselben `WEBAUTHN_RP_ID` wieder starten, bei neuerem Image zuerst die Migration. Mindestens einmal vorher auf einer Kopie üben.

## 15. Überwachung und Logs

- Logs: `docker service logs -f --tail 100 timetrack_backend` (JSON-Datei-Treiber mit Rotation 10 MiB × 5 je Dienst und Knoten). Für zentrale Logs den `logging:`-Block anpassen. Einladungs-URLs, Passwörter und Schlüssel werden nicht protokolliert.
- Zustand: `docker service ps timetrack_backend`, `docker service ls`, `docker inspect --format '{{json .State.Health}}' <container>`.
- Endpunkte: `GET /health` (Prozess lebt), `GET /ready` (Datenbank + Migrationen). Es gibt **keinen** `/metrics`-Endpunkt. Externe Überwachung (z. B. Uptime-Check auf `https://timetrack.example.org/` und die Startseite der PWA) einrichten.
- Wartungsjob: läuft im Backend alle `MAINTENANCE_INTERVAL_MINUTES` Minuten; einmalig manuell: `docker exec -it <container> /app/docker-entrypoint.sh maintenance --env production`.
- Ressourcen: Standardlimits 1 CPU / 768 MiB (Backend). Uploads bis 64 MiB werden im Speicher gesammelt; die Werte wurden unter Last nicht gemessen.

## 16. Modulschalter

`MODULES_DISABLED` (kommagetrennt) sperrt Funktionen für alle Konten: `reports` (Berichte/Berichtsheft), `planning`, `transfer` (Import/Export), `automation`, `mcp`, `groups` (öffentliche Umfragen und Bestellrunden per Link, ADR-0033). Gesperrte Module verschwinden in der PWA und antworten auf der API mit einem Fehler; Benutzer können Module zusätzlich für sich selbst abschalten (ADR-0012). Beispiel: Nur ohne KI-Anbindung `MODULES_DISABLED=mcp`. Ungültige Namen verhindern den Start. Änderung: `.env`, neu ausrollen.

## 17. Bekannte Lücken

Das ist der tatsächliche Stand, nicht das Wunschbild:

1. Stack und Anleitung sind **nicht auf einem echten Swarm** erprobt (`docker stack deploy`, Secrets-Einhängung, `replicated-job`, Rollback). Geprüft sind `docker stack config` und das Containerverhalten im Smoke-Test (BETRIEB.md Abschnitt 5.5).
2. Kein Test gegen einen echten Proxy (nginx/Traefik) und gegen die produktive MariaDB 12.3.3. Die Proxy-Beispiele sind nach Dokumentation geschrieben.
3. `DB_TLS=required` prüft das Zertifikat mit den Standard-CAs des Images; es gibt keine Variable für eine eigene CA oder zum Abschalten der Namensprüfung. Private CA: eigenes Image oder öffentliches Zertifikat.
4. `bootstrap-admin` per `docker exec`/`docker service create` auf einem echten Swarm nicht erprobt (Befehl selbst ist belegt).
5. Backup lokaler Dateien (nur bei selbst ergänztem Bind-Mount, Pfadabweichung Host/Container) nicht erprobt (Abschnitt 14). Zeitgesteuerte Backups, Verschlüsselung und S3-Backup gegen echtes S3 fehlen.
6. Docker-Secrets sind im Backend-Image über den Einstiegspunkt gelöst; das Backend selbst kennt `*_FILE` nicht. Eigene Aufrufe, die den Einstiegspunkt umgehen, bekommen die Secrets nicht.
7. Migrationen sind nicht auf Abwärtskompatibilität für Rolling Updates geprüft (BETRIEB.md Abschnitt 5.2). Schema-Rollback gibt es nur über Restore.
8. Kein `/metrics`, keine Alarmierung. Der Erinnerungs-Scheduler nutzt eine Lease (mehrere Replikate möglich), die Anmeldung wird durch eine globale `auth_lock` serialisiert.
9. Ressourcenlimits sind Startwerte ohne Lastmessung. amd64: nativer Build des aktuellen Stands nicht belegt (BETRIEB.md Abschnitt 7).
10. Associated Domains (Passkeys in den Apps) brauchen das bezahlte Apple Developer Program (ADR-0015); ein Test mit echten Geräten steht aus.

## 18. Fehlersuche

Ausgelagert auf die Seite **[Probleme und Lösungen](installation/probleme.md)** (alle Symptome, Ursachen und Abhilfen an einer Stelle).

## 19. Sicherheits-Checkliste

- [ ] Alle Secrets als Docker-Secrets (kein Passwort in `.env`, Image, Repository oder Shell-Verlauf); Wert-Dateien nach dem Anlegen gelöscht.
- [ ] `STORAGE_SECRET_KEY` und VAPID-Schlüssel im Passwortmanager gesichert (**Verlust des Speicherschlüssels macht verschlüsselte S3-Einstellungen unwiederbringlich**).
- [ ] DB-Benutzer nur für `timetrack.*`, Host eingeschränkt, `REQUIRE SSL`, starkes Passwort; MariaDB-Port nur aus dem Swarm erreichbar.
- [ ] Backup-Verfahren eingerichtet, Archive verschlüsselt und extern gelagert, Restore einmal geübt.
- [ ] Reverse Proxy: HTTPS, HSTS (das Backend sendet bei https-Basisadresse selbst `Strict-Transport-Security`, `HSTS_MAX_AGE_SECONDS`), HTTP→HTTPS, Upload-Limit 70m, Rate-Limit für `/api/v1/auth/`, `/oauth/`; `/health` und `/ready` nicht öffentlich.
- [ ] `TRUSTED_PROXY_CIDRS` **gesetzt** auf das Proxy-Netz (so eng wie möglich, ideal `/32`); Backend-Port **nicht** veröffentlicht oder per Firewall nur dem Proxy zugänglich; Prüfschritt mit gefälschtem `X-Forwarded-For` von einem fremden Rechner durchgeführt (Betrieb, Abschnitt 6). Keine Startwarnung zu `TRUSTED_PROXY_CIDRS` im Log.
- [ ] Firewall: nur 80/443 (und SSH) öffentlich; Swarm-Ports (2377, 7946, 4789) nicht aus dem Internet erreichbar.
- [ ] Image mit fester Version, aus vertrauenswürdiger Registry; Updates mit vorherigem Backup.
- [ ] Admin-Konto: mindestens zwei Passkeys auf getrennten Geräten, Wiederherstellungsoption bewusst gewählt, Konto nicht für die tägliche Arbeit verwenden, Einladungen nur an bekannte Personen.
- [ ] Bootstrap-Link nach Gebrauch nicht aufbewahrt.
- [ ] Nicht benötigte Module per `MODULES_DISABLED` gesperrt (z. B. `mcp`, wenn keine KI-Clients genutzt werden).
- [ ] Docker-Daemon-Zugriff (Gruppe `docker`/root) eingeschränkt: Wer Docker bedient, sieht alle Secrets.

## 20. Checkliste Go-Live

1. [ ] DNS `timetrack.example.org` zeigt auf den Proxy; Zertifikat gültig (`curl -I https://timetrack.example.org/`).
2. [ ] MariaDB: Datenbank und Benutzer angelegt, TLS-Verbindung getestet ([Eigene MariaDB](installation/mariadb.md)).
3. [ ] Secrets angelegt (`docker secret ls` zeigt drei bis fünf `tt_*`), Schlüssel gesichert (Abschnitt 4).
4. [ ] Overlay-Netz vorhanden, Proxy daran angeschlossen; Subnetz in `TRUSTED_PROXY_CIDRS` (Abschnitte 5, 9).
5. [ ] `.env` ausgefüllt; `docker stack config -c stack.yaml` ohne Fehler (Abschnitte 6, 7).
6. [ ] Image enthält die PWA (`docker run --rm --entrypoint ls IMAGE /srv/pwa` zeigt `index.html`); keine Volumes, keine Knotenbindung nötig.
7. [ ] Migrationsjob `Complete`, Backend `healthy`, `/ready` = 200 (Abschnitt 7).
8. [ ] Proxy-Konfiguration geladen: `https://timetrack.example.org/` zeigt die PWA, `/health` von außen nicht erreichbar.
9. [ ] AASA und Apples CDN geprüft, falls die App genutzt wird (Abschnitt 11).
10. [ ] Ersten Admin angelegt, Passkey registriert, zweiter Passkey/Gerät hinzugefügt (Abschnitt 12).
11. [ ] Speicherregel im Admin-Bereich gesetzt („alles → Datenbank“, Upload-Limit z. B. 50 MiB), Test-Upload; Push einmal abonniert und ausgelöst.
12. [ ] Rate-Limit-Test mit zwei Clients (BETRIEB.md Abschnitt 6).
13. [ ] Erstes Backup gelaufen und ein Restore auf einer Kopie geübt.
14. [ ] Update-Ablauf einmal trocken durchgegangen (Abschnitt 13), Rollback-Befehl notiert.
15. [ ] Überwachung/Alarm für `https://timetrack.example.org/` eingerichtet.
16. [ ] Offene Punkte aus Abschnitt 17 gelesen und akzeptiert.
