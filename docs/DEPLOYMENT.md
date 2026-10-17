# Deployment-Anleitung: Timetrack in Produktion (Docker Swarm, eigene MariaDB, eigener Reverse Proxy)

Stand: 17.10.2026 (Paket D2). Diese Anleitung führt Schritt für Schritt zu einer laufenden Instanz unter
`https://timetrack.example.org`. Sie ersetzt nicht [BETRIEB.md](BETRIEB.md) (Backup, Restore, Hintergründe, Nachweise),
sondern verweist dorthin. Beispielwerte (`timetrack.example.test`, `db.internal.example.test`, `ABCDE12345`) sind
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
[../deploy/swarm/stack.env.example](../deploy/swarm/stack.env.example) (alle Variablen mit Beispielwerten),
[../deploy/swarm/create-secrets.sh](../deploy/swarm/create-secrets.sh) (Docker-Secrets anlegen).

## 1. Voraussetzungen

| Voraussetzung | Hinweis |
| --- | --- |
| Linux-Server, amd64, Docker (Engine) mit **aktivem Swarm** (`docker info` zeigt `Swarm: active`) | Ein Knoten genügt. `docker swarm init` ist Sache des Betreibers; diese Anleitung provisioniert nichts. |
| Zugriff auf ein **Manager**-Knoten-Terminal | Secrets und Stack werden dort angelegt. |
| DNS-Eintrag `timetrack.example.org` → Server (A/AAAA) | Muss öffentlich auflösen, wenn die iOS/macOS-App Passkeys nutzen soll (Abschnitt 11). |
| TLS-Zertifikat für den Host, am Reverse Proxy | Das Backend spricht intern nur HTTP. Browser und Passkeys brauchen HTTPS (Ausnahme nur `localhost`). |
| Reverse Proxy (nginx, Traefik o. ä.), den Sie selbst betreiben | Anforderungen und Beispiele: Abschnitt 8. |
| Vorhandene MariaDB 12.3.3 | Vom Stack aus per TCP erreichbar, TLS empfohlen (Abschnitt 3). Wird nicht verändert außer um eine neue Datenbank und einen neuen Benutzer. |
| Container-Image des Backends | Z. B. `ghcr.io/<owner>/timetrack-backend:<tag>` (Veröffentlichung durch Paket W1). Jede Registry geht, die die Knoten erreichen; bei privater Registry `docker login` und `--with-registry-auth`. Selbst bauen: BETRIEB.md Abschnitt 5.1 und 7 (nativer amd64-Build empfohlen). |
| Gebaute PWA | Teil des Container-Images: Die CI baut das Image aus Backend **und** PWA (Repository `timetrack-pwa`, Referenz `PWA_REF`, Standard `main`). Nichts auf den Knoten zu kopieren; Node wird nur beim Bauen gebraucht, nicht im Betrieb. Selbst bauen: `docker build --build-context pwa-src=../timetrack-pwa -t ... .` (EINRICHTUNG.md). |
| `openssl`, `curl` auf dem Server | Für `create-secrets.sh` und die Prüfungen. |

Das Backend und die PWA müssen zueinander passen (Vertragsversion). Das Image enthält beides; der PWA-Stand steht im Image-Label `org.opencontainers.image.pwa.revision`. Bauen Sie aus zusammengehörigen Ständen; der Vertrag steht im Kopf von
[../contracts/openapi.yaml](../contracts/openapi.yaml), der Stand der PWA in deren Repository.

## 2. Repository-Dateien auf den Server bringen

Sie brauchen nur drei Dateien aus `deploy/swarm/`. Am einfachsten das Repository (oder nur diesen Ordner) auf den Manager-Knoten kopieren:

```sh
mkdir -p ~/timetrack-deploy && cd ~/timetrack-deploy
# z. B. per scp/rsync: stack.yaml, stack.env.example, create-secrets.sh
cp stack.env.example stack.env
chmod 600 stack.env
chmod +x create-secrets.sh
```

`stack.env` enthält keine Passwörter, kann aber interne Adressen verraten: nicht ins öffentliche Repository, in ein privates Konfigurations-Repository ist in Ordnung.

## 3. Datenbank vorbereiten (vorhandene MariaDB)

Erstellen Sie auf dem MariaDB-Server eine **eigene** Datenbank und einen **eigenen** Benutzer mit den nötigen Rechten nur für diese Datenbank.
Das Passwort erzeugt das Secret-Skript (Abschnitt 4); Sie tragen es dann einmal in die SQL-Anweisung ein.

### 3.1 Starkes Passwort

Mindestens 32 zufällige Zeichen, keine Wörter. Das Skript aus Abschnitt 4 erzeugt eines (`openssl rand -base64 32`, ersetzt `+/` durch `-_`,
sodass es in SQL-Strings und Shells ohne Maskierung funktioniert). Bei selbst gewähltem Passwort: keine Anführungszeichen, Backslashes oder Zeilenumbrüche verwenden.

### 3.2 SQL

Als Administrator auf dem MariaDB-Server (`mariadb -u root -p`):

```sql
CREATE DATABASE `timetrack` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Host '%' nur, wenn der Zugriff aus dem Swarm-Netz kommt und die Firewall des DB-Servers den Zugriff begrenzt.
-- Besser: die feste Quelladresse/ das Subnetz des Swarm-Knotens, z. B. 'timetrack'@'192.0.2.%'.
CREATE USER 'timetrack'@'192.0.2.%' IDENTIFIED BY '<PASSWORT-AUS-DER-DATEI>' REQUIRE SSL;

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES
  ON `timetrack`.* TO 'timetrack'@'192.0.2.%';
FLUSH PRIVILEGES;
```

Hinweise zu den Rechten (aus dem Code abgeleitet, nicht gegen den Produktionsserver geprüft):

