# Ersteinrichtung

- **Wofür:** Nach dem ersten Start den Admin anlegen, einen Passkey registrieren und die Instanz für dich und weitere Personen einrichten.
- **Voraussetzungen:** Timetrack läuft ([Docker Compose](compose.md) oder [Docker Swarm](swarm.md)) und ist über den Reverse Proxy per HTTPS erreichbar ([Reverse Proxy und TLS](proxy.md)).
- **Dauer:** 10 Minuten für die Schritte 1 bis 5; die übrigen sind optional und unabhängig voneinander.

Beispieldomain: `timetrack.example.org`. Jeder Schritt endet mit einer **Prüfen**-Zeile.

## 1. Läuft der Server?

```sh
curl -fsS https://timetrack.example.org/ready
```

Ohne Proxy direkt am Server: `curl -fsS http://127.0.0.1:18080/ready` (im Swarm auf einem Knoten, `PUBLISHED_PORT`). `/health` und `/ready` sollten **nicht** öffentlich über den Proxy erreichbar sein; teste von dort, wo es erlaubt ist.

**Prüfen:** Antwort mit Status 200 und `{"status":"ok"}`. Bei 503 ist die Migration nicht fertig oder die Datenbank nicht erreichbar: [Probleme und Lösungen](probleme.md).

## 2. Den ersten Admin anlegen

`bootstrap-admin` erzeugt **einen** Einladungslink für die Admin-Rolle (72 Stunden gültig, einmalig). Er funktioniert nur, solange noch kein Konto existiert. Behandle den Link wie ein Passwort: nicht in Tickets, Chats oder Logs ablegen und sofort im Browser öffnen.

Docker Compose (im Ordner mit `compose.yaml`):

```sh
docker compose run --rm --no-deps -T backend bootstrap-admin --env production
```

Docker Swarm (auf dem Knoten, auf dem das Backend läuft):

```sh
docker exec -it "$(docker ps -q -f name=timetrack_backend | head -n 1)" \
  /app/docker-entrypoint.sh bootstrap-admin --env production
```

::: warning docker exec ohne Einstiegspunkt scheitert
`docker exec … bootstrap-admin` ohne `/app/docker-entrypoint.sh` endet mit `executable file not found in $PATH`: `bootstrap-admin` ist ein Unterbefehl des Einstiegspunkts, keine Programmdatei. Der Einstiegspunkt liest auch die Docker-Secrets ein.
:::

Läuft das Backend nicht oder auf einem anderen Knoten, gibt es im Swarm eine Alternative über einen Einmal-Dienst: [Deployment-Anleitung](../DEPLOYMENT.md), Abschnitt 12.

**Prüfen:** Die Ausgabe enthält `https://timetrack.example.org/invite/…`. Stimmt der Host nicht, ist `PUBLIC_BASE_URL` falsch.

## 3. Einladungslink öffnen und Passkey anlegen

Öffne den Link auf dem Gerät, das du dauerhaft nutzt (Handy oder Computer). Du legst Kontoname, Anzeigename, optional eine E-Mail-Adresse und den **Passkey** an; das Gerät fragt nach Fingerabdruck, Gesicht, PIN oder Sicherheitsschlüssel. Danach erscheint „Wiederherstellung einrichten“. Richte **mindestens eine** Möglichkeit ein, sonst bist du ausgesperrt, wenn du alle Passkeys verlierst:

- **Recovery-Codes:** einmal verwendbare Codes. Sie werden einmal angezeigt; speichere sie im Passwortmanager oder drucke sie aus.
- **Rückfallpasswort:** ein langes Passwort, nur für den Notfall. Im Passwortmanager ablegen.
- **E-Mail-Codes:** ein Code per E-Mail an deine **Konto-E-Mail-Adresse** (es gibt keine getrennte Wiederherstellungs-Adresse). Setzt voraus, dass der Server E-Mail versenden kann (SMTP, siehe unten) und die Konto-Adresse bestätigt ist; ist sie es noch nicht, bestätigst du sie beim Einschalten mit einem Code. Ändert oder entfernst du die Konto-Adresse später, gilt die neue Adresse bzw. die E-Mail-Wiederherstellung wird abgeschaltet.

Lege später unter Einstellungen, Passkeys einen zweiten Passkey auf einem anderen Gerät an.

**Prüfen:** Du bist als Admin angemeldet, und Einstellungen zeigen Wiederherstellung und mindestens einen Passkey. Der Passkey hängt an `WEBAUTHN_RP_ID`. Schlägt die Anlage fehl, prüfe `WEBAUTHN_RP_ID` und `WEBAUTHN_ORIGIN` (Browseradresse ohne `www` und Port, `https`).

