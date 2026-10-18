# Probleme und Lösungen

- **Wofür:** Symptome beim Installieren und Betreiben, ihre Ursachen und Abhilfen an einer Stelle.
- **Voraussetzungen:** Zugriff auf das Terminal des Servers (Logs: `docker compose logs backend migrate` bzw. `docker service logs timetrack_backend`).
- **Dauer:** je Problem wenige Minuten.

Gehe zuerst diese Reihenfolge durch: (1) `/ready` aufrufen, (2) Logs von Migration und Backend lesen, (3) die Tabelle unten. Ungültige Konfiguration verhindert den Start und nennt die Variable im Log.

| Symptom | Wahrscheinliche Ursache | Abhilfe |
| --- | --- | --- |
| `docker exec … bootstrap-admin`: `executable file not found in $PATH` | `bootstrap-admin` ist ein Unterbefehl des Einstiegspunkts, keine Programmdatei | `/app/docker-entrypoint.sh bootstrap-admin --env production` (Swarm) oder `docker compose run --rm --no-deps -T backend bootstrap-admin --env production` (Compose). |
| Swarm: Variablen leer, „set TIMETRACK_IMAGE“ | `docker stack deploy` liest keine `.env` | Zuerst `set -a; . ./stack.env; set +a`. |
| `network … could not be found` | Alte Stack-Version | Aktuelle `stack.yaml` laden und neu ausrollen. |
| Log oder Antwort: `Connection request timed out` | Der Datenbank-Verbindungspool ist ausgeschöpft: zu wenige Verbindungen pro Event-Loop oder `max_connections`/`MAX_USER_CONNECTIONS` der Datenbank zu niedrig; auch langsame Abfragen oder ein überlasteter DB-Server | `DB_POOL_CONNECTIONS_PER_LOOP` (1 bis 8, Standard 1) und `DB_POOL_TIMEOUT_SECONDS` (Standard 10; unter `environment` in `compose.yaml`/`stack.yaml` ergänzen) erhöhen **und** prüfen, dass `max_connections` und `MAX_USER_CONNECTIONS` für Kerne × Wert × Replikate reichen (`SHOW VARIABLES LIKE 'max_connections';`). Siehe [Konfigurationsreferenz](konfiguration.md). |
| „Der Server ist gerade nicht bereit.“ in der Web-App oder `/ready` = 503 | Datenbank nicht erreichbar oder Migration fehlt (das Backend migriert nie von selbst) | `docker compose logs migrate backend` bzw. `docker service logs timetrack_migrate`; Migration ausführen, danach `/ready` erneut prüfen. Der Container-Healthcheck ruft `/ready` auf. |
| Verbindung zur Datenbank bricht nach Leerlauf ab | Firewall oder Datenbank trennt ruhende Verbindungen | `DB_KEEPALIVE_SECONDS` (Standard 45) senken; `wait_timeout` der Datenbank prüfen. |
| Browser zeigt 502/503 vom Proxy | Backend nicht gestartet oder Port nicht erreichbar (Firewall, falsche Knoten-IP/`PUBLISHED_PORT`); Replikate 0 | `docker service ps timetrack_backend`; Ziel des Proxys prüfen (`127.0.0.1:18080` bei Compose, `<Knoten-IP>:18080` im Swarm); Swarm: `docker service scale timetrack_backend=1`; Compose: `docker compose ps`. |
| Dienst startet nicht, Log: `Invalid configuration for X` | Variable ungültig (RP-ID mit Großbuchstaben, Origin mit Pfad, ungültiges CIDR, `OIDC_ISSUER` ohne HTTPS ...) | Wert in `stack.env` korrigieren, neu ausrollen. |
| Dienst ist „unhealthy“, `/ready` = 503 | Migration nicht gelaufen oder DB nicht erreichbar | `docker service logs timetrack_migrate`; Migration ausführen ([Aktualisieren](../UPDATE.md)); DB-Erreichbarkeit, Passwort, TLS prüfen. |
| Migrationsjob `Failed`: Verbindung/TLS-Fehler | Falscher `DB_HOST`, Firewall, Zertifikatsname passt nicht, private CA | [Eigene MariaDB](mariadb.md) (TLS); Verbindung mit dem `mariadb`-Client testen; `REQUIRE SSL` ohne TLS am Client. |
| Migrationsjob `Failed`: Zugriff verweigert / `Access denied` | Falsches Passwort oder Benutzer-Host passt nicht zur Quelladresse | Passwort im Secret = Passwort in der DB? `'timetrack'@'<Host>'` auf die Quelladresse (Knoten-IP) anpassen. |
| Migrationsjob `Failed`: `CREATE command denied` | Rechte fehlen | `GRANT` aus [Eigene MariaDB](mariadb.md) nachholen. |
| Container „Rejected“, `secret not found` | Secret fehlt oder anderer Name | `docker secret ls`; Namen in `stack.yaml` und Prefix des Skripts abgleichen. |
| Container beendet sich mit Exit 64/66 | Variable und `_FILE` gleichzeitig gesetzt / Datei nicht lesbar | Nicht zusätzlich `DB_PASSWORD=` setzen; Secret im Dienst eingehängt? |
| Passkey-Anmeldung/Registrierung schlägt fehl („Origin“, „RP ID“) | `WEBAUTHN_ORIGIN`/`WEBAUTHN_RP_ID` weichen vom Browser-Host ab (www, Port, http); Proxy ändert Host | Browser-Adresse = `WEBAUTHN_ORIGIN`; RP-ID = Host ohne Schema. Nach Änderung neu ausrollen. Nach RP-ID-Wechsel sind alte Passkeys wertlos. |
| „Zu viele Anfragen“ (429) bei Anmeldung für alle | `TRUSTED_PROXY_CIDRS` fehlt oder falsches Netz: alle Clients teilen einen Zähler | Subnetz des Proxys eintragen ([Reverse Proxy und TLS](proxy.md#trusted-proxy-cidrs-bestimmen)); Proxy im Host-Modus veröffentlichen; Wartezeit abwarten (5 Minuten). |
| Rate-Limit trifft nur einen Nutzer | Zähler pro Konto (15 je 5 Minuten) | Warten oder anderen Zugang nutzen; kein Fehler. |
| Push kommt nicht an | VAPID-Schlüssel/-Subjekt ungültig (Log-Warnung `Web Push stays unavailable`); `GET /api/v1/push/config` meldet `available:false`; `PUSH_ALLOWED_HOSTS` blockiert den Dienst; ausgehende Verbindung gesperrt; Gerät hat nicht abonniert | Secret/Subjekt prüfen; Liste enthält den Push-Host des Geräts (FCM, Mozilla, Apple, WNS); Egress-Firewall; Abo in der PWA erneuern. |
| AASA liefert 404 | `APPLE_APP_IDS` leer oder Stack nicht neu ausgerollt | Setzen und ausrollen ([Deployment-Anleitung](../DEPLOYMENT.md), Abschnitt 11). |
| AASA liefert 301/302 oder HTML | Proxy leitet um oder fängt den Pfad ab | `/.well-known/` ohne Umleitung/Fallback durchreichen ([Reverse Proxy und TLS](proxy.md)). |
| Apples CDN findet die Datei nicht | Domain nicht öffentlich/zertifikat ungültig/Cache noch alt | [Deployment-Anleitung](../DEPLOYMENT.md), Abschnitt 11, Prüfbefehle; später erneut prüfen. |
| Upload bricht ab (413 oder Verbindungsabbruch) | Proxy-Limit oder -Zeitüberschreitung zu klein | `client_max_body_size 70m`, Timeouts ≥ 120 s ([Reverse Proxy und TLS](proxy.md)). |
| Datei-Upload scheitert / „Lokal“ nicht nutzbar | Der Stack hat keine Volumes; Speicherregel steht auf „Lokal“ | Im Admin-Bereich „alles → Datenbank“ (oder S3) wählen, Upload-Limit prüfen. |
| `/` liefert 404 statt PWA | Image ohne PWA gebaut (Build ohne `pwa-src`) | Image aus dem Docker-Workflow verwenden; `docker run --rm --entrypoint ls IMAGE /srv/pwa` muss `index.html` zeigen. |
| S3-Dateien unlesbar (503 `storage_unavailable`) | Falscher/neuer `STORAGE_SECRET_KEY` | Ursprünglichen Schlüssel als Secret wiederherstellen; sonst S3-Zugangsdaten im Admin-Bereich neu eintragen. |
| PWA lädt, aber API-Fehler/CORS/Cookie fehlt | `PUBLIC_BASE_URL` ohne `https` (Cookie nicht `Secure`) oder abweichender Host | Alle drei URLs auf die öffentliche HTTPS-Adresse setzen. |
| `bootstrap-admin` meldet Konflikt | Es existiert schon ein Konto | Weitere Personen per Einladung in der PWA; Verlust des Admin-Zugangs: Wiederherstellungsoptionen des Kontos nutzen. |
| MCP-Client verbindet nicht | Modul `mcp` gesperrt; `/.well-known/oauth-*` nicht durchgereicht; `PUBLIC_BASE_URL` falsch | [Reverse Proxy und TLS](proxy.md); `MODULES_DISABLED` prüfen; [MCP-Anbindung](../MCP.md). |

Weitere Hintergründe und Checklisten: [Deployment-Anleitung](../DEPLOYMENT.md), [Betrieb und Backup](../BETRIEB.md).

## E-Mail kommt nicht an

Öffne als Admin Verwaltung, E-Mail und wähle „Verbindung prüfen“. Der Schritt, der rot wird, zeigt die Ursache und was zu tun ist. Ohne Browser: `POST /api/v1/admin/mail/check` (Details im [API-Vertrag](../../contracts/openapi.yaml)).

| Symptom | Fehlgeschlagener Schritt | Abhilfe |
| --- | --- | --- |
| „Der Servername … ist unbekannt“ | Servername auflösen | `SMTP_HOST` prüfen; im Docker-Netz muss ein Dienstname im selben Netzwerk liegen wie Timetrack. |
| „Der Server nimmt auf Port … keine Verbindungen an“ | Verbindung aufbauen | `SMTP_PORT` prüfen, läuft der Mailserver? |
| „Der Server antwortet nicht“ (Zeitüberschreitung) | Verbindung aufbauen / Verschlüsselung | Firewall blockiert ausgehend (Port 25 sperren viele Anbieter, nimm 587 oder 465) oder falscher Modus: 465 braucht `SMTP_TLS=implicit`, 587 `starttls`. |
| „Der Server bietet STARTTLS nicht an“ | Verschlüsselung | Anderen Port wählen (587) oder bei 465 `SMTP_TLS=implicit`. Timetrack sendet nie unverschlüsselt (außer `off` für Loopback-Tests). |
| „Zertifikat … abgelaufen“ | Verschlüsselung | Zertifikat beim Mailanbieter erneuern lassen. |
| „Zertifikat gilt für …, aber SMTP_HOST ist …“ | Verschlüsselung | `SMTP_HOST` auf genau den Namen setzen, für den das Zertifikat gilt (keine IP-Adresse). |
| „Dem Zertifikat … wird nicht vertraut“ | Verschlüsselung | Zertifikat einer öffentlichen Zertifizierungsstelle verwenden; selbst signierte Zertifikate werden nicht akzeptiert. |
| „Die Anmeldung wurde abgelehnt“ | Anmeldung | `SMTP_USER`/`SMTP_PASSWORD(_FILE)` prüfen; viele Anbieter verlangen ein App-Passwort. |
| „Der Server verlangt eine Anmeldung“ / „lehnt die Absenderadresse ab“ | Absender prüfen | `SMTP_USER` und `SMTP_PASSWORD` setzen; `SMTP_FROM` muss zum Konto gehören oder beim Anbieter freigegeben sein. |
| Prüfung grün, Mail landet im Spam | – | SPF, DKIM und DMARC der Absenderdomain beim Anbieter einrichten; Absenderdomain sollte zu `PUBLIC_BASE_URL` passen. |
| Testmail: „Relay verweigert“ / „nimmt die Empfängeradresse nicht an“ | (Testmail) | Der Mailserver leitet nur für angemeldete Konten oder eigene Domains weiter: Anmeldung einrichten. |

## „Zu viele Versuche. Bitte warte einen Moment."

Das ist ein HTTP 429. Es kommt entweder vom **Backend** (nur bei Anmelde-, Registrierungs- und Wiederherstellungsaufrufen; im Log steht eine Warnung `rate limit …`, und ohne `TRUSTED_PROXY_CIDRS` teilen sich alle Clients hinter dem Proxy einen Zähler) oder vom **Reverse Proxy** (zu niedrige Ratenbegrenzung, siehe [Reverse Proxy](proxy.md)). Prüfe zuerst das Backend-Log: Ohne `rate limit`-Zeile ist es der Proxy.

## Was ich bei einem Fehlerbericht mitschicke

In der PWA unter **Hilfe** steht der Abschnitt „Version und Build“. Der Knopf **Angaben kopieren** erzeugt eine Zeile wie `Timetrack PWA 0.1.0 (abc1234, 2026-10-18), Backend 0.1.0 (def5678, 2026-10-18), API 0.19.0, mariadb`; sie gehört in jede Fehlermeldung. Ohne Anmeldung zeigt `curl https://<deine-domain>/health` Version und Git-Revision des Backends.

- „Image-ID“ ist der Git-Commit, aus dem das Image gebaut wurde. Den genauen Image-Digest (`sha256:…`) kennt nur der Betreiber: `docker service inspect timetrack_backend --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'` (bei einem Tag ohne Digest zusätzlich `docker image inspect <image> --format '{{index .RepoDigests 0}}'`).
- Zwei Replikate: das Feld „Replikat“ (Hostname) zeigt, welches geantwortet hat.
- Meldet die Hilfe „Die geladene Oberfläche ist älter als die auf dem Server“, genügt **Neu laden / Aktualisieren**; danach stimmen beide Revisionen überein.