- Die Migrationen erzeugen und ändern Tabellen (`CREATE`, `ALTER`, `INDEX`, `REFERENCES`) und konvertieren Zeichensätze (`ALTER TABLE ... CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin`).
  `DROP` kommt im Code nur in den Rückwärts-Migrationen (`migrate --revert`) vor; für reine Vorwärts-Updates ist es vermutlich entbehrlich (nicht geprüft), daher bewusst mitgegeben. Der Betrieb selbst braucht nur `SELECT/INSERT/UPDATE/DELETE`. Wer es strenger will, gibt
  `CREATE/ALTER/DROP/INDEX/REFERENCES` nur für den Zeitraum eines Updates frei (zusätzlicher Aufwand, optional).
- **Keine** globalen Rechte (`*.*`), kein `GRANT OPTION`, kein `SUPER`/`FILE`. Der Benutzer darf nur `timetrack.*`.
- Datenbankzeichensatz `utf8mb4`; die Server-Sortierung `utf8mb4_unicode_ci` entspricht der Entwicklungsumgebung. Einzelne Tabellen setzen `utf8mb4_bin` selbst.
- `max_allowed_packet` des Servers sollte mindestens **70 MiB** betragen, wenn Dateien in der Datenbank gespeichert werden (Speicherregel „Datenbank“; Uploads bis 64 MiB, siehe handoffs/C13.md). Prüfen: `SHOW VARIABLES LIKE 'max_allowed_packet';`.
  Beispiel „alle Dateien in der Datenbank, höchstens 50 MiB“: im Admin-Bereich (Einstellungen → Dateispeicher) Speicherregel „alles → Datenbank“ (Voreinstellung) und „Größter erlaubter Upload“ = 50 MiB (`maxUploadBytes` = 52428800) setzen; dafür genügt `max_allowed_packet` ≥ 56 MiB, im Proxy `client_max_body_size` ≈ 52m. Weil die Dateien in MariaDB liegen, sehen alle Swarm-Replikate dieselben Dateien (kein verteilter Speicher nötig). Die Grenze ist eine Datenbankeinstellung (kein Umgebungswert); der feste Höchstwert der Software ist 64 MiB, die Voreinstellung 10 MiB.
- Einen **zweiten** Benutzer für Backups (nur lesen) legen Sie nach Abschnitt 14 an.

### 3.3 TLS zur Datenbank

Das Backend verwendet bei `DB_TLS=required` (Standard) TLS mit Prüfung des Serverzertifikats gegen die Zertifikatsablage des Images (Standard der verwendeten Bibliothek, `TLSConfiguration.makeClientConfiguration()`).
Folgen:

