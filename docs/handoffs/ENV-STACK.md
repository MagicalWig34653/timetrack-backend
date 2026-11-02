# ENV-STACK: Swarm-Stack komplett per `.env` (02.11.2026)

Branch `env-stack`. Betreiberwunsch: Der Stack soll alles per Umgebungsvariablen steuern, ohne `override.yaml`; das Backend entscheidet, welche optionalen Funktionen laufen. Keine Vertragsänderung.

## 1. Bestandsaufnahme (vorher)

| Funktion | Variablen | Aktivierung vorher | Verhalten bei leerem String |
| --- | --- | --- | --- |
| SMTP | `SMTP_HOST/PORT/TLS/FROM/FROM_NAME/USER`, `SMTP_PASSWORD(_FILE)` | `SMTP_HOST` nicht leer | `SMTP_PORT=""` und `SMTP_USER=""` mit Passwort: Startfehler |
| OIDC | `OIDC_ISSUER/CLIENT_ID/NAME/SCOPES`, `OIDC_CLIENT_SECRET(_FILE)` | beide Pflichtwerte gesetzt; nur eines = Fehler | leer tolerant (getrimmt) |
| APNs | `APNS_KEY_ID/TEAM_ID/BUNDLE_IDS`, `APNS_PRIVATE_KEY(_FILE)` | alle vier gültig; sonst Warnung, aus | tolerant |
| Web Push | `VAPID_PRIVATE_KEY(_FILE)`, `VAPID_SUBJECT`, `PUSH_ALLOWED_HOSTS` | Schlüssel und Subject gültig; sonst Warnung | tolerant |
| Apple-App-IDs | `APPLE_APP_IDS` | Liste nicht leer | tolerant |
| Dateispeicher | `STORAGE_SECRET_KEY(_FILE)`, `STORAGE_S3_ALLOWED_HOSTS`, `STORAGE_LOCAL_ROOT` | S3/lokal über Admin-Regeln, nicht per Variable | tolerant |
| Erinnerungen, Module, Wartung | `NOTIFICATIONS_ENABLED`, `MODULES_DISABLED`, `MAINTENANCE_*`, ... | Standardwerte | `DB_PORT=""`, `DB_HOST=""`, `SESSION_TTL_HOURS=""` u. a. Startfehler |
| MCP, Import | nur Modulschalter (`MODULES_DISABLED`), keine eigenen Variablen | | |

Die Stack-Datei hatte SMTP/OIDC/APNs als auskommentierte Blöcke (Secrets ebenfalls), `APNs` zusätzlich als Overlay-Beispiel.

## 2. Backend

- `EnvironmentSanitizer` (`Sources/TimetrackKit/FeatureSwitches.swift`): leere/Leerzeichen-Werte und der Platzhalterinhalt `TIMETRACK_PLACEHOLDER_UNSET` gelten als nicht gesetzt (`Configuration`, `MaintenanceOptions`, `NotificationOptions`, Speicher-Variablen). Ausnahme `DB_PASSWORD` (leer erlaubt).
- Schalter `SMTP_ENABLED`, `OIDC_ENABLED`, `APNS_ENABLED`, `WEB_PUSH_ENABLED`, `APPLE_APP_IDS_ENABLED`: `true`/`false`/`auto`/leer. `false` erzwingt aus (ohne Prüfung der übrigen Werte), `true` ohne vollständige Konfiguration ist ein Startfehler mit Variablennamen (nie Werten), leer = bisheriges Verhalten (Auto: an, wenn Pflichtwerte da; SMTP/OIDC halb gesetzt bleibt Fehler, APNs/VAPID bleibt Warnung). Ungültiger Schalterwert = Startfehler.
- Startübersicht im Log (`feature <Name>: ON|off (<Grund>)`, plus Files/Modules), `logFeatureOverview` in `Configure.swift`. Statuszeilen enthalten keine Geheimnisse (Test).
- `NotificationFeatures` (`Notifications/NotificationFeatures.swift`) bündelt die Entscheidung für APNs, Web Push und Runner; `installNotifications` ist jetzt `throws`.
- `scripts/docker-entrypoint.sh`: leere oder Platzhalter-Secretdatei lässt die Variable ungesetzt (Hinweis ohne Wert auf stderr).
- Klarere Fehlermeldungen: `SMTP_FROM` fehlt; `SMTP_USER` ohne Passwort (Hinweis auf Platzhalter).

## 3. Secrets im Swarm: Lösung und Bewertung

Problem: Ein im Stack referenziertes externes Secret muss existieren, sonst scheitert `docker stack deploy`; Docker-Secrets sind unveränderlich und dürfen nicht leer sein.

