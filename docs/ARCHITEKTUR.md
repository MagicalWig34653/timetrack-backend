# Technischer Entwurf

Entwurf Stand 13.10.2026, Entscheidungs- und Umsetzungsvermerke Stand 17.10.2026. Stack/Anforderungen bestätigt.
Die ursprünglich als „zu erproben“ markierten Komponenten sind entschieden (Verweise auf ADR 0003–0012); mit
**Umsetzungsstand** beginnende Absätze beschreiben den tatsächlichen Code, übrige Absätze sind weiterhin der Entwurf.
Nicht gebaut und weiter Vorschlag bleiben: Kalenderbrücke, KI-/Mac-Worker, Hintergrundworker als eigener Prozess, Swarm-Betrieb.
Geprüfter Stand: [STATUS.md](STATUS.md); Abhängigkeiten: [LIZENZEN.md](LIZENZEN.md).

## 1. Aufbau und Betrieb

Drei getrennte Repos, Backend als Hauptrepo. Pfade/Wissensverteilung: `REPOSITORIES.md`.

Swift/Vapor/Fluent; MariaDB empfohlen, SQLite für Einzelinstanzen; PostgreSQL entfällt.
Vorhandene MariaDB: 12.3.3-MariaDB-ubu2404. Linux Docker/Swarm auf amd64 und arm64;
Intel-/AMD-vServer und ein ARM-Host vorhanden. Reverse Proxy, Domains, TLS sind vorhanden.
Diese Infrastruktur nicht neu provisionieren. Authentik vorhanden, aber ausdrücklich nicht erforderlich.

Lokale Entwicklung auf einem ARM64-Mac mit Docker über Colima und Docker Compose.
Eigene lokale Entwicklungsdatenbank, keine Verwendung der vorhandenen Serverdatenbank für Tests.
Agent-Aufteilung: Claude Code koordiniert, ungefähr 50 % Implementierung durch Codex über das
Claude-Codex-Plugin. Einrichtung und überprüfter lokaler Stand siehe `../EINRICHTUNG.md`.

PWA Svelte/shadcn-svelte; vorgeschlagener Aufbau SvelteKit Static Adapter, TypeScript, Tailwind.
Node nur für Entwicklung/Build, statische Dateien im Produktions-Webcontainer.
Projekt AGPLv3; AGPL-3.0-only-Lizenztext vorhanden, Dependency-Lizenzen inventarisiert (`LIZENZEN.md`, offener Befund: eingebettetes BoringSSL in NIOSSL vor einem Release).

Vorschlag: modularer Monolith, versionierte REST/JSON-API mit OpenAPI-Vertrag.
MCP als zusätzlicher Adapter derselben Anwendungsdienste, keine zweite Geschäftslogik.
API/Hintergrundworker als getrennte Prozesse desselben Images möglich. DB-Jobs statt Pflicht-Redis.
MariaDB für mehrere API-Replikate. SQLite nur ein Backend auf persistentem Volume,
keine gemeinsam beschreibbare SQLite-Datei im Swarm. Migrationen einmalig koordiniert ausführen.

Umsetzungsstand: Das Backend ist ein modularer Monolith (Swift-Paket `TimetrackKit`, Einstieg `App`); REST unter `/api/v1`
nach `contracts/openapi.yaml` (v0.14.0), `/mcp` und `/oauth/*` als Adapter derselben Dienste. Der Erinnerungs-Scheduler läuft
im Prozess mit DB-Lease (`job_leases`, ADR-0010), kein eigener Worker-Prozess und kein Redis. Migrationen laufen derzeit über
`AUTO_MIGRATE=true` beim Start; für den Swarm-Betrieb gibt es einen einmaligen Migrationsjob mit `AUTO_MIGRATE=false` (`deploy/swarm/stack.yaml`, `BETRIEB.md`; Stack nicht real deployt). Die PWA wird vom
Backend statisch ausgeliefert (`PWA_STATIC_DIR`). Ein automatisierter Abgleich Implementierung ↔ OpenAPI-Vertrag fehlt (Backlog).

## 2. Passkeys, Einladungen und OIDC

Bestätigt: App-eigene Passkeys primär, mehrere pro Konto, optional OpenID Connect.
OAuth allein ist kein allgemeines Login-Protokoll; OIDC für externe Identität verwenden.
MCP-OAuth und KI-Anbieterzugang sind davon getrennte Rollen.

Vorgeschlagene Umsetzung:

- Passkeys registrieren, benennen, ergänzen und einzeln widerrufen.
- Geprüfte WebAuthn-Bibliothek; keine eigene Kryptografie. Challenge, Origin/RP-ID und User Verification prüfen.
  *Entschieden (ADR-0003, C2):* `swift-server/webauthn-swift` 1.0.0-beta.1 (Apache-2.0, Beta-Stand; im Lizenzinventar vermerkt).
