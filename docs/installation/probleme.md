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
