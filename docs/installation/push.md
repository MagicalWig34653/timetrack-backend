# Push-Benachrichtigungen einrichten

- **Wofür:** Erinnerungen und Hinweise (zum Beispiel „Timer läuft noch“) auch dann erhalten, wenn die App oder die Web-App nicht geöffnet ist.
- **Voraussetzungen:** laufender Stack ([Compose](compose.md) oder [Swarm](swarm.md)) hinter HTTPS ([Reverse Proxy](proxy.md)), ein Administratorzugang zum Server. Für die Apple-Apps zusätzlich ein Apple-Developer-Konto.
- **Dauer:** Web-Push 5 Minuten, Apple-Push etwa 30 Minuten.

Timetrack kennt zwei getrennte Wege. Beide sind **optional**; ohne sie funktioniert alles andere unverändert, es gibt nur keine Benachrichtigungen von außen.

| Weg | Für wen | Dienst | Was du brauchst |
| --- | --- | --- | --- |
| **Web-Push** | PWA im Browser oder auf dem Homescreen | Push-Dienst des Browsers (FCM, Mozilla, Apple, WNS) | `VAPID_SUBJECT` und den VAPID-Schlüssel (legen `init-secrets.sh` bzw. `create-secrets.sh` an) |
| **APNs** | iPhone, iPad, Mac (native Apps) | Apple Push Notification service | `.p8`-Schlüssel aus dem Apple-Developer-Konto, Key-ID, Team-ID, Bundle-ID |

Der Text der Mitteilung ist bewusst allgemein („Timer läuft noch“, „Öffne Timetrack für Details.“). Zeiten, Orte, Notizen oder Namen stehen nie auf dem Sperrbildschirm; die App lädt die Details selbst.

## Teil 1: Web-Push (PWA)

1. **Kontakt festlegen.** In `.env` `VAPID_SUBJECT` setzen, zum Beispiel `mailto:admin@example.org` oder `https://timetrack.example.org`. Ohne gültigen Wert bleibt Push aus (Warnung im Log).
2. **Schlüssel.** Der VAPID-Schlüssel entsteht beim Anlegen der Secrets (`init-secrets.sh` bei Compose, `create-secrets.sh` bei Swarm). Du setzt ihn nicht von Hand. Sichere ihn im Passwortmanager: Geht er verloren, müssen alle Geräte neu abonnieren.
3. **Stack neu starten** (Compose: `docker compose up -d`, Swarm: `update.sh`).
4. **Prüfen.** Angemeldet `GET /api/v1/push/config` aufrufen: `available` muss `true` sein.
5. **Im Browser abonnieren.** In der Web-App unter *Einstellungen › Benachrichtigungen* Push einschalten und die Browserabfrage bestätigen. Auf iPhone und iPad funktioniert das nur, wenn die Web-App zuvor zum Homescreen hinzugefügt wurde.

Der Server sendet nur an erlaubte Push-Dienste. Sperrt deine Firewall ausgehende Verbindungen oder hast du `PUSH_ALLOWED_HOSTS` gesetzt, muss der Push-Host des Geräts auf der Liste stehen ([Konfiguration](konfiguration.md)).

## Teil 2: Push für die Apple-Apps (APNs)

Der Betrieb ohne APNs ist der Normalfall. Die Apps funktionieren ohne Push vollständig; Erinnerungen kommen dann nur lokal vom Gerät.

### 2.1 Schlüssel bei Apple erzeugen