- Nutzer wählt bei Einrichtung E-Mail-Codes, Rückfallpasswort oder Recovery-Codes.
  Passkeys bleiben primär; Kombination mehrerer Rückfallwege vorgeschlagen.
- E-Mail-Wiederherstellung nur mit verifizierter Adresse und funktionierendem Server-Mailversand.
  Kurzlebige Einmalcodes, begrenzte Versuche und Versandrate; keine Kontoexistenz verraten.
- Rückfallpasswort mit geprüfter speicherharter Passwort-Hashfunktion ablegen; keine Klartextspeicherung.
  *Entschieden (C2):* Argon2id über `Argon2Swift` (64 MiB, 3 Iterationen; die Bibliothek ist eine Branch-Abhängigkeit `main`, revisionsfixiert).
  Recovery-Codes einzeln gehasht speichern, atomar einmalig verbrauchen und erneuerbar machen.
- Wiederherstellung erzeugt einen begrenzten Ablauf zum erneuten Einrichten eines Passkeys;
  Sitzungswiderruf anbieten. Änderungen von Recovery-Ziel/Verfahren erneut authentisieren.
- Sichere HttpOnly-Browsercookies, CSRF-Schutz bei schreibenden Aktionen.
- OIDC Code Flow + PKCE, Identität über Issuer/Subject; Konten nicht allein per E-Mail automatisch verbinden.
  *Umgesetzt (ADR-0007, C14):* optional über `OIDC_ISSUER`/`OIDC_CLIENT_ID`, eigener schlanker Client mit id_token-Validierung;
  nur gegen Dex geprüft, nicht gegen Authentik o. Ä.
- Auch bei OIDC keine Neuregistrierung ohne Einladung; Kontenverknüpfung bewusst autorisieren.
- Zufällige Einladungen, Ablauf/Widerruf, standardmäßig einmalig; nur Tokenhash speichern.
- Einladungseinlösung und Kontoanlage atomar; Einladung gibt keinen Zugriff auf Daten des Einladenden.
- Ersten Admin über einmaligen lokalen Bootstrap statt offener Erstregistrierung anlegen.
- Administration und Datenfreigaben getrennt. Kein gewöhnlicher Admin-UI-Zugriff auf fremde Inhalte.
  Betreiber mit DB-/Backupzugriff werden dadurch nicht kryptografisch ausgeschlossen; E2EE nicht zugesagt.

Fachliche Objekte mit Eigentümer, Autorisierung immer serverseitig. Zufällige IDs ersetzen keine
Rechteprüfung. Freigaben explizit mit Empfänger/Umfang/Widerruf. Dies gilt auch für Downloads,
Exporte, Jobs, Push-Abos, Importe und MCP. Kein frei sichtbares Kontoverzeichnis voraussetzen.

## 3. MCP-Server mit OAuth und persönlichen Bearer-Tokens

Bestätigt: ChatGPT und Claude als OAuth-Zielclients; persönliche Bearer-Tokens für andere Clients.
Beide Wege verwenden dieselben Konto-, Scope- und Freigabeprüfungen.
OAuth-Zugriffstokens können ebenfalls als Bearer übertragen werden; der zusätzliche Weg meint
manuell erstellte persönliche Zugriffstokens ohne interaktiven OAuth-Flow.
Folgende technische Ausgestaltung ist vorgeschlagen:

Remote-MCP über Streamable HTTP, z. B. `/mcp`, im Backend oder als dünner Swift-Adapter.
Swift-SDK und stabile Protokollversion mit Zielclient erproben. Kein zusätzlicher Node-Produktionsdienst.
*Entschieden (ADR-0009, C17):* `POST /mcp` im Backend, eigener JSON-RPC-Handler ohne Swift-SDK, nur JSON-Antworten (kein SSE),
Protokollversionen 2025-11-25/2025-06-18/2025-03-26; keine Resources/Prompts. Erprobung mit echtem ChatGPT/Claude steht aus.
MCP als OAuth Resource Server, Code Flow mit PKCE, Resource-/Authorization-Server-Metadaten
für Discovery. Audience/Resource, Gültigkeit und Scopes prüfen; keine Provider-Tokenweitergabe.
Clientregistrierung passend zu Protokoll/Zielclient, öffentliche Clients ohne Client-Secret-Zwang.
Quelle: https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-11-25/basic/authorization.mdx

