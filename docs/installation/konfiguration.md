# Konfigurationsreferenz

- **Wofür:** Alle Umgebungsvariablen von Timetrack an einer Stelle: Pflicht oder optional, Standardwert, Bedeutung.
- **Voraussetzungen:** keine; die Werte setzt du in `.env` (Compose) bzw. `.env` (Swarm).
- **Dauer:** zum Nachschlagen.

**Grundregel: leer ist ungesetzt.** Eine leere (oder nur aus Leerzeichen bestehende) Variable verhält sich exakt wie eine nicht gesetzte; sie löst nie einen Start- oder Parse-Fehler aus (`SMTP_PORT=""` gilt als `587`). Ausnahme: `DB_PASSWORD` darf bei MariaDB leer sein. Ebenso zählt der Inhalt `TIMETRACK_PLACEHOLDER_UNSET` (Platzhalter-Secret, siehe [Deployment](../DEPLOYMENT.md), Abschnitt 4) als nicht gesetzt. Deshalb reicht `stack.yaml` **alle** Variablen immer durch, und das Backend entscheidet selbst, was läuft (Entscheidungsmatrix unten).

Ungültige Werte verhindern den Start; der Fehler nennt die Variable (z. B. `Invalid configuration for WEBAUTHN_RP_ID: must be a lowercase hostname`). Die Vorlagen [`deploy/compose/.env.example`](https://github.com/MagicalWig34653/timetrack-backend/blob/main/deploy/compose/.env.example) und [`deploy/swarm/.env.example`](https://github.com/MagicalWig34653/timetrack-backend/blob/main/deploy/swarm/.env.example) enthalten die wichtigsten davon mit Beispielwerten. „Standard“ ist der Wert im Code; die mitgelieferten Dateien setzen teils eigene Werte (angegeben).

## Funktionsschalter und Entscheidungsmatrix

Jede optionale Funktion hat einen Schalter `<FUNKTION>_ENABLED` mit den Werten `true`, `false`, `auto` oder leer (Groß-/Kleinschreibung egal; anderes ist ein Startfehler). Ohne Schalter verhalten sich bestehende Installationen wie vorher.

| Funktion | Schalter | Pflichtwerte für „an“ | leer / `auto` | `false` | `true` |
| --- | --- | --- | --- | --- | --- |
| E-Mail (SMTP) | `SMTP_ENABLED` | `SMTP_HOST`, `SMTP_FROM` (mit `SMTP_USER` zusammen das Passwort) | an, wenn `SMTP_HOST` gesetzt; Host ohne Absender oder halbes Login = Startfehler | aus, übrige `SMTP_*` werden nicht geprüft | Startfehler, wenn `SMTP_HOST` fehlt |
| OpenID Connect | `OIDC_ENABLED` | `OIDC_ISSUER`, `OIDC_CLIENT_ID` (Secret optional) | an, wenn beide gesetzt; nur eines = Startfehler | aus | Startfehler, wenn eines fehlt |
| APNs (Apple-Push) | `APNS_ENABLED` | Schlüssel (Secret), `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_IDS` | an, wenn alle vier gültig; sonst aus, bei teilweise gesetzten Werten Warnung mit den Variablennamen | aus (Diagnose meldet „nicht eingerichtet“) | Startfehler mit den fehlenden/ungültigen Variablen |
| Web Push | `WEB_PUSH_ENABLED` | VAPID-Schlüssel (Secret), `VAPID_SUBJECT` | an, wenn beide gültig; teilweise gesetzt = Warnung | aus | Startfehler |
| Apple-App-IDs (AASA) | `APPLE_APP_IDS_ENABLED` | `APPLE_APP_IDS` | an, wenn die Liste nicht leer ist, sonst 404 | Endpunkt 404 | Startfehler bei leerer Liste |
| Erinnerungen | `NOTIFICATIONS_ENABLED` | – | an | Runner aus | an |
| Module | `MODULES_DISABLED` | – | alle an | – | – |
| Dateispeicher | im Admin-Bereich | Schlüssel `STORAGE_SECRET_KEY` nur für S3-Zugangsdaten | Datenbank-Speicher immer; S3/lokal über Regeln | – | – |

Fehlermeldungen nennen nur Variablennamen, nie Werte. Beim Start schreibt das Backend eine Übersicht ins Log, zum Beispiel:

```
feature overview (set <FEATURE>_ENABLED=true|false to force; empty = automatic; docs/installation/konfiguration.md)
feature SMTP: ON (host=smtp.example.test port=587 tls=starttls from=noreply@example.test authentication=user and password)
feature OIDC: off (OIDC_ISSUER and OIDC_CLIENT_ID are empty)
feature APNs: off (incomplete or invalid: APNS_PRIVATE_KEY)
feature Web Push: ON (VAPID key and subject set, subject=mailto:admin@example.test)
```

Geheimnisse (Passwörter, Schlüssel, Client-Secrets) erscheinen dort nie.

## Pflicht

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `TIMETRACK_IMAGE` | – | Nur Compose/Swarm-Datei: Image, z. B. `ghcr.io/magicalwig34653/timetrack-backend:0.1.0`. Für Produktion eine feste Version, nicht `latest`. |
| `DB_HOST` | `127.0.0.1` (Code); in Compose/Swarm Pflicht | Name des MariaDB-Servers. Bei `DB_TLS=required` muss er zum Zertifikat passen. Mitgelieferte Compose-Datenbank: `db`. |
| `PUBLIC_BASE_URL` | `http://localhost:18080` (Code); Pflicht in Compose/Swarm | Öffentliche Adresse. HTTPS (HTTP nur auf `localhost`), ohne Zugangsdaten, Pfad-Slash, Query, Fragment. Bestimmt Einladungslinks, OAuth-URLs und das `Secure`-Flag des Cookies. |
| `WEBAUTHN_RP_ID` | `localhost` (Code); Pflicht in Compose/Swarm | Passkey-Domain als Kleinbuchstaben-Hostname, ohne Schema, Port, Pfad. **Eine Änderung entwertet alle Passkeys.** |
| `WEBAUTHN_ORIGIN` | `http://localhost:18080` (Code); Pflicht in Compose/Swarm | Exakt die Adresse der Browserzeile (Schema und Host, kein Pfad). Der Host muss die RP-ID oder eine Subdomain davon sein. |
| `VAPID_SUBJECT` | – (in Compose/Swarm empfohlen) | Kontakt für Push-Dienste: `mailto:` oder `https://`. Ohne gültigen Wert bleibt Web Push aus (Warnung im Log). |
| `DB_PASSWORD` | – | Bei MariaDB ausdrücklich zu setzen. Im Container stattdessen `DB_PASSWORD_FILE` (Docker-Secret). |
| `STORAGE_SECRET_KEY` | – | Base64 von 32 Zufallsbytes; verschlüsselt gespeicherte S3-Zugangsdaten. Im Container `STORAGE_SECRET_KEY_FILE`. Verlust macht S3-Zugangsdaten unbrauchbar. |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_BUNDLE_IDS` | – | Optional: APNs-Push für die Apple-Apps (ADR-0030), alle vier nötig (siehe Matrix, `APNS_ENABLED`); Schlüssel als PEM-Text der `.p8`-Datei, im Container `APNS_PRIVATE_KEY_FILE`. Swarm und Compose: Variablen in `.env`, Schlüssel als Secret `tt_apns_private_key` ([Deployment-Anleitung](../DEPLOYMENT.md), Abschnitt 4). |
| `VAPID_PRIVATE_KEY` | – | P-256-Schlüssel (32 Byte, Base64url) für Web Push. Im Container `VAPID_PRIVATE_KEY_FILE`. |

`DB_PASSWORD`, `STORAGE_SECRET_KEY` und `VAPID_PRIVATE_KEY` erzeugen `init-secrets.sh` (Compose) und `create-secrets.sh` (Swarm); du setzt sie nicht von Hand.

## Datenbank

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `DATABASE_DRIVER` | `sqlite` (Code); `mariadb` in Compose/Swarm | `mariadb` oder `sqlite`. |
| `DB_PORT`, `DB_NAME`, `DB_USER` | `3306`, `timetrack`, `timetrack` | Verbindung zur MariaDB. |
| `DB_TLS` | `required` | `required`: TLS mit Prüfung des Serverzertifikats gegen die CA-Ablage des Images. `off` nur im vertrauenswürdigen Netz (z. B. mitgelieferte DB). Eine eigene CA lässt sich nicht angeben. |
| `DB_POOL_CONNECTIONS_PER_LOOP` | `1` (1 bis 8) | Verbindungen pro Event-Loop. Der Bedarf ist Kerne × Wert × Replikate; `max_connections` und `MAX_USER_CONNECTIONS` der Datenbank müssen reichen. Compose/Swarm reichen sie durch. |
| `DB_POOL_TIMEOUT_SECONDS` | `10` (1 bis 120) | Wartezeit auf eine freie Verbindung. Compose/Swarm reichen sie durch. |
| `DB_KEEPALIVE_SECONDS` | `45` (0 bis 3600) | Ping-Intervall gegen abgebrochene Leerlaufverbindungen; `0` = aus. |
| `SQLITE_PATH` | `timetrack.sqlite` | Dateipfad bei `sqlite`. Nur eine Instanz, nie zwischen Replikaten teilen. |
| `AUTO_MIGRATE` | `false` | `true` migriert beim Start. In Produktion `false`: Migration läuft als eigener Schritt ([Aktualisieren](../UPDATE.md)). |

## Netzwerk und Proxy

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `BIND_ADDR` | `127.0.0.1` | Nur Compose: Host-Adresse des veröffentlichten Ports. Standard `127.0.0.1` (Proxy auf demselben Server). Für einen Proxy auf einem anderen Server die private Adresse oder `0.0.0.0` setzen **und den Port per Firewall nur dem Proxy öffnen**. |
| `PUBLISHED_PORT` | `18080` | Veröffentlichter Port (Compose: auf dem Host; Swarm: auf jedem Knoten, Routing-Mesh). |
| `TRUSTED_PROXY_CIDRS` | leer (hinter einem Proxy **Pflicht**) | Kommagetrennte IP-Adressen oder CIDR-Netze der Reverse Proxys (z. B. `172.18.0.0/16`). Nur von dort wird `X-Forwarded-For` geglaubt. Leer: niemand. `/0` und ungültige Einträge verhindern den Start. [Reverse Proxy und TLS](proxy.md). |
| `PWA_CSP_MODE` | `enforce` | Notbremse für die CSP der PWA: `enforce`, `report-only` (nur Konsolenmeldungen) oder `off`; Standard bleibt streng (`docs/BETRIEB.md` Abschnitt 6 „Notbremse“) |
| `HSTS_MAX_AGE_SECONDS` | `15552000` (0 bis 63072000) | Dauer des `Strict-Transport-Security`-Headers in Sekunden; nur gesendet, wenn `PUBLIC_BASE_URL` mit `https://` beginnt. `0` schaltet ihn ab (z. B. wenn der Proxy ihn setzt). Ohne `includeSubDomains`. |
| `TRUSTED_PROXY_HEADER` | `X-Forwarded-For` | Oder `X-Real-IP`. Bei `X-Real-IP` **muss der Proxy den Header bei jeder Anfrage überschreiben** (nginx: `proxy_set_header X-Real-IP $remote_addr;`), sonst kann ein Client seine Adresse fälschen; das Backend warnt beim Start einmal. Im Zweifel `X-Forwarded-For`. [Details](proxy.md). |
| `APPLE_APP_IDS_ENABLED` | leer | `true`, `false` oder leer (automatisch). |
| `APPLE_APP_IDS` | leer | Kommagetrennt `<TeamID>.<BundleID>` (Team-ID 10 Zeichen). Leer: `/.well-known/apple-app-site-association` antwortet 404. Platzhalter: `ABCDE12345.com.example.timetrack`. |
| `PWA_STATIC_DIR` | `/srv/pwa` | Verzeichnis der Web-App im Image. Nur ändern, wenn du die Web-App getrennt bereitstellst. |

## Anmeldung und Sitzungen

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `WEBAUTHN_RP_NAME` | `Timetrack` | Anzeigename im Passkey-Dialog. |
| `SESSION_TTL_HOURS` | `720` (1 bis 8760); `336` in Compose/Swarm | Sitzungsdauer in Stunden. |
| `SESSION_IDLE_HOURS` | `336` (1 bis 8760) | Leerlauf-Timeout in Stunden: Sitzungen ohne Nutzung enden früher als `SESSION_TTL_HOURS`. |
| `OIDC_ENABLED` | leer | `true`, `false` oder leer (automatisch). |
| `OIDC_ISSUER`, `OIDC_CLIENT_ID` | aus | Optionales OpenID Connect; beide nur zusammen. Issuer per HTTPS. |
| `OIDC_CLIENT_SECRET` | – | Secret des Clients; im Container `OIDC_CLIENT_SECRET_FILE`. |
| `OIDC_NAME`, `OIDC_SCOPES` | `OpenID Connect`, `openid email profile` | Anzeigename (höchstens 80 Zeichen) und Scopes (müssen `openid` enthalten). |

## E-Mail (optional, für E-Mail-Codes)

Ohne `SMTP_HOST` ist E-Mail nicht verfügbar (Schalter `SMTP_ENABLED`, siehe Matrix). In den mitgelieferten Dateien stehen die Variablen leer in der `.env.example`.

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `SMTP_ENABLED` | leer | `true`, `false` oder leer (automatisch). |
| `SMTP_HOST` | – | Server. Aktiviert E-Mail. |
| `SMTP_PORT` | `587` | Port (1 bis 65535). |
| `SMTP_TLS` | `starttls` | `starttls`, `implicit` oder `off`. `off` nur für Loopback-Testhosts. |
| `SMTP_FROM`, `SMTP_FROM_NAME` | – (Absender Pflicht) | Absenderadresse und -name. |
| `SMTP_USER`, `SMTP_PASSWORD` | – | Zugangsdaten, nur gemeinsam. Im Container `SMTP_PASSWORD_FILE`. |

**Prüfen:** Als Admin unter Verwaltung, E-Mail (`/admin/mail`) siehst du die wirksamen Werte (ohne Zugangsdaten), kannst die Verbindung Schritt für Schritt prüfen (es wird keine Nachricht gesendet) und eine Testmail senden. Die Werte lassen sich dort nicht ändern; sie stehen nur in der Umgebung.

## Benachrichtigungen und Push

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `NOTIFICATIONS_ENABLED` | `true` | `false` schaltet den Erinnerungs-Runner ab. |
| `WEB_PUSH_ENABLED`, `APNS_ENABLED` | leer | `true`, `false` oder leer (automatisch), siehe Matrix. |
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
| `SECRET_DB_PASSWORD_NAME`, `SECRET_STORAGE_KEY_NAME`, `SECRET_VAPID_KEY_NAME`, `SECRET_SMTP_PASSWORD_NAME`, `SECRET_OIDC_CLIENT_SECRET_NAME`, `SECRET_APNS_KEY_NAME` | `tt_db_password`, `tt_storage_secret_key`, `tt_vapid_private_key`, `tt_smtp_password`, `tt_oidc_client_secret`, `tt_apns_private_key` | Namen der Docker-Secrets im Cluster. Nur zum Austauschen eines (unveränderlichen) Secrets, etwa Platzhalter durch echten Wert (`create-secrets.sh --name-suffix`). |

## Nicht per Variable

- **S3** und der **Dateispeicher** (Regel „Datenbank“, S3, lokal; Upload-Limit) werden im Admin-Bereich eingestellt; S3-Zugangsdaten liegen verschlüsselt in der Datenbank ([Ersteinrichtung](ersteinrichtung.md)).
- `*_FILE`-Variablen (`DB_PASSWORD_FILE` usw.) wertet der Einstiegspunkt des Images aus: Die Datei wird in die Variable ohne `_FILE` gelesen; beides gleichzeitig zu setzen ist ein Fehler (Exit-Code 64, nicht lesbare Datei 66).
- Entwicklung: weitere Variablen in der [Entwicklereinrichtung](../../EINRICHTUNG.md).
