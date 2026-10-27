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

`.env` enthält keine Passwörter, kann aber interne Adressen verraten: nicht ins öffentliche Repository, in ein privates Konfigurations-Repository ist in Ordnung.

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

Weitere Optionen: `--db-password-file DATEI` (vorhandenes Passwort), `--smtp-password-file`, `--oidc-client-secret-file`, `--apns-private-key-file`, `--prefix` (anderer Namensprefix). Ohne `--db-password-file`/`--generate-db-password` fragt das Skript das Passwort ohne Echo ab.

| Secret | Inhalt | Folge des Verlusts |
| --- | --- | --- |
| `tt_db_password` | Passwort des DB-Benutzers | Neues Passwort setzen und neues Secret anlegen; kein Datenverlust. |
| `tt_storage_secret_key` | Base64 von 32 Zufallsbytes (AES-256-GCM) | **Gespeicherte S3-Zugangsdaten nicht mehr entschlüsselbar**: S3-Dateien unlesbar (HTTP 503 `storage_unavailable`), bis ein Admin die S3-Daten neu einträgt. DB und lokale Dateien nicht betroffen. Auch **nicht ohne Not rotieren**. Wird S3 nie verwendet, ist der Schaden gering, der Schlüssel muss aber gesetzt sein. |
| `tt_vapid_private_key` | P-256-Schlüssel (32 Byte, Base64url) | Push-Abonnements ungültig; Geräte müssen neu abonnieren. |
| `tt_smtp_password`, `tt_oidc_client_secret` | nur falls genutzt | Neu eintragen. |
| `tt_apns_private_key` | nur falls APNs genutzt: PEM-Text des Apple-`.p8`-Schlüssels (EC P-256) | Push an die Apple-Apps fällt aus; Schlüssel bei Apple neu erzeugen (oder aus dem Passwortmanager) und als neues Secret anlegen. |

**APNs-Push für die Apple-Apps (optional, ADR-0030).** Ohne diese Schritte bleibt APNs aus (`apnsAvailable:false`), das ist der Normalfall. Aktivieren:

1. Den `.p8`-Schlüssel im Apple-Developer-Konto erzeugen (APNs-Schlüssel) und als Datei sicher ablegen; Key-ID und Team-ID notieren. Den Schlüssel nie ins Repository legen.
2. Secret anlegen: `./create-secrets.sh --apns-private-key-file /pfad/AuthKey_XXXX.p8` (zusammen mit den anderen Optionen oder später in einem eigenen Aufruf; erst `--dry-run`). Das Skript prüft mit openssl, ohne etwas auszugeben, dass die Datei ein unverschlüsselter EC-P-256-Schlüssel im PEM-Format ist, übergibt den Inhalt per stdin und überschreibt nie ein vorhandenes Secret. Danach die Datei aus dem Arbeitsverzeichnis entfernen (Kopie im Passwortmanager).
3. In `stack.yaml` den Block „APNs push“, `- tt_apns_private_key` unter `secrets:` des Backends und `tt_apns_private_key:` im Top-Level-`secrets:` einkommentieren (wie bei SMTP/OIDC).
4. In `.env` `APNS_KEY_ID`, `APNS_TEAM_ID` (je 10 Zeichen) und `APNS_BUNDLE_IDS` (kommagetrennt) setzen; alle vier Werte inklusive Schlüssel sind nötig, sonst bleibt APNs aus.
5. Stack neu ausrollen (Variablen: Abschnitt 6). Prüfen: `GET /api/v1/push/config` meldet `apnsAvailable:true` (angemeldete Sitzung). Eine echte Zustellung ist erst mit den Apple-Apps und einem Testgerät prüfbar.

**VAPID-Schlüssel**: Das Backend bringt keinen Befehl dafür mit (die CLI kennt nur `serve`, `migrate`, `bootstrap-admin`, `maintenance`).
Das Skript erzeugt ihn mit dem dokumentierten openssl-Verfahren: `openssl ecparam -name prime256v1 -genkey -noout | openssl ec -outform DER | tail -c +8 | head -c 32 | base64 | tr '+/' '-_' | tr -d '=\n'`
(roher Skalar, 43 Zeichen Base64url ohne Padding). Der öffentliche Schlüssel ergibt sich daraus; die PWA holt ihn über `GET /api/v1/push/config`.

Secrets sind unveränderlich. Rotation: neues Secret mit anderem Namen (`--prefix`), `stack.yaml` anpassen (`secrets:` und `*_FILE`-Pfade), neu ausrollen, altes entfernen.

## 5. Port und Netzwerk