Consent nach Passkey-Login zeigt Client, Konto und Rechte; Grants anzeigen und widerrufen.
Einladungspflicht bleibt bestehen. Geeignete Authorization-Server-Komponente integrieren;
Bibliothekswahl früh prüfen. OIDC-Clientfähigkeit allein stellt noch keinen OAuth-Server bereit.
*Entschieden (ADR-0009, C16):* eigener Authorization Server im Backend (Dynamic Client Registration, PKCE S256 Pflicht,
Refresh-Rotation mit Wiederverwendungserkennung, opake Tokens mit gespeichertem SHA-256, Audience = MCP-Resource); keine
externe Komponente. Härtung durch ADR-0011.
Authentik darf optional anbinden, aber keine Voraussetzung sein.

Persönliche MCP-Tokens in den Kontoeinstellungen erstellen: Name, Scopes und Ablauf festlegen,
Token einmal anzeigen, nur Hash speichern, einzeln widerrufen und letzte Nutzung anzeigen.
Zufällige Tokens an Konto und MCP-Zweck binden; keine universellen Admin-/Server-Tokens.
Über `Authorization: Bearer <token>`, nicht über URLs übertragen. Keine Secrets in Logs.
Persönliche Tokens und OAuth-Grants getrennt verwalten; gleicher Zugriff auf dieselben Fachdienste.
Ein Token legt weder ein neues Konto an noch umgeht es eine widerrufene Planfreigabe.

| Scope (umgesetzt, ADR-0009; Tools siehe `MCP.md`) | Fähigkeiten |
| --- | --- |
| time:read | Buchungen, Tagesübersicht und Zeitkonto |
| time:write | Timer starten/stoppen, Zeitbuchung/Korrektur |
| schedule:read | eigener Plan und ausdrücklich freigegebene Planansichten |
| schedule:write | eigene Arbeits-/HO-Planung bearbeiten |
| reports:read | eigene Berichtshefte/Quellen lesen |
| reports:write | Entwurf anlegen/bearbeiten |
| documents:read | separat autorisierter Zugriff auf eigene Anhänge |

Keine fremden Schreibrechte aus Planfreigaben ableiten. Schreibaktionen verwenden REST-Fachregeln,
Idempotenz und Versionsprüfung. Für Überschreiben/Korrekturen Vorschau mit Änderungstoken vorsehen;
dies allein beweist keine menschliche Bestätigung. Falls erforderlich, Freigabe in eigener App.
Toolbeschreibungen/Read-only-Hinweise ersetzen keine Rechteprüfung. Dokumenttexte bleiben Daten,
auch wenn sie Anweisungen enthalten. Zielclients stehen fest; erster Toolumfang bleibt Vorschlag.
Freigegebene Ist-Zeiten/Urlaubsangaben über eine begrenzte Freigabeansicht ausliefern;
`schedule:read` darf dadurch keinen pauschalen Zugriff auf fremde Zeitkonten oder Dokumente erhalten.

Umsetzungsstand: MCP-Tools nach Scope (ADR-0009), Audit in `mcp_audit` ohne Parameter/Ergebnisse, persönliche Tokens (`ttp_…`,
nur für `/mcp`, Ablauf Pflicht), Grants widerrufbar, Rate-Limit 120 Anfragen je 5 Minuten. Der ursprüngliche „Vorschlag mit
Änderungstoken“ wurde durch `expectedVersion` und `clientEventId` ersetzt. Abschaltbar je Server/Konto über das
Modul `mcp` (ADR-0012, umgesetzt).

## 4. Datenmodell und Zeitbewertung

Fachliche Objekte: Nutzer, Passkey, Identität, Sitzung, Einladung, OAuth-Grant, persönliches MCP-Token,
Wiederherstellungsmethode/-Challenge/-Code;
Arbeitsverhältnis/Regelversion, Ort, Standortereignis, Arbeitsabschnitt, Pause, Bewertung,
Kontokorrektur, Plan, Abwesenheit, Urlaubskontobewegung, Dokument, Berichtsheft/Quelle,
Kalenderverbindung/-regel, Freigabe, Importcharge, Exportauftrag, Push-Abo und KI-Auftrag/Worker.

Zeitpunkte UTC plus fachliche Zeitzone, Ganztagsplanung als lokale Datumswerte.
Dauern als Ganzzahlen (z. B. Sekunden), keine Float-Stunden als maßgebliche Werte.
Regelversion/Rundungsherkunft speichern; heutige Profiländerung bewertet Vergangenheit nicht still neu.
Korrekturen versionieren, Rohereignisse erhalten. Wiedereröffnen (W2): `PATCH /time/segments/{id}` mit ausdrücklichem `endedAt: null` setzt nur den korrigierten Wert (Rohende bleibt), verlangt keinen laufenden Abschnitt und keinen späteren Abschnitt (409 `timer_already_running` / `segment_overlap`); die Revision trägt den Grund mit Präfix „Reopened: “. Gilt gleich für REST und MCP `correct_segment`. Mitternacht, Sommerzeit und Teilzeit berücksichtigen.

