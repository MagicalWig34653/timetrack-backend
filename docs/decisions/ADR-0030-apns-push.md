# ADR-0030: APNs-Push für die Apple-Apps (P14)

Status: umgesetzt im Branch `p14-apns`; Lead-Prüfung offen. Gegen den echten APNs-Dienst nicht geprüft.

## Entscheidung

Der Server stellt die bestehenden Benachrichtigungsarten (`running_timer`, `pending_suggestions`, `report_gap`, `document_submission`, `system`) zusätzlich an Apple-Geräte zu. Web Push (ADR-0010) bleibt unverändert; beide Wege laufen im selben Scheduler und unter derselben Sperre (`job_leases`).

- **Geräteregistrierung:** `GET/POST /api/v1/me/push-devices`, `DELETE /api/v1/me/push-devices/{id}`, `POST .../{id}/test`. Nur Sitzung und CSRF, wie die übrigen `/me`-Endpunkte; Bearer-Token (persönliche Tokens, Gerätetoken) erreichen sie nicht (`DeviceScopeGuard`), MCP bietet kein Werkzeug dafür. Wiederherstellungssitzungen sind ausgeschlossen. Eingabe `{token, platform ios|macos|watchos, environment sandbox|production, appBundleId, label?}`. Antworten enthalten den Token nie.
- **Token-Speicherung:** Klartext in `apns_devices.token` (APNs braucht ihn bei jeder Zustellung; Verschlüsselung würde einen zusätzlichen, betriebsrelevanten Schlüssel verlangen und nur gegen Lesezugriff auf die Datenbank schützen, die dann auch Sitzungsdaten sieht). Das entspricht der Konvention von `push_subscriptions.endpoint`. Eindeutigkeit über `token_hash` (SHA-256, base64url) global. Der Token ist ein widerrufbarer, an App und Gerät gebundener Bezeichner, kein Zugangsgeheimnis; er wird weder ausgeliefert noch geloggt (Schwärzung in `TriggerTokenScrubber`).
- **Kontotrennung:** Alle Abfragen filtern nach Konto; fremde Ids sind 404. Ein bereits bekannter Token wechselt bei Registrierung durch ein anderes Konto (gemeinsames Gerät, neue Anmeldung) auf dieses Konto, wartende Nachrichten des Vorbesitzers werden verworfen.
- **Grenzen:** höchstens 10 Geräte je Konto (409 `too_many_push_devices`), 30 Registrierungen und 5 Tests je Konto und Stunde (429, Tabelle `rate_limit_events`). `appBundleId` muss in `APNS_BUNDLE_IDS` stehen (verhindert Zustellung an fremde Topics).
- **Konfiguration:** `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY` (PEM-Text der `.p8`-Datei; im Container `APNS_PRIVATE_KEY_FILE`), `APNS_BUNDLE_IDS`. Fehlt etwas oder ist es ungültig, bleibt APNs aus (Warnung im Log, `GET /push/config` liefert `apnsAvailable:false`, Registrierung 501 `push_unavailable`); der Betrieb ohne APNs ist der Normalfall.
- **Client:** Protokoll `ApnsTransport` (Testdouble `FakeApnsTransport`) mit Implementierung `HTTP2ApnsTransport` auf Basis von AsyncHTTPClient (HTTP/2 per ALPN, bereits im Abhängigkeitsgraphen, keine neue Abhängigkeit). Hosts `api.push.apple.com` bzw. `api.sandbox.push.apple.com` nach dem `environment` des Geräts. Der bestehende `PushTransport` gehört zu Web Push; daher der andere Name.
- **Provider-Token:** ES256-JWT (`kid` = Key-Id, `iss` = Team-Id, `iat`), 50 Minuten wiederverwendet (Apple: nicht öfter als alle 20 Minuten, spätestens nach 60 Minuten erneuern); bei `ExpiredProviderToken` sofort verworfen und die Zustellung wiederholt.
- **Nutzlast:** Wie bei Web Push generischer Text je Art („Timer läuft noch“ / „Öffne Timetrack für Details.“), dazu `kind`, `url` (app-interner Pfad) und `notificationId`; keine Zeiten, Orte, Notizen oder Namen auf dem Sperrbildschirm, Details lädt die App. `thread-id` = Art, `apns-collapse-id` = 32-Zeichen-Hash des Dedup-Schlüssels, `apns-push-type: alert`, Priorität 10, Ablauf 24 Stunden. Stiller Push für den Abgleich: `{"aps":{"content-available":1},"kind":"sync"}` mit `apns-push-type: background`, Priorität 5, Collapse-Id `sync`.
- **Einstellungen:** Dieselben Kategorie-Schalter (`push`), Ruhezeiten, Moduleschalter und Kontosperre wie bei Web Push, geprüft beim Einreihen und erneut bei der Zustellung.
- **Zustellung:** Tabelle `apns_outbox` (je Benachrichtigung und Gerät eine Zeile; pending, deferred, sent, failed), drei Versuche mit Backoff 1 und 5 Minuten bei 429/5xx/Netzwerk; HTTP 410, 400 `BadDeviceToken` und `Unregistered` löschen das Gerät samt Warteschlange; andere Fehler werden mit bereinigtem Grund (`apns_<Reason>`) als fehlgeschlagen vermerkt. Aufbewahrung gesendeter und fehlgeschlagener Zeilen 14 Tage.

## Offen

- Der stille Push ist als Baustein (`ApnsDispatcher.sendSyncHint`) vorhanden, wird aber noch von keinem Ereignis ausgelöst; Auslöser (z. B. nach serverseitigen Änderungen anderer Geräte) und Drosselung (Apple begrenzt stille Pushes) sind mit den Apps abzustimmen.
- Verdrahtung des Schlüssels als Docker-/Swarm-Secret in `deploy/` (der Entrypoint übersetzt `APNS_PRIVATE_KEY_FILE` bereits).
- Echter Test gegen Sandbox und Produktion; der Aufruf der Apple-Hosts ist nur gegen einen Testdouble geprüft.
- Wartungsjob: Geräte ohne Erfolg über lange Zeit werden nur über die APNs-Antworten bereinigt (kein Zeitlimit wie bei Web Push).