- `DB_HOST` muss **exakt dem Namen im Zertifikat** entsprechen (CN/SAN), nicht einer IP, wenn das Zertifikat nur Namen enthält.
- Ein Zertifikat einer **privaten CA** wird nicht akzeptiert, solange diese CA nicht im Image liegt. Das Projekt bietet dafür **keine** Konfiguration (kein `DB_TLS_CA_FILE`); siehe Abschnitt 17. Möglichkeiten: öffentlich vertrauenswürdiges Zertifikat (z. B. Let's Encrypt für den DB-Namen), ein eigenes Image mit installierter CA, oder `DB_TLS=off` **nur** wenn die Verbindung ausschließlich über ein privates, vertrauenswürdiges Netz läuft (Docker-Overlay verschlüsselt nicht von sich aus; WireGuard/VLAN/dieselbe Maschine).
- Auf dem Server: `ssl_cert`, `ssl_key` (und ggf. `ssl_ca`) in der MariaDB-Konfiguration gesetzt; `REQUIRE SSL` am Benutzer erzwingt die Verschlüsselung.

Verbindung vorab testen (vom Swarm-Knoten, mit dem Image selbst ginge es auch, aber der Client genügt):

```sh
mariadb -h db.internal.example.test -u timetrack -p --ssl timetrack -e 'SELECT 1, @@version'
```

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

1. Passwort für Abschnitt 3.2 aus `/root/tt-db-password.txt` entnehmen (nicht in den Shell-Verlauf kopieren; Editor öffnen und in die SQL-Sitzung einfügen), dann die **Datei löschen**: `shred -u /root/tt-db-password.txt` (oder `rm`).
2. `/root/tt-keys/tt_storage_secret_key` und `tt_vapid_private_key` in den Passwortmanager übernehmen und das Verzeichnis löschen. **Docker zeigt Secret-Werte nie wieder an.**
3. Prüfen: `docker secret ls` zeigt `tt_db_password`, `tt_storage_secret_key`, `tt_vapid_private_key`.

Weitere Optionen: `--db-password-file DATEI` (vorhandenes Passwort), `--smtp-password-file`, `--oidc-client-secret-file`, `--prefix` (anderer Namensprefix). Ohne `--db-password-file`/`--generate-db-password` fragt das Skript das Passwort ohne Echo ab.

| Secret | Inhalt | Folge des Verlusts |
| --- | --- | --- |
| `tt_db_password` | Passwort des DB-Benutzers | Neues Passwort setzen und neues Secret anlegen; kein Datenverlust. |
| `tt_storage_secret_key` | Base64 von 32 Zufallsbytes (AES-256-GCM) | **Gespeicherte S3-Zugangsdaten nicht mehr entschlüsselbar**: S3-Dateien unlesbar (HTTP 503 `storage_unavailable`), bis ein Admin die S3-Daten neu einträgt. DB und lokale Dateien nicht betroffen. Auch **nicht ohne Not rotieren**. Wird S3 nie verwendet, ist der Schaden gering, der Schlüssel muss aber gesetzt sein. |
| `tt_vapid_private_key` | P-256-Schlüssel (32 Byte, Base64url) | Push-Abonnements ungültig; Geräte müssen neu abonnieren. |
| `tt_smtp_password`, `tt_oidc_client_secret` | nur falls genutzt | Neu eintragen. |

**VAPID-Schlüssel**: Das Backend bringt keinen Befehl dafür mit (die CLI kennt nur `serve`, `migrate`, `bootstrap-admin`, `maintenance`).
Das Skript erzeugt ihn mit dem dokumentierten openssl-Verfahren: `openssl ecparam -name prime256v1 -genkey -noout | openssl ec -outform DER | tail -c +8 | head -c 32 | base64 | tr '+/' '-_' | tr -d '=\n'`
(roher Skalar, 43 Zeichen Base64url ohne Padding). Der öffentliche Schlüssel ergibt sich daraus; die PWA holt ihn über `GET /api/v1/push/config`.

Secrets sind unveränderlich. Rotation: neues Secret mit anderem Namen (`--prefix`), `stack.yaml` anpassen (`secrets:` und `*_FILE`-Pfade), neu ausrollen, altes entfernen.

## 5. Port und Netzwerk

> **Dateispeicher:** Standard ohne Volumes: Dateien in der Datenbank (oder S3). Für lokale Dateiablage enthält `stack.yaml` einen auskommentierten Volume-Block (Dienst und Ende der Datei), dazu `BACKEND_PLACEMENT` auf einen festen Knoten setzen.

Der Stack veröffentlicht den Port des Backends auf **jedem Swarm-Knoten** (Routing Mesh, `mode: ingress`, Standard `PUBLISHED_PORT=18080`). Jeder Knoten leitet an ein gesundes Replikat weiter, egal auf welchem Knoten es läuft. Ein vorab angelegtes Overlay-Netz ist **nicht** nötig; der Stack nutzt nur sein eigenes Standardnetz.

- Der Reverse Proxy (außerhalb oder innerhalb von Swarm) verbindet sich mit `http://<Knoten-IP>:18080` (mehrere Knoten: als Upstream-Liste oder über eine virtuelle IP).
- **Firewall:** Erlauben Sie den Port nur Ihrem Proxy. Wer ihn direkt erreicht, könnte `X-Forwarded-For` fälschen (siehe Abschnitt 9).
- Das Subnetz für `TRUSTED_PROXY_CIDRS` ist hier das des `ingress`-Netzes (Abschnitt 9):

```sh
docker network inspect ingress --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
```

Sie können den Stack alternativ an ein gemeinsames Overlay-Netz mit einem Proxy im Swarm hängen. Dafür ergänzen Sie im Stack ein externes Netz und `networks:` am Dienst; das ist nicht die Voreinstellung und nicht erprobt.

## 6. Variablen eintragen (`stack.env`)

Öffnen Sie `stack.env` und ersetzen Sie die Beispielwerte. **Pflicht** sind die ersten Zeilen; alles andere hat einen sinnvollen Standard.
Die Datei wird von der Shell eingelesen (`set -a; . stack.env; set +a`): keine Leerzeichen um `=`, Werte mit Leerzeichen in Anführungszeichen.

| Variable | Pflicht? | Beispielwert | Bedeutung / Regeln (aus `Configuration.swift`) |
| --- | --- | --- | --- |
| `TIMETRACK_IMAGE` | ja | `ghcr.io/OWNER/timetrack-backend:1.0.0` | Image von Backend und Migrationsjob. Feste Version statt `latest`. |
| `DB_HOST` | ja | `db.internal.example.test` | Name des DB-Servers; bei `DB_TLS=required` muss er zum Zertifikat passen. |
| `DB_PORT`, `DB_NAME`, `DB_USER` | nein | `3306`, `timetrack`, `timetrack` | Wie in Abschnitt 3. |
| `DB_TLS` | nein | `required` | `required` (Standard) oder `off`. Siehe 3.3. |
| `PUBLIC_BASE_URL` | ja | `https://timetrack.example.org` | Öffentliche Adresse. Muss HTTPS sein (HTTP nur für `localhost`), ohne Zugangsdaten, Query, Fragment. Bestimmt Einladungslinks, OAuth-URLs und das `Secure`-Flag des Cookies. |
| `WEBAUTHN_RP_ID` | ja | `timetrack.example.org` | Relying-Party-ID: Kleinbuchstaben-Hostname, ohne Schema/Port/Pfad. **Nachträgliche Änderung entwertet alle Passkeys** (Abschnitt 10). |
| `WEBAUTHN_ORIGIN` | ja | `https://timetrack.example.org` | Muss exakt dem Browser-Origin entsprechen (Schema + Host, kein Pfad); der Host muss RP-ID oder deren Subdomain sein. |
| `WEBAUTHN_RP_NAME` | nein | `Timetrack` | Anzeigename im Passkey-Dialog. |
| `VAPID_SUBJECT` | im Stack ja | `mailto:admin@example.org` | Kontakt für Push-Dienste: `mailto:` oder `https://`. Ungültig oder fehlend: Push bleibt aus (Warnung im Log). |
| `PUBLISHED_PORT` | nein | `18080` | TCP-Port, der auf jedem Knoten veröffentlicht wird (Routing Mesh). Proxy-Upstream: `http://<Knoten-IP>:<Port>`. |
| `TRUSTED_PROXY_CIDRS` | dringend empfohlen | `10.0.1.0/24` | Netze der Proxys, deren `X-Forwarded-For` geglaubt wird (Abschnitt 9). Leer = niemand. `/0` wird abgelehnt, ungültige Einträge verhindern den Start. |
| `TRUSTED_PROXY_HEADER` | nein | `X-Forwarded-For` | Oder `X-Real-IP`. |
| `APPLE_APP_IDS` | für die iOS/macOS-App | `ABCDE12345.com.example.timetrack` | Komma-getrennt, jeder Eintrag `<10-stellige Team-ID>.<Bundle-ID>`; ungültige Einträge verhindern den Start. Leer = AASA-Endpunkt antwortet 404. **`ABCDE12345` ist ein Platzhalter.** |
| `PUSH_ALLOWED_HOSTS` | nein | `fcm.googleapis.com,updates.push.services.mozilla.com,web.push.apple.com,*.notify.windows.com` | Ersetzt die eingebaute Liste erlaubter Push-Dienste (ADR-0011); getesteter Vorschlag. Leer = eingebaute Liste. |
| `NOTIFICATIONS_ENABLED` | nein | `true` | Hintergrund-Erinnerungen. |
| `SESSION_TTL_HOURS` | nein | `336` | Sitzungsdauer 1..8760 Stunden (Stack-Standard 336; Code-Standard 720). |
| `MODULES_DISABLED` | nein | `mcp` | Betreibersperre: `reports,planning,transfer,automation,mcp` (Abschnitt 16). |
| `MAINTENANCE_INTERVAL_MINUTES` u. a. | nein | `60`, `90`, `168`, `168` | Wartungsjob (ADR-0017): Intervall (0 = aus), `MCP_AUDIT_RETENTION_DAYS`, `IMPORT_JOB_TIMEOUT_HOURS`, `STORAGE_ORPHAN_GRACE_HOURS`. |
| `BACKEND_REPLICAS` | nein | `1` | Beim ersten Deployment `0` (Abschnitt 7). |
| `BACKEND_PLACEMENT` | nein | `"node.platform.os == linux"` | Optionale Platzierungsbedingung. Keine feste Knotenbindung nötig (PWA im Image, Dateien in der Datenbank); z. B. `"node.labels.timetrack == true"` zum Einschränken. |
| `SMTP_*` | nein | siehe Datei | E-Mail-Wiederherstellung. Alle Zeilen aktivieren (auch Block und Secret in `stack.yaml`): `SMTP_HOST`, `SMTP_PORT`, `SMTP_TLS` (`starttls`/`implicit`), `SMTP_FROM`, `SMTP_FROM_NAME`, `SMTP_USER` + Secret `tt_smtp_password`. `SMTP_USER` und Passwort nur gemeinsam; `SMTP_TLS=off` nur für Loopback-Testhosts. |
| `OIDC_*` | nein | siehe Datei | Optionales OpenID-Connect (ADR-0007): `OIDC_ISSUER` (HTTPS), `OIDC_CLIENT_ID`, `OIDC_NAME`, `OIDC_SCOPES` (muss `openid` enthalten) + Secret `tt_oidc_client_secret`. Nur zusammen mit dem Block in `stack.yaml`. |
| S3 | – | – | Wird **nicht** per Variable konfiguriert, sondern im Admin-Bereich der PWA (Speicherregeln); Zugangsdaten liegen verschlüsselt in der Datenbank (`STORAGE_SECRET_KEY`). |

Das Backend loggt bei ungültiger Konfiguration einen Fehler mit dem Namen der Variable (z. B. `Invalid configuration for WEBAUTHN_RP_ID: must be a lowercase hostname`) und startet nicht.

Dateispeicher in der Datenbank: Der Stack hat **keine Volumes**. Hochgeladene Dateien liegen in der Datenbank (und damit im DB-Backup). Stellen Sie nach dem ersten Login im Admin-Bereich bei den Speicherregeln „alles → Datenbank“ ein und setzen Sie ein globales Upload-Limit (Beispiel: 50 MiB). Die Speicherart „Lokal“ steht im Stack nicht zur Verfügung (kein beschreibbarer Pfad, Root-Dateisystem schreibgeschützt); S3 ist über den Admin-Bereich weiterhin möglich.

## 7. Erstes Deployment

Reihenfolge: **Migration → Dienst → Gesundheitsprüfung.** Swarm kennt keine Reihenfolge zwischen Diensten, deshalb startet das Backend zuerst mit 0 Replikaten.

```sh
cd ~/timetrack-deploy
set -a; . ./stack.env; set +a

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

Schlägt der Migrationsjob fehl (`Failed`, `Rejected`): `docker service logs timetrack_migrate`. Häufig: DB nicht erreichbar, TLS-Fehler, fehlende Rechte (Abschnitt 18). Nach der Korrektur den Job erneut starten: `docker service update --force timetrack_migrate`.

Wichtig: `docker stack deploy` setzt `replicas` aus der Datei zurück. Wenn Sie später erneut deployen, ohne `BACKEND_REPLICAS` zu setzen, gilt der Wert aus `stack.env` (hier `1`).

Gesundheit des Dienstes (der Container-Healthcheck ruft `/ready` auf: Datenbank erreichbar und alle Migrationen angewendet):

```sh
docker ps --filter name=timetrack_backend --format '{{.Names}} {{.Status}}'        # (healthy)
docker exec "$(docker ps -q -f name=timetrack_backend)" curl -fsS http://127.0.0.1:8080/ready
docker exec "$(docker ps -q -f name=timetrack_backend)" curl -fsS http://127.0.0.1:8080/health
```

(`docker exec` und `docker ps` zeigen nur Container des **eigenen** Knotens.)

## 8. Reverse Proxy

Der Proxy terminiert TLS und leitet **alles** an das Backend (es liefert auch die PWA aus). Ziel: `http://<Knoten-IP>:18080` (der veröffentlichte Port, `PUBLISHED_PORT`).
Der Name `backend` ist ebenfalls als Alias vorhanden, kann aber mit Diensten anderer Stacks kollidieren; der volle Name `timetrack_backend` ist eindeutig.

Anforderungen (aus Code und BETRIEB.md Abschnitt 6):

| Thema | Anforderung |
| --- | --- |
| TLS/HTTP | HTTPS für `timetrack.example.org`, HTTP/2 empfohlen, HTTP→HTTPS-Umleitung, HSTS (`max-age=31536000`). Auf dem Weg zum Backend darf HTTP/1.1 genutzt werden. |
| Header | `Host`, `X-Forwarded-For` (anhängen), `X-Forwarded-Proto`. Das Backend baut URLs aus `PUBLIC_BASE_URL`, nicht aus dem Host-Header. |
| `/.well-known/apple-app-site-association` | **Unverändert durchreichen**: kein Redirect, keine Authentifizierung, kein Umschreiben, `Content-Type: application/json` (setzt das Backend selbst; nicht überschreiben), HTTP 200 direkt. Auch `/.well-known/oauth-*` (MCP/OAuth) durchreichen. |
| Caching | `/api/` nicht cachen (kein Proxy-Cache). Das Backend setzt für die PWA selbst `Cache-Control` (hashierte Dateien `immutable`, sonst `no-cache`); nicht überschreiben. Keine Komprimierung ist erforderlich. |
| Upload | Dateien bis 64 MiB plus 64 KiB Multipart-Aufschlag: Körpergrenze **mindestens 65 MiB** (hier 70m), Lese-/Sendezeitüberschreitung ≥ 120 s. |
| `/mcp` | Streamable HTTP nur per `POST` mit JSON-Antwort: kein SSE, kein WebSocket, keine Upgrade-Header, kein Streaming-Puffer nötig. `GET /mcp` liefert absichtlich 405. Körper ≤ 256 KiB. |
| `/health`, `/ready` | Nicht öffentlich weiterreichen (Informationen über Datenbankzustand). Der Docker-Healthcheck braucht sie nicht über den Proxy. |
| Rate-Limit | Zusätzlich am Proxy für `/api/v1/auth/`, `/api/v1/me/recovery/`, `/oauth/` (z. B. 10 Anfragen/s je IP). |
| Echte Client-IP | Siehe Abschnitt 9: im Swarm den Proxy-Port im **Host-Modus** veröffentlichen (nicht über das Routing Mesh), sonst sieht der Proxy eine Mesh-Adresse. |

### 8.1 nginx

Variante A: nginx **im Swarm** am selben Overlay-Netz (Ziel `timetrack_backend:8080`; die `resolver`-Zeile von Docker nötig, damit Neustarts des Backends nicht an alten IPs hängen).
Variante B: nginx auf dem Host: Dann ist das Overlay-Netz nicht erreichbar; Sie müssen in `stack.yaml` den auskommentierten `ports:`-Block (Host-Modus, z. B. `18080`) aktivieren und den Port per Firewall auf den Proxy begrenzen; Ziel dann `127.0.0.1:18080` bzw. die Host-Adresse. Nicht erprobt.

```nginx
# /etc/nginx/conf.d/timetrack.conf (Zertifikatspfade anpassen)
server {
    listen 80;
    listen [::]:80;
    server_name timetrack.example.org;
    return 301 https://$host$request_uri;       # gilt NICHT für ACME-Challenges, falls Sie HTTP-01 nutzen: dort ausnehmen
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name timetrack.example.org;

    ssl_certificate     /etc/letsencrypt/live/timetrack.example.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/timetrack.example.org/privkey.pem;
    add_header Strict-Transport-Security "max-age=31536000" always;

    client_max_body_size 70m;                   # 64 MiB Datei + Multipart-Aufschlag
    proxy_request_buffering off;                # Uploads nicht erst auf Platte puffern
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    resolver 127.0.0.11 valid=10s;              # Docker-DNS (nur nginx IM Swarm); auf dem Host weglassen
    set $upstream http://192.0.2.10:18080;     # Knoten-IP und PUBLISHED_PORT

    location = /health { return 404; }
    location = /ready  { return 404; }

    # Apple-Datei: unverändert durchreichen, kein Redirect, kein Auth, kein Cache-Header-Umbau.
    location = /.well-known/apple-app-site-association {
        proxy_pass $upstream;
        proxy_set_header Host $host;
    }

    location /api/ {
        proxy_pass $upstream;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_no_cache 1;
        proxy_cache_bypass 1;
    }

    location / {
        proxy_pass $upstream;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection        "";
    }
}
```

`X-Forwarded-For` mit `$proxy_add_x_forwarded_for` **anhängt** die Client-Adresse an einen vom Client mitgesendeten Wert; das Backend liest den Header von rechts und ignoriert vorangestellte Fälschungen, sofern `TRUSTED_PROXY_CIDRS` genau Ihren Proxy umfasst.
Steht ein weiterer Proxy (z. B. Cloudflare) davor, gehört dessen Netz ebenfalls in `TRUSTED_PROXY_CIDRS`.
Anmerkung: Der `location /`-Block liefert auch `/oauth/*`, `/mcp` und `/.well-known/oauth-*`; kein weiterer Block nötig.

### 8.2 Traefik (v3, Swarm-Provider)

**Hinweis:** Die Label-Variante unten setzt voraus, dass Traefik im selben Swarm läuft und mit dem Backend ein Netz teilt (nicht Teil dieses Stacks). Mit dem veröffentlichten Port ist die dynamische Datei-Konfiguration einfacher: Router `Host(`timetrack.example.org`)` und ein Service mit `servers: - url: "http://192.0.2.10:18080"` (mehrere Knoten: mehrere `url`-Einträge).

Traefik liest Labels aus dem **Dienst** (im Swarm unter `deploy.labels`). Ergänzen Sie im Dienst `backend` in `stack.yaml` den vorhandenen `deploy:`-Block um `labels:` (Entrypoint- und Resolver-Namen an Ihre Traefik-Konfiguration anpassen):

```yaml
    deploy:
      labels:
        - traefik.enable=true
        - traefik.http.services.timetrack.loadbalancer.server.port=8080
        - traefik.http.routers.timetrack.rule=Host(`timetrack.example.org`) && !Path(`/health`) && !Path(`/ready`)
        - traefik.http.routers.timetrack.entrypoints=websecure
        - traefik.http.routers.timetrack.tls.certresolver=letsencrypt
        - traefik.http.routers.timetrack.middlewares=timetrack-headers
        - traefik.http.middlewares.timetrack-headers.headers.stsSeconds=31536000
```

(Die Labels gehören unter `deploy.labels`, nicht unter `labels:`: nur dort sieht sie der Swarm-Provider. Die Regel schließt `/health` und `/ready` von der Weiterleitung aus.)

Statische Traefik-Konfiguration (Auszug, beim Traefik-Dienst selbst):

```yaml
entryPoints:
  websecure:
    address: ":443"
    http:
      tls: {}
    transport:
      respondingTimeouts:
        readTimeout: 300s        # Uploads bis 64 MiB; Traefik v3 begrenzt das Lesen standardmäßig (Wert in Ihrer Version prüfen)
        writeTimeout: 300s
        idleTimeout: 180s
    forwardedHeaders:
      trustedIPs: []             # nur eintragen, wenn davor ein weiterer Proxy steht (dann dessen Netz)
```

Traefik setzt `X-Forwarded-For` und `X-Forwarded-Proto` selbst, begrenzt die Anfragegröße **nicht** (keine `buffering`-Middleware verwenden, außer mit `maxRequestBodyBytes` ≥ 70 MiB) und leitet `/.well-known/*` ohne Umschreiben weiter. HTTP/2 ist an TLS-Entrypoints standardmäßig an.
Das Traefik-Beispiel wurde **nicht** gegen eine laufende Traefik-Instanz getestet.

Damit Traefik die echte Client-IP sieht: Ports 80/443 des Traefik-Dienstes im **Host-Modus** veröffentlichen (`mode: host`), nicht über das Routing Mesh.

## 9. `TRUSTED_PROXY_CIDRS` bestimmen

1. Subnetz des `ingress`-Netzes (das Backend sieht hinter dem Routing Mesh diese Adresse als Verbindungspartner): `docker network inspect ingress --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'` (z. B. `10.0.0.0/24`).
2. Zugriffsrechte beachten: Vertrauen Sie nur dem Netz, in dem **ausschließlich der Proxy** Verbindungen zum Backend aufbauen kann. Hängen weitere Dienste im selben Netz, legen Sie ein eigenes Netz nur für Proxy und Backend an, oder tragen Sie die feste Proxy-Adresse als `/32` ein.
3. In `stack.env`: `TRUSTED_PROXY_CIDRS=10.0.0.0/24`, `TRUSTED_PROXY_HEADER=X-Forwarded-For`, neu ausrollen (Abschnitt 13).
4. Prüfen: Rate-Limit-Verhalten, siehe BETRIEB.md Abschnitt 6, Schritt 3. Ohne die Einstellung teilen sich **alle** Clients einen Zähler (60 Ereignisse je 5 Minuten): ein Angreifer sperrt die Anmeldung für alle. Pro Konto gilt zusätzlich eine eigene Grenze (15 je 5 Minuten).

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
Der Befehl schreibt den Link nur auf die Konsole; das Backend protokolliert Einladungs-URLs nicht. Dieser Weg ist **nicht auf einem echten Swarm erprobt**; im Compose-Betrieb ist `docker compose run --rm -T backend bootstrap-admin` belegt (TESTUMGEBUNGEN.md).

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

Vorher ein Backup (Abschnitt 14).

```sh
cd ~/timetrack-deploy
set -a; . ./stack.env; set +a
export NEUES_IMAGE=ghcr.io/OWNER/timetrack-backend:1.1.0    # neue Version; in stack.env nachführen

# 1. Migration zuerst (idempotent; ohne offene Migrationen passiert nichts)
docker service update --force --image "$NEUES_IMAGE" timetrack_migrate
docker service ps timetrack_migrate                          # Complete abwarten; bei Fehler: Logs lesen, NICHT weitermachen

# 2. Backend aktualisieren (Rolling Update, start-first, Rollback bei Fehlschlag)
docker service update --with-registry-auth --image "$NEUES_IMAGE" timetrack_backend
docker service ps timetrack_backend
```

Oder: `TIMETRACK_IMAGE` in `stack.env` ändern, `docker stack deploy ...` erneut ausführen (Migrationsjob **vor** dem Backend abwarten; mit `BACKEND_REPLICAS=0` beginnen, wenn das Schema geändert wird).

Verhalten: Das neue Backend wird erst „healthy“, wenn `/ready` 200 liefert (Datenbank erreichbar, alle Migrationen angewendet). Ohne vorherige Migration bleibt es ungesund; `update_config` rollt automatisch zurück (`failure_action: rollback`, 60 s Beobachtung). Tritt das ein, ist der Dienst auf der alten Version geblieben.

Manueller Rollback des Images: `docker service rollback timetrack_backend`. **Das Schema wird nicht zurückgerollt.** Ein Rückgang auf eine ältere Version nach einer angewendeten Migration ist nur sicher, wenn die Migration abwärtskompatibel war (nicht zugesichert); im Zweifel Restore aus dem Backup vor Schritt 1 (BETRIEB.md Abschnitt 3). Bei Migrationen mit zerstörenden Änderungen (Release-Hinweise lesen) das Backend vorher auf 0 skalieren: `docker service scale timetrack_backend=0`.

PWA aktualisieren: Die PWA ist Teil des Images, ein Update ist ein neues Image-Tag. In GitHub baut der Docker-Workflow die PWA aus dem Repository `timetrack-pwa` (Referenz: Repository-Variable `PWA_REF`, Standard `main`); für eine neue PWA-Version den Workflow neu starten (Push auf `main`, Tag `v*` oder manuell) und das neue Tag wie ein Backend-Update ausrollen (Abschnitt oben). Browser und Service Worker holen die neue Version beim nächsten Besuch.

## 14. Backup und Restore

Verbindliche Beschreibung, Archivformat, Nachweise: [BETRIEB.md](BETRIEB.md) Abschnitte 1 bis 4. Kurzfassung für diese Installation:

1. **Backup-Benutzer** (nur lesen) in MariaDB: `CREATE USER 'ttbackup'@'192.0.2.%' IDENTIFIED BY '...' REQUIRE SSL; GRANT SELECT, SHOW VIEW, TRIGGER ON timetrack.* TO 'ttbackup'@'192.0.2.%';` (Rechtemenge nicht gegen den Produktionsserver geprüft; `mariadb-dump --single-transaction` braucht in der Regel `SELECT`).
2. **Datenbank** sichern (Host-Modus, Client `mariadb-dump` auf dem Backup-Host nötig, Passwort aus Datei):
   `DB_HOST=db.internal.example.test DB_USER=ttbackup DB_PASSWORD_FILE=/root/tt-backup-pw scripts/backup.sh --driver mariadb --db-name timetrack --out /backups`
3. **Dateien**: Liegen sie in der Datenbank (Empfehlung, Stack ohne Volumes), sind sie im Datenbank-Backup enthalten; `--local-files` entfällt. Nur wenn Sie den Stack selbst um einen Bind-Mount für die Speicherart „Lokal“ erweitern, gilt: das Backend speichert den **echten Pfad im Container** in der Datenbank, das Skript prüft gegen den Host-Pfad; nur mit identischem Pfad auf Host und Container sinnvoll, nicht erprobt.
4. **S3-Objekte** separat sichern (BETRIEB.md Abschnitt 2).
5. **Nicht im Archiv, getrennt aufbewahren**: `STORAGE_SECRET_KEY`, VAPID-Schlüssel, DB-Passwort, `stack.env`, Proxy-Konfiguration.
6. Archive verschlüsseln (`age`/`gpg`), außerhalb des Servers ablegen, zeitgesteuert (cron/systemd-Timer) laufen lassen. **Das Projekt liefert keinen Zeitplan.**
7. Restore: Backend auf 0 skalieren, `scripts/restore.sh` (Ziel-DB leer), mit den **ursprünglichen** Secrets und derselben `WEBAUTHN_RP_ID` wieder starten, bei neuerem Image zuerst die Migration. Mindestens einmal vorher auf einer Kopie üben.

## 15. Überwachung und Logs

- Logs: `docker service logs -f --tail 100 timetrack_backend` (JSON-Datei-Treiber mit Rotation 10 MiB × 5 je Dienst und Knoten). Für zentrale Logs den `logging:`-Block anpassen. Einladungs-URLs, Passwörter und Schlüssel werden nicht protokolliert.
- Zustand: `docker service ps timetrack_backend`, `docker service ls`, `docker inspect --format '{{json .State.Health}}' <container>`.
- Endpunkte: `GET /health` (Prozess lebt), `GET /ready` (Datenbank + Migrationen). Es gibt **keinen** `/metrics`-Endpunkt. Externe Überwachung (z. B. Uptime-Check auf `https://timetrack.example.org/` und die Startseite der PWA) einrichten.
- Wartungsjob: läuft im Backend alle `MAINTENANCE_INTERVAL_MINUTES` Minuten; einmalig manuell: `docker exec -it <container> /app/docker-entrypoint.sh maintenance --env production`.
- Ressourcen: Standardlimits 1 CPU / 768 MiB (Backend). Uploads bis 64 MiB werden im Speicher gesammelt; die Werte wurden unter Last nicht gemessen.

## 16. Modulschalter

`MODULES_DISABLED` (kommagetrennt) sperrt Funktionen für alle Konten: `reports` (Berichte/Berichtsheft), `planning`, `transfer` (Import/Export), `automation`, `mcp`. Gesperrte Module verschwinden in der PWA und antworten auf der API mit einem Fehler; Benutzer können Module zusätzlich für sich selbst abschalten (ADR-0012). Beispiel: Nur ohne KI-Anbindung `MODULES_DISABLED=mcp`. Ungültige Namen verhindern den Start. Änderung: `stack.env`, neu ausrollen.

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

| Symptom | Wahrscheinliche Ursache | Abhilfe |
| --- | --- | --- |
| Browser zeigt 502/503 vom Proxy | Backend nicht gestartet oder Port nicht erreichbar (Firewall, falsche Knoten-IP/`PUBLISHED_PORT`); Replikate 0 | `docker service ps timetrack_backend`; Netz `PROXY_NETWORK` gleich beim Proxy und im Stack; Ziel `timetrack_backend:8080`; `docker service scale timetrack_backend=1`. |
| Dienst startet nicht, Log: `Invalid configuration for X` | Variable ungültig (RP-ID mit Großbuchstaben, Origin mit Pfad, ungültiges CIDR, `OIDC_ISSUER` ohne HTTPS ...) | Wert in `stack.env` korrigieren, neu ausrollen. |
| Dienst ist „unhealthy“, `/ready` = 503 | Migration nicht gelaufen oder DB nicht erreichbar | `docker service logs timetrack_migrate`; Migration ausführen (Abschnitt 13); DB-Erreichbarkeit, Passwort, TLS prüfen. |
| Migrationsjob `Failed`: Verbindung/TLS-Fehler | Falscher `DB_HOST`, Firewall, Zertifikatsname passt nicht, private CA | Abschnitt 3.3; Verbindung mit dem `mariadb`-Client testen; `REQUIRE SSL` ohne TLS am Client. |
| Migrationsjob `Failed`: Zugriff verweigert / `Access denied` | Falsches Passwort oder Benutzer-Host passt nicht zur Quelladresse | Passwort im Secret = Passwort in der DB? `'timetrack'@'<Host>'` auf die Quelladresse (Knoten-IP) anpassen. |
| Migrationsjob `Failed`: `CREATE command denied` | Rechte fehlen | `GRANT` aus 3.2 nachholen. |
| Container „Rejected“, `secret not found` | Secret fehlt oder anderer Name | `docker secret ls`; Namen in `stack.yaml` und Prefix des Skripts abgleichen. |
| Container beendet sich mit Exit 64/66 | Variable und `_FILE` gleichzeitig gesetzt / Datei nicht lesbar | Nicht zusätzlich `DB_PASSWORD=` setzen; Secret im Dienst eingehängt? |
| Passkey-Anmeldung/Registrierung schlägt fehl („Origin“, „RP ID“) | `WEBAUTHN_ORIGIN`/`WEBAUTHN_RP_ID` weichen vom Browser-Host ab (www, Port, http); Proxy ändert Host | Browser-Adresse = `WEBAUTHN_ORIGIN`; RP-ID = Host ohne Schema. Nach Änderung neu ausrollen. Nach RP-ID-Wechsel sind alte Passkeys wertlos. |
| „Zu viele Anfragen“ (429) bei Anmeldung für alle | `TRUSTED_PROXY_CIDRS` fehlt oder falsches Netz: alle Clients teilen einen Zähler | Subnetz des Proxys eintragen (Abschnitt 9); Proxy im Host-Modus veröffentlichen; Wartezeit abwarten (5 Minuten). |
| Rate-Limit trifft nur einen Nutzer | Zähler pro Konto (15 je 5 Minuten) | Warten oder anderen Zugang nutzen; kein Fehler. |
| Push kommt nicht an | VAPID-Schlüssel/-Subjekt ungültig (Log-Warnung `Web Push stays unavailable`); `GET /api/v1/push/config` meldet `available:false`; `PUSH_ALLOWED_HOSTS` blockiert den Dienst; ausgehende Verbindung gesperrt; Gerät hat nicht abonniert | Secret/Subjekt prüfen; Liste enthält den Push-Host des Geräts (FCM, Mozilla, Apple, WNS); Egress-Firewall; Abo in der PWA erneuern. |
| AASA liefert 404 | `APPLE_APP_IDS` leer oder Stack nicht neu ausgerollt | Setzen und ausrollen (Abschnitt 11). |
| AASA liefert 301/302 oder HTML | Proxy leitet um oder fängt den Pfad ab | `/.well-known/` ohne Umleitung/Fallback durchreichen (Abschnitt 8). |
| Apples CDN findet die Datei nicht | Domain nicht öffentlich/zertifikat ungültig/Cache noch alt | Abschnitt 11, Prüfbefehle; später erneut prüfen. |
| Upload bricht ab (413 oder Verbindungsabbruch) | Proxy-Limit oder -Zeitüberschreitung zu klein | `client_max_body_size 70m`, Timeouts ≥ 120 s (Abschnitt 8). |
| Datei-Upload scheitert / „Lokal“ nicht nutzbar | Der Stack hat keine Volumes; Speicherregel steht auf „Lokal“ | Im Admin-Bereich „alles → Datenbank“ (oder S3) wählen, Upload-Limit prüfen. |
| `/` liefert 404 statt PWA | Image ohne PWA gebaut (Build ohne `pwa-src`) | Image aus dem Docker-Workflow verwenden; `docker run --rm --entrypoint ls IMAGE /srv/pwa` muss `index.html` zeigen. |
| S3-Dateien unlesbar (503 `storage_unavailable`) | Falscher/neuer `STORAGE_SECRET_KEY` | Ursprünglichen Schlüssel als Secret wiederherstellen; sonst S3-Zugangsdaten im Admin-Bereich neu eintragen. |
| PWA lädt, aber API-Fehler/CORS/Cookie fehlt | `PUBLIC_BASE_URL` ohne `https` (Cookie nicht `Secure`) oder abweichender Host | Alle drei URLs auf die öffentliche HTTPS-Adresse setzen. |
| `bootstrap-admin` meldet Konflikt | Es existiert schon ein Konto | Weitere Personen per Einladung in der PWA; Verlust des Admin-Zugangs: Wiederherstellungsoptionen des Kontos nutzen. |
| MCP-Client verbindet nicht | Modul `mcp` gesperrt; `/.well-known/oauth-*` nicht durchgereicht; `PUBLIC_BASE_URL` falsch | Abschnitte 8 und 16; MCP.md. |

## 19. Sicherheits-Checkliste

- [ ] Alle Secrets als Docker-Secrets (kein Passwort in `stack.env`, Image, Repository oder Shell-Verlauf); Wert-Dateien nach dem Anlegen gelöscht.
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
2. [ ] MariaDB: Datenbank und Benutzer angelegt, TLS-Verbindung getestet (Abschnitt 3).
3. [ ] Secrets angelegt (`docker secret ls` zeigt drei bis fünf `tt_*`), Schlüssel gesichert (Abschnitt 4).
4. [ ] Overlay-Netz vorhanden, Proxy daran angeschlossen; Subnetz in `TRUSTED_PROXY_CIDRS` (Abschnitte 5, 9).
5. [ ] `stack.env` ausgefüllt; `docker stack config -c stack.yaml` ohne Fehler (Abschnitte 6, 7).
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