**X3 (Vertrag 0.29.0):** `needsReview` wird beim neu gesetzten oder geänderten Ende automatisch gelöscht; `PATCH /time/segments/{id}` mit `needsReview:false`, Grund und `If-Match` quittiert auch ohne Zeitänderung. Annahme und Ablehnung eines zugehörigen Ende-Vorschlags löschen die Markierung ebenfalls. Alle Änderungen am Segment nutzen denselben Revisionspfad (Vorher/Nachher, Grund, Version). Zeitkonto-Anpassungen haben `createdAt` (Bestandszeilen erhalten beim Migrationslauf denselben Migrationszeitpunkt) und sind über `GET /time/account/adjustments?limit&offset` nach `createdAt` und ID absteigend abrufbar. `DELETE /time/account/adjustments/{id}` entfernt nur eigene Anpassungen und liefert den neu berechneten Saldo. **Audit-Entscheidung:** `account_audit` speichert `time_adjustment.deleted` mit Konto-ID und Anpassungs-ID, ohne Grund, Betrag oder Datum; kein Grabstein mit Zeitkontowerten. Der bestehende Kontoexport umfasst aktive Anpassungen mit ID und `createdAt`, die bestehende Kontolöschung entfernt aktive Anpassungen; der datensparsame Audit-Eintrag folgt der bisherigen Aufbewahrung für Konto-Audits. MCP `list_time_adjustments` hat denselben lesenden Kontozugriff, aber kein Löschwerkzeug.

**Stornierte Abschnitte (W3, Vertrag 0.28.0):** Stornieren bleibt der Soft-Delete (`voidedAt`, Grund, Revision). Neu: Liste `GET /time/segments/cancelled` (seitenweise, Zeitraumfilter), Wiederherstellen `POST /time/segments/{id}/restore` (nur ohne Überschneidung mit nicht stornierten Abschnitten, 409 `segment_overlap`; ein stornierter laufender Timer nur ohne anderen laufenden, 409 `timer_already_running`; Revision „Restored: …“) und endgültiges Löschen (`DELETE …/{id}?permanent=true` bzw. Sammellöschung `DELETE /time/segments/cancelled` mit `from`/`to`/`ids`/`all=true`, Vorschau `dryRun=true`). Hartes Löschen ist nur für stornierte Abschnitte des eigenen Kontos möglich (409 `segment_not_cancelled`, 404 bei fremden). **Entscheidung:** kein Grabstein; mit dem Abschnitt werden seine Revisionen (Korrekturverlauf), Ende-Vorschläge und gespeicherte Timer-Ergebnisse vollständig gelöscht (Datensparsamkeit, Löschrecht); Automations-Ereignisse behalten ihren Idempotenzschlüssel, verlieren aber den Segmentbezug. Einzige Spur ist die Zusammenfassung der Antwort (Anzahlen). Der Datenexport enthält nur noch vorhandene Abschnitte. Segmente haben keine Anhänge (Anhänge hängen an Abwesenheiten). MCP bekommt nur `list_cancelled_segments` und `restore_segment`; endgültiges Löschen ist bewusst nicht über MCP/KI erreichbar.

**Statistikreihe (W3):** `GET /time/statistics?from&to&granularity=day|week|month&basis=evaluated|raw` (höchstens 1100 Tage) gruppiert die vorhandene Tagesbewertung; es gibt keine neue Bewertungslogik. Je Bucket: Soll (gesamt und bis heute), Ist, Gutschrift, Differenz, Über-/Unterzeit, kumuliertes Zeitkonto (immer der offizielle bewertete Stand wie `GET /time/account`), Zeit je Art (Arbeit/Schule/Fahrt), Abwesenheitstage, tatsächliche Pausen und abgezogene feste Pausen. `basis=raw` entfernt nur die Rundung von erstem Beginn/letztem Ende. Rechtsprofile bleiben unberührt.
Rechtshinweise anhand tatsächlicher Zeit und gewähltem Rechtsprofil, nicht gerundeter Bewertung.
Betriebliche Gutschriften nicht als gesetzliche Regeln bezeichnen.
Rundung nur an erstem Beginn/letztem Ende des fachlichen Arbeitstags; innere Pausen/Lücken exakt.
Summe der Arbeitsabschnitte plus äußere Rundungsdifferenzen, nicht pauschal Tagesrahmen minus
bekannte Pausen. Nachtschicht-Zuordnung und laufende, noch vorläufige Tagesbewertung spezifizieren.