## 4. Geführte Einrichtung in der App

Neue Konten sehen auf der Startseite ein Banner zur Einrichtung. In sechs Schritten legst du fest: **Arbeitsmodell** (Soll pro Tag und Woche), **Pausen**, **Berufsschule**, **Urlaub** und **Funktionen** (welche Module du nutzt); die letzte Seite fasst alles zusammen. Die App zeigt Vorschläge sichtbar an, gespeichert wird erst am Ende. Du kannst die Einrichtung jederzeit unter Einstellungen, Profil wiederholen; Änderungen werden als neue Version gespeichert, die Historie bleibt erhalten.

**Prüfen:** Die Startseite zeigt dein Soll und deinen Zeitkonto-Stand; du kannst eine Zeit starten.

## Optional: Woche planen und Wochenübersicht

Unter „Woche“ siehst du die Wochenübersicht (Stunden, Saldo, Zeitkonto) und planst im Reiter „Planen“ grob, von wann bis wann du arbeitest (nur bei eingeschaltetem Modul Planung). Der Plan bucht keine Zeit. Beides braucht Backend ab Vertrag v0.17.0.

## 5. Weitere Personen einladen

Registrierung ist **nur per Einladung** möglich (auch bei OpenID Connect). Als Admin erstellst du unter Einladungen einen Link und gibst ihn der Person weiter. Jede Person bekommt ein eigenes, privates Konto; Planungen teilt sie nur gezielt. Konten verwaltest du unter Admin, Konten (deaktivieren, Rolle, Sitzungen beenden).

**Prüfen:** Die eingeladene Person kann den Link öffnen und einen Passkey anlegen; der Link ist danach verbraucht.

## 6. Dateispeicher einstellen

Dateien (Anhänge, Importe) liegen standardmäßig **in der Datenbank**. Prüfe unter Admin, Dateispeicher:

- Speicherregel „alles → Datenbank“ (Voreinstellung) oder S3. Die Art „Lokal“ gibt es nur, wenn du in Compose ein Volume eingebunden hast; im Swarm-Stack nicht.
- **Größter erlaubter Upload:** Voreinstellung 10 MiB, Höchstwert 64 MiB. Beispiel 50 MiB. Das ist eine Datenbankeinstellung, keine Umgebungsvariable.
- Bei Dateien in der Datenbank muss `max_allowed_packet` der MariaDB zum Limit passen (mindestens 56 MiB bei 50 MiB; 70 MiB deckt den Höchstwert ab, die mitgelieferte Datenbank setzt 70 MiB). Im Proxy `client_max_body_size` entsprechend (z. B. 70m). Siehe [Eigene MariaDB vorbereiten](mariadb.md).

**Prüfen:** Lade eine Testdatei hoch (z. B. an einer Abwesenheit) und öffne sie wieder.

## Optional: E-Mail, OpenID Connect, Push, Module

**E-Mail (SMTP).** Nötig für E-Mail-Codes und E-Mail-Änderung. Setze `SMTP_HOST`, `SMTP_PORT`, `SMTP_TLS`, `SMTP_FROM`, `SMTP_FROM_NAME` und optional `SMTP_USER` samt Secret `tt_smtp_password`. In Compose die auskommentierten SMTP-Zeilen in `compose.yaml` aktivieren (auch Secret anlegen: Datei `secrets/tt_smtp_password`); im Swarm den SMTP-Block in `stack.yaml` und in `.env`, Secret mit `create-secrets.sh --smtp-password-file`. Alle Werte: [Konfigurationsreferenz](konfiguration.md). **E-Mail prüfen:** Melde dich als Admin an und öffne in der Seitenleiste unter Verwaltung den Punkt „E-Mail“ (`/admin/mail`). „Verbindung prüfen“ zeigt Schritt für Schritt, ob der Server erreichbar ist, die Verschlüsselung und die Anmeldung klappen und der Absender akzeptiert wird; mit „Testmail senden“ kommt eine Nachricht an deine Adresse (dafür ist eine frische Anmeldung nötig). Danach: Unter Einstellungen, Profil eine Adresse eintragen; der Bestätigungscode kommt per E-Mail.

**OpenID Connect.** Optionale Anmeldung über einen vorhandenen Identitätsanbieter: `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_NAME`, `OIDC_SCOPES` und das Secret `tt_oidc_client_secret` (gleiche Technik wie bei SMTP). Die Registrierung bleibt auch dann einladungsbasiert. **Prüfen:** Die Anmeldeseite zeigt den konfigurierten Namen.