1. Im [Apple-Developer-Konto](https://developer.apple.com/account) unter *Certificates, Identifiers & Profiles › Keys* einen neuen Schlüssel anlegen und **Apple Push Notifications service (APNs)** ankreuzen.
2. Die `.p8`-Datei herunterladen. **Apple zeigt sie nur einmal.** Sofort im Passwortmanager sichern.
3. Die **Key-ID** (10 Zeichen) notieren. Die **Team-ID** (10 Zeichen) steht oben rechts unter *Membership*.
4. Unter *Identifiers* die App-ID der App öffnen und die Capability **Push Notifications** aktivieren. Bei automatischer Signierung in Xcode erledigt das Xcode; für das Release-Archiv muss die Capability für die App-ID vorhanden sein.
5. Die **Bundle-ID** der App notieren. Mit mehreren (zum Beispiel iOS und Mac) kommagetrennt.

Die `.p8`-Datei gehört **nie** in ein Repository, eine Chatnachricht oder ein Ticket.

### 2.2 Server einrichten

Der Server braucht vier Werte: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_IDS` und den Schlüssel selbst. Sind nicht alle vier gesetzt oder ist einer ungültig, bleibt APNs aus.

**Swarm (empfohlen):**

1. Secret anlegen, zuerst als Probelauf:

   ```bash
   cd deploy/swarm
   ./create-secrets.sh --dry-run --apns-private-key-file /pfad/AuthKey_ABCDE12345.p8
   ./create-secrets.sh --apns-private-key-file /pfad/AuthKey_ABCDE12345.p8
   ```

   Das Skript prüft ohne Ausgabe, dass die Datei ein unverschlüsselter EC-P-256-Schlüssel im PEM-Format ist, übergibt ihn nur über stdin und überschreibt nie ein vorhandenes Secret. Danach die Datei aus dem Arbeitsverzeichnis löschen.
2. In `stack.yaml` den auskommentierten Block „APNs push“ einkommentieren, dazu `- tt_apns_private_key` unter `secrets:` des Backends und `tt_apns_private_key:` im Top-Level-`secrets:` (wie bei SMTP und OIDC).
3. In `.env` eintragen:

   ```
   APNS_KEY_ID=ABCDE12345
   APNS_TEAM_ID=ABCDE12345
   APNS_BUNDLE_IDS=com.example.timetrack
   ```

   Verwende deine echten Werte; die hier gezeigten sind Platzhalter.
4. Stack neu ausrollen (`update.sh`).

**Compose:** Die Compose-Variante ist für APNs noch nicht vorbereitet. Setze `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_IDS` in `.env` und mounte die `.p8`-Datei read-only in den Container, dann `APNS_PRIVATE_KEY_FILE=/pfad/im/container` setzen (alternativ den PEM-Text in `APNS_PRIVATE_KEY`).

### 2.3 Prüfen

1. Angemeldet `GET /api/v1/push/config` aufrufen: `apnsAvailable` muss `true` sein. Bei `false` stehen im Backend-Log Hinweise zu fehlenden oder ungültigen Werten.
2. In der App *Mehr › Erinnerungen › Push-Benachrichtigungen* öffnen (am Mac der Tab „Push“), **Push einschalten** wählen und die Systemabfrage bestätigen. Der Status muss „Registriert“ zeigen.
3. **Test senden** wählen. Nach wenigen Sekunden erscheint eine Testmitteilung.

Steht dort „Vom Server nicht angeboten“, ist APNs auf dem Server nicht aktiv (Schritt 1).

### 2.4 Was der Server sendet

- **Erinnerungen und Hinweise** der bestehenden Benachrichtigungsarten, mit denselben Kategorie-Schaltern, Ruhezeiten und Modulschaltern wie bei Web-Push.
- **Stille Abgleichs-Nachricht:** Ändert ein Gerät Daten, bekommen die anderen Geräte desselben Kontos eine stille Nachricht und laden Heute, Zeitliste, Planung und Kalender neu. Zusammengefasst auf höchstens eine Nachricht je Konto und 30 Sekunden (Apple drosselt stille Nachrichten).
- Je Konto sind höchstens 10 Geräte möglich.

## Datenschutz und Sicherheit

- Das Gerätetoken liegt im Klartext in der Datenbank, weil Apple es bei jeder Zustellung braucht. Es wird weder ausgeliefert noch geloggt. Begründung: [ADR-0030](../decisions/ADR-0030-apns-push.md).
- Die Geräteverwaltung läuft nur mit angemeldeter Sitzung. Persönliche Zugangstoken und MCP können keine Geräte registrieren.
- Beim Abmelden entfernt die App das Gerät vom Server. Ist es dann nicht erreichbar, räumt der Server das Gerät auf, sobald Apple es als ungültig meldet.
- Wechselst du den `.p8`-Schlüssel, lege ein **neues** Secret mit anderem Namen an (vorhandene werden nie überschrieben) und aktualisiere `stack.yaml`; der alte Schlüssel kann danach bei Apple widerrufen werden.

## Probleme

| Symptom | Wahrscheinliche Ursache | Abhilfe |
| --- | --- | --- |
| `apnsAvailable` ist `false` | einer der vier Werte fehlt oder ist ungültig; Secret nicht eingebunden | Backend-Log lesen; Block in `stack.yaml` und beide `secrets:`-Einträge prüfen; `.env` neu einlesen und Stack neu ausrollen |
| App zeigt „Vom Server nicht angeboten“ | Server hat APNs nicht aktiviert | Teil 2.2 abschließen |
| Registrierung schlägt mit „Zu viele Geräte“ fehl | mehr als 10 Geräte im Konto | alte Geräte in der App unter Push entfernen |
| App-Bundle-ID wird abgelehnt | `APNS_BUNDLE_IDS` enthält die Bundle-ID der App nicht | Wert ergänzen, Stack neu ausrollen |
| Registriert, aber keine Mitteilung | Capability *Push Notifications* fehlt für die App-ID; falsche Umgebung (Entwicklungs-Build gegen Produktion) | Capability aktivieren, App neu bauen; Debug-Builds nutzen die Sandbox, TestFlight und App Store die Produktion |
| Zuvor funktionierende Geräte bekommen nichts mehr | Gerät hat die App gelöscht oder Mitteilungen widerrufen (Apple meldet 410) | Server entfernt das Gerät selbst; in der App erneut einschalten |
| Web-Push kommt nicht an | `VAPID_SUBJECT` fehlt, Push-Host gesperrt oder Abo veraltet | Teil 1 und [Probleme und Lösungen](probleme.md) |

## Stand der Prüfung

Eine echte Zustellung über Apples Dienst ist mit einem Testgerät und deinem eigenen Schlüssel zu prüfen. Das Projekt kann das nicht stellvertretend tun; die Tests laufen gegen einen Testersatz für APNs.