Umsetzungsstand: spezifiziert in ADR-0004 (Nachtschicht = Tag des Beginns, laufender Tag `provisional`) und umgesetzt in
`TimeEngine` (reine Funktionen, ganzzahlige Sekunden). Tabellen und Fluent-Modelle über die Migrationen in `Migrations.swift`
und je Modul (`OAuthMigrations`, `OIDCMigrations`, `ImportSchema`/`StorageSchema`, `stage4a…`). Noch kein Datenmodell für
Kalenderverbindung und KI-Auftrag/Worker.

## 5. Shortcuts und Standort

Vorschlag `/api/v1/automation/events`: UUID, Gerät, Ereigniszeit, Orts-ID und Typ;
Empfangszeit serverseitig. Koordinaten optional, kein permanenter Bewegungsverlauf notwendig.
Gerätetokens einzeln widerrufbar und auf Automationsaktionen begrenzt, keine Passkeys im Shortcut.
Duplikate liefern bestehendes Ergebnis. Parallele/verspätete Ereignisse nicht doppelt buchen oder
korrigierte Zeiten überschreiben. Unklare Reihenfolgen markieren.
Ankunftskandidat, Aufenthaltsnachweis, Abbruch und Bestätigung getrennt modellieren.
Vorbeifahrt, fehlendes Verlassen, Netzverlust und verzögerte Zustellung mit realen Shortcuts testen.
PWA nicht als verlässlichen Hintergrund-Geofence planen; PWA-Offline-Sync ersetzt keinen Shortcut-Retry.

Umsetzungsstand: `POST /api/v1/automation/events` mit Gerätetoken (Scope `automation`) umgesetzt (ADR-0004, C6/C7);
Ereignistypen `arrival`, `presence_confirmed`, `departure`, `cancel`. Erprobung mit realen Shortcuts steht aus.

**W1 (ADR-0027)**: Ein `departure` beendet jeden laufenden Abschnitt, auch manuell gestartete (Modus `direct`: Ende = Ereigniszeit, `suggest`: Ende-Vorschlag, `off`: nur festgehalten); ein an einen anderen Ort gebundener Abschnitt bleibt, Vorbeifahrt bucht nichts, ohne laufenden Timer ist der Abgang ein harmloses `ignored`. Die Regeln liegen in `AutomationService` (`stopRunning`).

Entscheidungstabelle `departure` (laufender Abschnitt `R`, Besuch = letzte `arrival` dieses Geräts und Orts):

| Lage | Ergebnis |
|---|---|
| Kein Besuch (keine `arrival`) oder Besuch bereits beendet und `R` danach gestartet (Auslöse-Link, manuell, Timer-Endpunkt, Quelle egal), `R` ohne oder mit diesem Ort | `direct`: beendet `R` zur Ereigniszeit (rückdatiert); `suggest`: Ende-Vorschlag; `off`: nur festgehalten |
| Wie oben, `R` an anderen Ort gebunden | `ignored`, `R` läuft weiter |
| Wie oben, kein `R` | `ignored` |
| Offener Besuch, `R` aus Automation, aber nicht durch eine Bestätigung dieses Besuchs entstanden (z. B. Rest eines früheren Besuchs) | Ende-Vorschlag „fehlender Abgang“, `R` bleibt offen |
| Offener Besuch, bestätigt, `R` gehört zum Besuch | `direct`: Ende zur Ereigniszeit; `suggest`: Vorschlag wird auf die Ereigniszeit gesetzt/Ende-Vorschlag |
| Offener Besuch, nicht bestätigt (Vorbeifahrt) | `ignored`, es wird nichts gebucht |
| Besuch bereits beendet (doppelter `departure`) | `needs_review` |
| Zeit älter als das jüngste Ereignis oder Ereigniszeit nicht nach Start von `R` | `needs_review` |

Die Sonderbehandlung „Automation-Abschnitt ohne Bestätigung → nur Vorschlag“ gilt nur für einen wirklich offenen Besuch; ein per Auslöse-Link gestarteter Abschnitt (Quelle `automation`) wird wie ein manueller behandelt.