**Push-Benachrichtigungen (VAPID).** Die Schlüssel haben die Secret-Skripte bereits erzeugt; du brauchst `VAPID_SUBJECT` (`mailto:…`). Jedes Gerät abonniert selbst unter Einstellungen, Benachrichtigungen. Der Server muss die Push-Dienste der Hersteller erreichen können (ausgehend HTTPS). **Prüfen:** `https://timetrack.example.org/api/v1/push/config` meldet `available: true` (nach Anmeldung im Browser abrufbar).

**Module ein- und ausschalten.** Auf Serverebene sperrt `MODULES_DISABLED` (`reports`, `planning`, `transfer`, `automation`, `mcp`) Funktionen für alle; Admins schalten sie zusätzlich unter Admin, Module um. Auf Kontoebene entscheidet jede Person unter Einstellungen, Module. **Prüfen:** Ein gesperrtes Modul verschwindet aus der Navigation.

## 7. Apps installieren

- **Web-App (PWA):** Öffne `https://timetrack.example.org` im Browser und füge die App zum Home-Bildschirm hinzu (iOS/iPadOS: Teilen, „Zum Home-Bildschirm“; Chrome und Edge: Installieren-Symbol in der Adressleiste). Push auf iOS funktioniert nur aus der installierten App. Installation und Push sind noch nicht auf Echtgeräten geprüft.
- **iPhone, iPad, Mac, Apple Watch:** Die nativen Apps stehen im Repository [timetrack-apple](https://github.com/MagicalWig34653/timetrack-apple) und werden mit Xcode gebaut; ein TestFlight-Workflow existiert als ungetestetes Gerüst. Für Passkeys in den Apps muss der Server die Datei `/.well-known/apple-app-site-association` liefern: Setze `APPLE_APP_IDS` auf `<TeamID>.<BundleID>` (Platzhalter `ABCDE12345.com.example.timetrack`; eigene Team-ID aus dem Apple-Entwicklerkonto) und reiche die Datei im Proxy unverändert durch. Associated Domains brauchen das bezahlte Apple Developer Program. Prüfbefehle: [Deployment-Anleitung](../DEPLOYMENT.md), Abschnitt 11.

**Prüfen:** `curl -sS https://timetrack.example.org/.well-known/apple-app-site-association` liefert JSON mit deiner App-ID (bei leerem `APPLE_APP_IDS` 404).

## 8. Bestehende Zeittabelle importieren

Unter Import übernimmst du eine CSV- oder Excel-Datei. Die App erkennt die **Arbeitszeit-Tabelle** (Excel mit Jahresblättern und Wochenblöcken) und schlägt eine Vorlage vor; andere Dateien ordnest du Spalte für Spalte zu. Vor der Übernahme siehst du eine Vorschau, bis dahin wird nichts gespeichert. Ein Import lässt sich zurücknehmen; wurden Einträge danach geändert, meldet die App Konflikte. Hintergrund: [ADR-0013](../decisions/ADR-0013-arbeitszeit-tabelle.md).

**Prüfen:** Nach dem Import stimmt der Saldo der Vorschau mit deiner Tabelle überein.

## 9. ChatGPT oder Claude anbinden (MCP)

Der MCP-Endpunkt `https://timetrack.example.org/mcp` ist Teil des Servers. In ChatGPT oder Claude trägst du ihn als eigenen Connector ein und meldest dich per OAuth mit deinem Passkey an; für andere Clients gibt es persönliche Tokens. Der Proxy muss `/mcp` und `/.well-known/oauth-*` unverändert durchreichen. Die Anbindung ist noch nicht gegen echte Connectoren geprüft. Schritte, Scopes und Tools: [MCP-Anbindung](../MCP.md). Wer das nicht möchte, sperrt das Modul mit `MODULES_DISABLED=mcp`.

**Prüfen:** `curl -s -o /dev/null -w '%{http_code}\n' -X POST https://timetrack.example.org/mcp` antwortet 401 (ohne Token), nicht 404.

## Werte später prüfen und ändern

Unter Einstellungen, Arbeitsmodell, zeigt jede Version ihre Werte; „Bearbeiten“ ändert ab einem Datum (neue Version) oder korrigiert die Version selbst (mit Warnung und Vorschau auf das Zeitkonto). Auf der Seite Urlaub zeigt die Karte „Dein Urlaubskonto“ Anspruch, Übertrag und Bestand; fehlt der Anspruch, führt sie direkt zum Eintragen.

## Und danach

- [Sichern und Wiederherstellen](backup.md) einrichten, bevor Daten wichtig werden.
- Kurzbefehle für Orte und Automatik (iOS/macOS): [Anleitung im PWA-Repository](https://github.com/MagicalWig34653/timetrack-pwa/blob/main/docs/SHORTCUTS.md).
- Updates: [Aktualisieren und Migrationen](../UPDATE.md).