| Variante | Bewertung |
| --- | --- |
| **(a) Platzhalter-Secrets** (gewählt) | Stack referenziert immer alle sechs. `create-secrets.sh` legt jedes nicht echt angelegte optionale Secret mit dem Inhalt `TIMETRACK_PLACEHOLDER_UNSET` an; Entrypoint und Backend behandeln es als ungesetzt. Für den Betreiber ein Befehl (`--add-only`), idempotent, `--dry-run`, kein Klartext in Umgebung oder `docker service inspect`. Nachteil: drei Pseudo-Secrets im Cluster; Austausch Platzhalter gegen echten Wert braucht einen neuen Namen. |
| (b) Secret-Namen per Variable allein | Löst das Existenzproblem nicht (das Secret muss trotzdem da sein). Als Ergänzung übernommen: `SECRET_*_NAME` mit den bisherigen Namen als Vorgabe, damit der Austausch (Rotation, Platzhalter ersetzen) ohne Stack-Änderung geht; `create-secrets.sh --name-suffix _2` druckt die `.env`-Zeile. |
| (c) Docker-Configs / Dateien | Configs sind nicht für Geheimnisse gedacht (in `docker config inspect` lesbar); Dateien im Klon widersprechen dem Prinzip, dass nichts davon im Verzeichnis liegt. Verworfen. |
| (d) Ein Secret-Bündel | Ein einziges Secret mit allen Werten: Rotation einzelner Werte erzwingt neues Gesamtsecret, Mehrzeiler (PEM) im Bündelformat fehleranfällig, Entrypoint müsste parsen. Verworfen. |

Bestehende Deployments: `tt_smtp_password` und `tt_apns_private_key` existieren echt und bleiben unberührt (`--add-only` überschreibt nie); fehlt `tt_oidc_client_secret`, entsteht ein Platzhalter. Danach `docker stack deploy`; Verhalten unverändert, sobald dieselben Werte in der `.env` stehen.

## 4. Dateien

`deploy/swarm/stack.yaml` (alle Variablen durchgereicht, Zahlen/Schalter in Anführungszeichen, `${VAR:?}` nur bei `TIMETRACK_IMAGE`, `DB_HOST`, `PUBLIC_BASE_URL`, `WEBAUTHN_RP_ID`, `WEBAUTHN_ORIGIN`; `VAPID_SUBJECT` ist jetzt optional; Zahlen behalten ihre Standardwerte, damit ein älteres Image nicht an leeren Strings scheitert), `.env.example` (vollständig, je Funktion ein Abschnitt), `override.example.yaml` (nur Sonderfälle), `create-secrets.sh` (`--add-only` ohne Dateioptionen, `--no-placeholders`, `--name-suffix`), `update.sh` 2.2.0 (Hinweistext), `migrate-dir.sh` (Abschnitt „.env-Vorschlag“, lesend, ohne Geheimnisse), `deploy/compose/compose.yaml` + `.env.example` + `init-secrets.sh` (Platzhalterdateien), `docs/DEPLOYMENT.md`, `docs/UPDATE.md`, `docs/installation/*`. `scripts/sync-deploy-branch.sh` unverändert (Dateiliste deckt alles ab).

**Wichtig:** Die neue `stack.yaml` setzt ein Image mit diesem Stand voraus, wenn leere Werte (z. B. `SMTP_HOST=""`) durchgereicht werden sollen; ältere Images tolerieren die leeren SMTP/OIDC/APNs-Werte ebenfalls, die neuen Schalter ignorieren sie.

## 5. Tests

- Swift `FeatureSwitchTests` (7): leer == ungesetzt für alle Variablen, Platzhalter, Matrix je Funktion, unvollständig + true = Fehler, keine Geheimnisse in Statuszeilen und Fehlern; `ConfigurationTests` angepasst (leere Werte sind kein Fehler mehr).
- `scripts/test-update.sh` (54 Prüfungen): `.env`-Vorschlag, `create-secrets.sh` gegen Stub (Platzhalter, idempotent, dry-run, Suffix), Entrypoint, `docker stack config` (leer/minimal/gefüllt, umbenanntes Secret, Overlay).
- Vollständiger `swift test --build-system native -j 3` (Linux, swift:6.3-noble, SQLite) auf dem Stand vor dem Rebase: 539 Tests, 45 übersprungen, 0 Fehler. Nach Rebase auf 0.44.0 (73c7b01): ein Lauf mit 4 Fehlern (nicht ermittelt, nicht reproduzierbar; vermutlich zeitabhängig), der unmittelbar wiederholte Lauf: 543 Tests, 45 übersprungen, 0 Fehler. MariaDB-Lauf nicht nötig/nicht gemacht: die neuen Tests sind reine Umgebungs-Auswertungen ohne Datenbank.

## 6. Umstieg des Betreibers (Stack + override.yaml mit APNs und SMTP auf reine `.env`)

Siehe Kurzbericht der Sitzung und `docs/DEPLOYMENT.md`, Abschnitt „Bestehendes Verzeichnis auf den deploy-Branch umstellen“.

## 7. Offen

- Nicht auf einem echten Swarm ausgeführt (nur `docker stack config`, Stubs).
- Rechtsprofile, Vertrag: unverändert.