**Auslöse-Links (W1, ADR-0027)**: `GET /t/{token}/{start|stop|toggle}` ohne Sitzung für Werkzeuge, die nur einen einfachen GET senden können. Das Token (256 Bit, nur als SHA-256-Hash gespeichert, einmalig bei der Erstellung sichtbar) in der URL ist die einzige Berechtigung. Je Link: Bezeichnung, erlaubte Aktionen, optionaler Ort, Ablauf, Widerruf, „zuletzt benutzt“; Verwaltung per Sitzung unter `/api/v1/me/trigger-links` (Modul `automation`, nicht per MCP). Unbekannte, widerrufene und abgelaufene Token sowie nicht erlaubte Aktionen antworten ununterscheidbar mit 404; Ratenbegrenzung je Link und je Client; `Cache-Control: no-store`; Aktionen sind idempotent (Start bei laufendem Timer und Stopp ohne Timer ändern nichts, `toggle` mit 10-s-Wiederholungsschutz, HEAD und Prefetch lösen nichts aus); `?at=` höchstens 2 Stunden zurück. Es gelten dieselben Ortsmodi und Kontenrechte wie bei der Automation; Daten: Tabelle `trigger_links`, Kontoexport ohne Token, Löschung mit dem Konto.

*Sicherheitshinweis zu GET mit Geheimnis in der URL:* Die URL gelangt in Browserverlauf, Lesezeichen, Synchronisation, Protokolle von Proxys/Zielgeräten und Screenshots; jeder, der sie kennt, kann Zeiten beginnen und beenden (nicht lesen, ändern oder löschen). Daher: ein Link je Zweck mit nur den nötigen Aktionen (und wenn möglich Ort und Ablauf), den Link nicht teilen oder in Chats einfügen, bei Verdacht oder Gerätewechsel sofort widerrufen, Proxy-Zugriffsprotokolle für `/t/` schwärzen (`docs/installation/proxy.md`). Wo ein Header gesetzt werden kann, ist das Gerätetoken mit `POST /automation/events` vorzuziehen. Das Backend protokolliert keine Anfragepfade und schwärzt `/t/<token>` zusätzlich im Konsolenlog.

## 6. Dateispeicherung

Bestätigt: Admin wählt DB, S3 oder lokalen Pfad, auch abhängig von Dateigröße.
Beispiel: unter 5 MB in DB, ab Grenze S3/lokal. Schwelle/Einheit explizit konfigurierbar.
DB führt Fachobjekte und Metadaten; externe Dateien sind zusätzliche maßgebliche Nutzdaten.
Je Datei Backend, Schlüssel, Größe, Prüfsumme, Eigentümer speichern.
Regeländerung gilt zuerst nur für neue Uploads; Bestandsdateien behalten ihren Speicherort.
Migration als eigener prüfbarer Auftrag; kein stiller Speicher-Fallback.
Upload-/Löschzustände und Retries gegen inkonsistente DB/Objektzustände absichern.
Größenlimits, Dateitypen, Zugriffsschutz und Pfadvalidierung vorsehen.

Lokaler Pfad ist im Swarm nicht automatisch auf allen Hosts verfügbar: gemeinsames Volume
oder bewusste Platzierung mit dokumentierter Ausfallgrenze. SQLite entsprechend lokal binden.
Backup/Restore umfasst DB, externe Dateien und nötige Secrets/Schlüssel. Kein dauerhaftes Datum
nur im Container-Layer. Hintergrundjobs atomar übernehmen, Lease/Retry und Idempotenz verwenden.

Umsetzungsstand (ADR-0006, ADR-0011): Admin-Regeln (`/admin/storage`, geordnete Größenregeln → `db`/`s3`/`local`) umgesetzt; S3
über einen **eigenen SigV4-Client** (swift-crypto + AsyncHTTPClient, keine AWS-SDK-Abhängigkeit), nur gegen Adobe S3Mock und einen
In-Process-Fake geprüft; S3-Secret mit AES-256-GCM unter `STORAGE_SECRET_KEY`; Dateimetadaten (Backend, Schlüssel, Größe,
SHA-256, Eigentümer) in der DB; Original-Standorte werden gebunden (C19), Regeländerung gilt nur für neue Uploads. XLSX- und
PDF-Erzeugung per **eigener Writer** (OOXML über ZIPFoundation, PDF mit Helvetica/WinAnsi), Import liest XLSX mit Foundation-`XMLParser`.
**Offen**: Migration bestehender Dateien zwischen Backends, periodischer Speicher-Aufräumjob. Backup/Restore (DB + lokale Dateien +
Manifest; S3-Objekte und Secrets getrennt) ist in `BETRIEB.md` beschrieben und mit `scripts/test-restore.sh` auf SQLite und MariaDB belegt (B3).

## 7. Kalender, Push und KI

EventKit erlaubt nativen Kalenderzugriff mit Freigabe. Vorschlag: macOS/iOS synchronisieren nur
ausgewählte Kalender oder reduzierte Konfliktdaten. PWA erhält keinen direkten EventKit-Zugriff.
Google-Adapter später. Quelle:
https://developer.apple.com/documentation/eventkit/accessing-the-event-store

