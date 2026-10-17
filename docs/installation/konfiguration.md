# Konfigurationsreferenz

- **Wofür:** Alle Umgebungsvariablen von Timetrack an einer Stelle: Pflicht oder optional, Standardwert, Bedeutung.
- **Voraussetzungen:** keine; die Werte setzt du in `.env` (Compose) bzw. `stack.env` (Swarm).
- **Dauer:** zum Nachschlagen.

Ungültige Werte verhindern den Start; der Fehler nennt die Variable (z. B. `Invalid configuration for WEBAUTHN_RP_ID: must be a lowercase hostname`). Die Vorlagen [`deploy/compose/.env.example`](https://github.com/MagicalWig34653/timetrack-backend/blob/main/deploy/compose/.env.example) und [`deploy/swarm/stack.env.example`](https://github.com/MagicalWig34653/timetrack-backend/blob/main/deploy/swarm/stack.env.example) enthalten die wichtigsten davon mit Beispielwerten. „Standard“ ist der Wert im Code; die mitgelieferten Dateien setzen teils eigene Werte (angegeben).

## Pflicht

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `TIMETRACK_IMAGE` | – | Nur Compose/Swarm-Datei: Image, z. B. `ghcr.io/magicalwig34653/timetrack-backend:0.1.0`. Für Produktion eine feste Version, nicht `latest`. |
| `DB_HOST` | `127.0.0.1` (Code); in Compose/Swarm Pflicht | Name des MariaDB-Servers. Bei `DB_TLS=required` muss er zum Zertifikat passen. Mitgelieferte Compose-Datenbank: `db`. |
| `PUBLIC_BASE_URL` | `http://localhost:18080` (Code); Pflicht in Compose/Swarm | Öffentliche Adresse. HTTPS (HTTP nur auf `localhost`), ohne Zugangsdaten, Pfad-Slash, Query, Fragment. Bestimmt Einladungslinks, OAuth-URLs und das `Secure`-Flag des Cookies. |
| `WEBAUTHN_RP_ID` | `localhost` (Code); Pflicht in Compose/Swarm | Passkey-Domain als Kleinbuchstaben-Hostname, ohne Schema, Port, Pfad. **Eine Änderung entwertet alle Passkeys.** |
| `WEBAUTHN_ORIGIN` | `http://localhost:18080` (Code); Pflicht in Compose/Swarm | Exakt die Adresse der Browserzeile (Schema und Host, kein Pfad). Der Host muss die RP-ID oder eine Subdomain davon sein. |
| `VAPID_SUBJECT` | – (Pflicht in Compose/Swarm) | Kontakt für Push-Dienste: `mailto:` oder `https://`. Ohne gültigen Wert bleibt Push aus (Warnung im Log). |
| `DB_PASSWORD` | – | Bei MariaDB ausdrücklich zu setzen. Im Container stattdessen `DB_PASSWORD_FILE` (Docker-Secret). |
| `STORAGE_SECRET_KEY` | – | Base64 von 32 Zufallsbytes; verschlüsselt gespeicherte S3-Zugangsdaten. Im Container `STORAGE_SECRET_KEY_FILE`. Verlust macht S3-Zugangsdaten unbrauchbar. |
| `VAPID_PRIVATE_KEY` | – | P-256-Schlüssel (32 Byte, Base64url) für Web Push. Im Container `VAPID_PRIVATE_KEY_FILE`. |

`DB_PASSWORD`, `STORAGE_SECRET_KEY` und `VAPID_PRIVATE_KEY` erzeugen `init-secrets.sh` (Compose) und `create-secrets.sh` (Swarm); du setzt sie nicht von Hand.

## Datenbank

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `DATABASE_DRIVER` | `sqlite` (Code); `mariadb` in Compose/Swarm | `mariadb` oder `sqlite`. |
| `DB_PORT`, `DB_NAME`, `DB_USER` | `3306`, `timetrack`, `timetrack` | Verbindung zur MariaDB. |
| `DB_TLS` | `required` | `required`: TLS mit Prüfung des Serverzertifikats gegen die CA-Ablage des Images. `off` nur im vertrauenswürdigen Netz (z. B. mitgelieferte DB). Eine eigene CA lässt sich nicht angeben. |
| `DB_POOL_CONNECTIONS_PER_LOOP` | `1` (1 bis 8) | Verbindungen pro Event-Loop. Der Bedarf ist Kerne × Wert × Replikate; `max_connections` und `MAX_USER_CONNECTIONS` der Datenbank müssen reichen. Compose/Swarm reichen sie durch. |
| `DB_POOL_TIMEOUT_SECONDS` | `10` (1 bis 120) | Wartezeit auf eine freie Verbindung. Nicht in den mitgelieferten Dateien durchgereicht; bei Bedarf unter `environment` ergänzen. |
| `DB_KEEPALIVE_SECONDS` | `45` (0 bis 3600) | Ping-Intervall gegen abgebrochene Leerlaufverbindungen; `0` = aus. |
| `SQLITE_PATH` | `timetrack.sqlite` | Dateipfad bei `sqlite`. Nur eine Instanz, nie zwischen Replikaten teilen. |
| `AUTO_MIGRATE` | `false` | `true` migriert beim Start. In Produktion `false`: Migration läuft als eigener Schritt ([Aktualisieren](../UPDATE.md)). |

## Netzwerk und Proxy

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `BIND_ADDR` | `0.0.0.0` | Nur Compose: Host-Adresse des veröffentlichten Ports. `127.0.0.1`, wenn der Proxy auf demselben Server läuft. |
| `PUBLISHED_PORT` | `18080` | Veröffentlichter Port (Compose: auf dem Host; Swarm: auf jedem Knoten, Routing-Mesh). |
| `TRUSTED_PROXY_CIDRS` | leer | Kommagetrennte IP-Adressen oder CIDR-Netze der Reverse Proxys (z. B. `172.18.0.0/16`). Nur von dort wird `X-Forwarded-For` geglaubt. Leer: niemand. `/0` und ungültige Einträge verhindern den Start. [Reverse Proxy und TLS](proxy.md). |
| `TRUSTED_PROXY_HEADER` | `X-Forwarded-For` | Oder `X-Real-IP`. |
| `APPLE_APP_IDS` | leer | Kommagetrennt `<TeamID>.<BundleID>` (Team-ID 10 Zeichen). Leer: `/.well-known/apple-app-site-association` antwortet 404. Platzhalter: `ABCDE12345.com.example.timetrack`. |
| `PWA_STATIC_DIR` | `/srv/pwa` | Verzeichnis der Web-App im Image. Nur ändern, wenn du die Web-App getrennt bereitstellst. |

## Anmeldung und Sitzungen

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `WEBAUTHN_RP_NAME` | `Timetrack` | Anzeigename im Passkey-Dialog. |
| `SESSION_TTL_HOURS` | `720` (1 bis 8760); `336` in Compose/Swarm | Sitzungsdauer in Stunden. |
| `OIDC_ISSUER`, `OIDC_CLIENT_ID` | aus | Optionales OpenID Connect; beide nur zusammen. Issuer per HTTPS. |
| `OIDC_CLIENT_SECRET` | – | Secret des Clients; im Container `OIDC_CLIENT_SECRET_FILE`. |
| `OIDC_NAME`, `OIDC_SCOPES` | `OpenID Connect`, `openid email profile` | Anzeigename (höchstens 80 Zeichen) und Scopes (müssen `openid` enthalten). |

## E-Mail (optional, für E-Mail-Codes)

Ohne `SMTP_HOST` ist E-Mail nicht verfügbar. In den mitgelieferten Dateien sind die Zeilen auskommentiert.

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `SMTP_HOST` | – | Server. Aktiviert E-Mail. |
| `SMTP_PORT` | `587` | Port (1 bis 65535). |
| `SMTP_TLS` | `starttls` | `starttls`, `implicit` oder `off`. `off` nur für Loopback-Testhosts. |
| `SMTP_FROM`, `SMTP_FROM_NAME` | – (Absender Pflicht) | Absenderadresse und -name. |
| `SMTP_USER`, `SMTP_PASSWORD` | – | Zugangsdaten, nur gemeinsam. Im Container `SMTP_PASSWORD_FILE`. |

## Benachrichtigungen und Push

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `NOTIFICATIONS_ENABLED` | `true` | `false` schaltet den Erinnerungs-Runner ab. |
| `PUSH_ALLOWED_HOSTS` | eingebaute Liste | Kommagetrennt, **ersetzt** die eingebaute Liste erlaubter Push-Dienste. Vorschlag: `fcm.googleapis.com,updates.push.services.mozilla.com,web.push.apple.com,*.notify.windows.com`. `*.` erlaubt Subdomains, nicht die Hauptdomain. |

## Module und Wartung

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `MODULES_DISABLED` | leer | Betreibersperre, kommagetrennt aus `reports`, `planning`, `transfer`, `automation`, `mcp`. Unbekannte Namen verhindern den Start. |
| `LOG_TIMESTAMPS` | nein | `true` | UTC-Zeitstempel am Anfang jeder Logzeile (`false` = aus). |
| `MAINTENANCE_INTERVAL_MINUTES` | `60` (0 bis 10080) | Abstand des Aufräumjobs im Backend; `0` = aus. |
| `MCP_AUDIT_RETENTION_DAYS` | `90` (1 bis 3650) | Aufbewahrung des MCP-Protokolls in Tagen. |
| `IMPORT_JOB_TIMEOUT_HOURS` | `168` (1 bis 8760) | Offene, nicht abgeschlossene Importe werden danach verworfen. |
| `STORAGE_ORPHAN_GRACE_HOURS` | `168` (1 bis 8760) | Karenzzeit, bevor verwaiste Objekte im lokalen Speicher gelöscht werden. |

## Nur Swarm-Stack

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `BACKEND_REPLICAS` | `1` | Beim ersten Ausrollen `0`, nach der Migration hochskalieren ([Docker Swarm](swarm.md)). |
| `BACKEND_PLACEMENT` | `"node.platform.os == linux"` | Optionale Platzierungsbedingung, z. B. `"node.labels.timetrack == true"`. |

## Nicht per Variable

- **S3** und der **Dateispeicher** (Regel „Datenbank“, S3, lokal; Upload-Limit) werden im Admin-Bereich eingestellt; S3-Zugangsdaten liegen verschlüsselt in der Datenbank ([Ersteinrichtung](ersteinrichtung.md)).
- `*_FILE`-Variablen (`DB_PASSWORD_FILE` usw.) wertet der Einstiegspunkt des Images aus: Die Datei wird in die Variable ohne `_FILE` gelesen; beides gleichzeitig zu setzen ist ein Fehler (Exit-Code 64, nicht lesbare Datei 66).
- Entwicklung: weitere Variablen in der [Entwicklereinrichtung](../../EINRICHTUNG.md).