> **Ohne Swarm?** Für einen einzelnen Server gibt es eine einfache Variante: [`deploy/compose/`](../deploy/compose/README.md) (Compose-Datei, `.env.example`, `init-secrets.sh`, optional eine gebündelte MariaDB).

> **Dateispeicher:** Standard ohne Volumes: Dateien in der Datenbank (oder S3). Für lokale Dateiablage enthält `stack.yaml` einen auskommentierten Volume-Block (Dienst und Ende der Datei), dazu `BACKEND_PLACEMENT` auf einen festen Knoten setzen.

Der Stack veröffentlicht den Port des Backends auf **jedem Swarm-Knoten** (Routing Mesh, `mode: ingress`, Standard `PUBLISHED_PORT=18080`). Jeder Knoten leitet an ein gesundes Replikat weiter, egal auf welchem Knoten es läuft. Ein vorab angelegtes Overlay-Netz ist **nicht** nötig; der Stack nutzt nur sein eigenes Standardnetz.

- Der Reverse Proxy (außerhalb oder innerhalb von Swarm) verbindet sich mit `http://<Knoten-IP>:18080` (mehrere Knoten: als Upstream-Liste oder über eine virtuelle IP).
- **Firewall:** Erlauben Sie den Port nur Ihrem Proxy. Wer ihn direkt erreicht, könnte `X-Forwarded-For` fälschen (siehe [Reverse Proxy und TLS](installation/proxy.md#trusted-proxy-cidrs-bestimmen)).
- Das Subnetz für `TRUSTED_PROXY_CIDRS` ist hier das des `ingress`-Netzes ([Reverse Proxy und TLS](installation/proxy.md#trusted-proxy-cidrs-bestimmen)):

```sh
docker network inspect ingress --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
```

Sie können den Stack alternativ an ein gemeinsames Overlay-Netz mit einem Proxy im Swarm hängen. Dafür ergänzen Sie im Stack ein externes Netz und `networks:` am Dienst; das ist nicht die Voreinstellung und nicht erprobt.

## 6. Variablen eintragen (`.env`)

Alle Variablen mit Pflicht/optional, Standardwert und Bedeutung stehen in der **[Konfigurationsreferenz](installation/konfiguration.md)**. Für den Swarm gilt zusätzlich: Öffne `.env` (Vorlage `.env.example`) und ersetze die Beispielwerte; **Pflicht** sind die ersten Zeilen (`TIMETRACK_IMAGE`, `DB_HOST`, `PUBLIC_BASE_URL`, `WEBAUTHN_RP_ID`, `WEBAUTHN_ORIGIN`, `VAPID_SUBJECT`). Die Datei wird von der Shell eingelesen (`set -a; . ./.env; set +a`): keine Leerzeichen um `=`, Werte mit Leerzeichen in Anführungszeichen. Das Backend loggt bei ungültiger Konfiguration einen Fehler mit dem Namen der Variable (z. B. `Invalid configuration for WEBAUTHN_RP_ID: must be a lowercase hostname`) und startet nicht.

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

PWA aktualisieren: Die PWA ist Teil des Images, ein Update ist ein neues Image-Tag. In GitHub baut der Docker-Workflow die PWA aus dem Repository `timetrack-pwa` (Referenz: Repository-Variable `PWA_REF`, Standard `main`); für eine neue PWA-Version den Workflow neu starten (Push auf `main`, Tag `v*` oder manuell) und das neue Tag wie ein Backend-Update ausrollen (Abschnitt oben). Browser und Service Worker holen die neue Version beim nächsten Besuch.

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

`MODULES_DISABLED` (kommagetrennt) sperrt Funktionen für alle Konten: `reports` (Berichte/Berichtsheft), `planning`, `transfer` (Import/Export), `automation`, `mcp`. Gesperrte Module verschwinden in der PWA und antworten auf der API mit einem Fehler; Benutzer können Module zusätzlich für sich selbst abschalten (ADR-0012). Beispiel: Nur ohne KI-Anbindung `MODULES_DISABLED=mcp`. Ungültige Namen verhindern den Start. Änderung: `.env`, neu ausrollen.

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
- [ ] Reverse Proxy: HTTPS, HSTS, HTTP→HTTPS, Upload-Limit 70m, Rate-Limit für `/api/v1/auth/`, `/oauth/`; `/health` und `/ready` nicht öffentlich.
- [ ] `TRUSTED_PROXY_CIDRS` auf das Proxy-Netz (so eng wie möglich); Backend-Port **nicht** veröffentlicht (oder per Firewall nur dem Proxy zugänglich).
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