Web Push mit Nutzerfreigabe, unter iOS/iPadOS Home-Screen-Installation berücksichtigen.
Ohne Push bleiben In-App-Hinweise nutzbar; E-Mail optional.
*Umgesetzt (ADR-0010, C18/C19):* eigene Web-Push-Implementierung (RFC 8030/8291/8292, VAPID über swift-crypto, `aes128gcm`),
verifiziert gegen den RFC-8291-Beispielvektor; Zustellung nur gegen Fake-Dienst; Endpunkt-Allowlist gegen SSRF
(`PUSH_ALLOWED_HOSTS`). E-Mail als Hinweiskanal nicht vorhanden. Quelle:
https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers

KI-Zugang separat vom App-Login, pro Nutzer verknüpft/widerrufbar. OpenAI dokumentiert
ChatGPT-Plan-Nutzung ohne eigenen API-Key für geeignete Open-Source-Clients. Eine gemeinsame
gehostete PWA ist damit nicht automatisch abgedeckt: Deployment, OAuth und Verfügbarkeit vor Zusage erproben.
https://developers.openai.com/siwc/quickstart
https://developers.openai.com/siwc/token-sharing-open-source
https://developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms
https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations

Gleichwertiger Anthropic-Drittanbieterzugang über Nutzerabo hier nicht bestätigt.
Keine Claude-Code-Tokens auslesen oder als generellen API-Ersatz verwenden. Quelle:
https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account

Mac-Worker vorgeschlagen: mit eigenem Konto koppeln, ausgehend per HTTPS Jobs abholen,
keine öffentliche Portfreigabe. Eigene Quellen abrufen, OCR/Modell lokal ausführen, Entwurf zurückgeben.
Status wartend/in Arbeit/fertig/fehlgeschlagen; Lease/Retry, Idempotenz und Quellversion prüfen.
Keine zweite maßgebliche DB am Mac. Bei Schlaf/Offline/Modellfehler Auftrag sichtbar wartend/fehlerhaft,
kein stiller Cloud-Fallback. Verfügbarkeit hängt auch von Hardware/Modell/Einstellungen ab, nicht nur OS 27.
https://developer.apple.com/foundation-models-framework/

## 7a. Umsetzungsstand Clients, Betrieb und Veröffentlichung (17.10.2026)

- **Konten und Einstellungen:** Kontenverwaltung durch Admins, Selbstauskunft (`GET /me/export`) und Selbstlöschung (ADR-0016), Profil und geführte Einrichtung (ADR-0019), Darstellung (Akzent, Farbschema) je Konto über `GET/PATCH /me/preferences` (ADR-0020), abschaltbare Module (ADR-0012), Aufräumjob (ADR-0017), vertrauenswürdige Proxys für Client-Adressen (ADR-0018).
- **Native Apps** (Repo timetrack-apple, ADR-0015): Swift-Kern `TimetrackCore` spricht dieselbe REST-API wie die PWA (Sitzung/CSRF), `TimetrackDesign` setzt `DESIGN.md` nativ um; die Uhr erhält die Sitzung per WatchConnectivity vom iPhone; Widgets und Komplikation lesen einen nicht geheimen Snapshot über eine App Group. Das Backend liefert `/.well-known/apple-app-site-association` aus `APPLE_APP_IDS` (A2). Nicht geprüft auf Echtgeräten.
- **Betrieb:** Compose für Entwicklung; Swarm-Stack-Vorlage ohne DB-Container, Secrets per `*_FILE`, Migrationsjob, Backup/Restore-Skripte (B3, D2, `BETRIEB.md`, `DEPLOYMENT.md`); nie auf einem echten Swarm getestet.
- **CI und Website:** GitHub Actions je Repo (W1, `CI.md`): Build/Test, Multi-Arch-Image (amd64 nativ, arm64 nativ), Pages-Website aus `site/`, CodeQL, Dependabot, Release-Workflow (nie ausgeführt). Stand und bekannte Fehler: `STATUS.md`.
- **Lizenz und Veröffentlichung:** Alle drei Repos öffentlich unter AGPL-3.0-only; Release-Prüfung der Abhängigkeiten offen (`LIZENZEN.md`).

### Leistungsrichtlinie (X1)

- **Abfragebudget:** Ein lesender Endpunkt soll eine konstante Zahl von Statements brauchen (Zeitkonto über 800 Tage: 9, im Test `PerformanceTests` auf höchstens 12 begrenzt), nie eine je Tag oder je Segment. Berechnungen über viele Tage laufen über `TimeEvaluationSnapshot.prepared()` (`PreparedEvaluation`): Segmente einmal zugeordnet, Feiertage je Jahr einmal, Validierungen einmal. Das frühere Einzeltagsverfahren steht als Orakel im Test.
- **Fenster:** Bereichsendpunkte laden nur die Zeilen des Fensters (Segmente mit Rand von −3/+4 Tagen); nur das Zeitkonto lädt die gesamte Historie.
- **Indizes:** `work_models(account_id)`, `work_segments(account_id)` und `work_segments(account_id, started_at)`, `absences(account_id, start_date)`, `day_preferences(account_id, date)` (eindeutig). Neue Abfragen mit `EXPLAIN` auf MariaDB prüfen.
- **Kein blockierendes Rechnen im Request-Pfad** über Sekunden: es blockiert Event-Loop, Pool und `/ready` (Swarm-Healthcheck: 3 s). Lesende Routen laufen ohne `auth_lock`; schreibende Routen weiter damit (ADR-0017).
- **Verbindungen:** MariaDB-Pool mit Keep-Alive-Ping (45 s), `/ready` wiederholt einmal.

## 7b. E-Mail-Vorlagen (Paket M1-Mail)

Alle ausgehenden Mails laufen über `SMTPMailSender` und sind `multipart/alternative`: zuerst der unveränderte Klartext (Rückfallebene,
Quelle `Resources/RecoveryMail.de.json` bzw. `MailDiagnosis.body`), zuletzt der HTML-Teil (beide quoted-printable, UTF-8). Betreffzeilen bleiben unverändert.
Aktuell gibt es zwei Mails: den Bestätigungscode (E-Mail-Wiederherstellung, E-Mail-Änderung, Verifizierung; ein Code, zehn Minuten) und die
Testnachricht der Mail-Diagnose (ADR-0022). Einladungen, Magic-Links, Passwort-Reset, Benachrichtigungen und Berichtsmails werden heute **nicht** per Mail versendet
(Einladungen sind Links, die Admins weitergeben; Erinnerungen laufen per Web Push), daher gibt es dafür keine Vorlage.

`Sources/TimetrackKit/Mail/MailTemplates.swift` enthält das gemeinsame Layout: tabellenbasiert, nur Inline-CSS plus ein `<style>`-Block für Dunkelmodus
(`prefers-color-scheme`, `color-scheme`-Meta, `[data-ogsc]` für Outlook.com) und schmale Bildschirme; keine Bilder, Skripte, externen Dateien oder Tracking.
Bausteine (`MailBlock`): Absatz, Code-Block (Monospace, groß, markierbar), Button (mit Klartext-Link darunter), Fakten-Tabelle; dazu Kopf mit Produktname,
Sicherheitshinweis und Fußzeile. **Jeder** eingesetzte Wert wird mit `MailTemplates.escape` maskiert; Button-URLs müssen absolute http(s)-URLs sein (`safeURL`),
Links entstehen nur aus `PUBLIC_BASE_URL`.

Anpassen: Marke und Fußzeile kommen aus der Konfiguration (`MailBrand`): Produktname `WEBAUTHN_RP_NAME`, Betreibername `SMTP_FROM_NAME`, Instanz `PUBLIC_BASE_URL`. Texte der Code-Mail stehen
in `RecoveryMail.de.json` (`{code}` als Platzhalter); Farben in `MailTemplates.Palette`. Eine neue Mail: `MailDocument` mit Blöcken bauen und
`MailTemplates.html(_:brand:)` aufrufen, Klartext getrennt liefern, Test in `MailTemplateTests` ergänzen.
Vorschau: `scripts/mail-preview.sh [Ordner]` schreibt alle Mails als `.html`/`.txt`; mit `MAIL_PREVIEW_SHOTS=1` und `PLAYWRIGHT_DIR` zusätzlich PNGs (hell, dunkel, schmal).

## 8. Referenzen und Validierung

- Fluent: https://docs.vapor.codes/fluent/overview/
- Docker: https://docs.vapor.codes/deploy/docker/
- Statische PWA: https://svelte.dev/docs/kit/adapter-static
- Komponenten: https://www.shadcn-svelte.com/docs
- Shortcuts: https://support.apple.com/en-euro/guide/shortcuts/apd602971e63/ios

Konkrete Versionen stehen in `Package.swift`/`Package.resolved` und `LIZENZEN.md`. Keine nicht getestete Kompatibilität
behaupten: amd64 ist nur emuliert belegt, MariaDB 12.3 nur lokal, echte Clients (ChatGPT, Claude, iPhone-Shortcuts, Plattform-Passkeys)
sind nicht geprüft (`STATUS.md`).
