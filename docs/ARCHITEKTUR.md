# Technischer Entwurf

Entwurf Stand 13.10.2026, Entscheidungs- und Umsetzungsvermerke Stand 15.10.2026. Stack/Anforderungen bestätigt.
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
nach `contracts/openapi.yaml` (v0.9.0), `/mcp` und `/oauth/*` als Adapter derselben Dienste. Der Erinnerungs-Scheduler läuft
im Prozess mit DB-Lease (`job_leases`, ADR-0010), kein eigener Worker-Prozess und kein Redis. Migrationen laufen derzeit über
`AUTO_MIGRATE=true` beim Start; ein expliziter, einmaliger Migrationsschritt für den Swarm-Betrieb ist **offen**. Die PWA wird vom
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

Umsetzungsstand: 22 Tools nach Scope (ADR-0009), Audit in `mcp_audit` ohne Parameter/Ergebnisse, persönliche Tokens (`ttp_…`,
nur für `/mcp`, Ablauf Pflicht), Grants widerrufbar, Rate-Limit 120 Anfragen je 5 Minuten. Der ursprüngliche „Vorschlag mit
Änderungstoken“ wurde durch `expectedVersion` und `clientEventId` ersetzt. Abschaltbar je Server/Konto über das geplante
Modul `mcp` (ADR-0012, offen).

## 4. Datenmodell und Zeitbewertung

Fachliche Objekte: Nutzer, Passkey, Identität, Sitzung, Einladung, OAuth-Grant, persönliches MCP-Token,
Wiederherstellungsmethode/-Challenge/-Code;
Arbeitsverhältnis/Regelversion, Ort, Standortereignis, Arbeitsabschnitt, Pause, Bewertung,
Kontokorrektur, Plan, Abwesenheit, Urlaubskontobewegung, Dokument, Berichtsheft/Quelle,
Kalenderverbindung/-regel, Freigabe, Importcharge, Exportauftrag, Push-Abo und KI-Auftrag/Worker.

Zeitpunkte UTC plus fachliche Zeitzone, Ganztagsplanung als lokale Datumswerte.
Dauern als Ganzzahlen (z. B. Sekunden), keine Float-Stunden als maßgebliche Werte.
Regelversion/Rundungsherkunft speichern; heutige Profiländerung bewertet Vergangenheit nicht still neu.
Korrekturen versionieren, Rohereignisse erhalten. Mitternacht, Sommerzeit und Teilzeit berücksichtigen.
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
**Offen**: Migration bestehender Dateien zwischen Backends, periodischer Speicher-Aufräumjob, dokumentiertes und getestetes
Backup/Restore.

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

## 8. Referenzen und Validierung

- Fluent: https://docs.vapor.codes/fluent/overview/
- Docker: https://docs.vapor.codes/deploy/docker/
- Statische PWA: https://svelte.dev/docs/kit/adapter-static
- Komponenten: https://www.shadcn-svelte.com/docs
- Shortcuts: https://support.apple.com/en-euro/guide/shortcuts/apd602971e63/ios

Konkrete Versionen stehen in `Package.swift`/`Package.resolved` und `LIZENZEN.md`. Keine nicht getestete Kompatibilität
behaupten: amd64 ist nur emuliert belegt, MariaDB 12.3 nur lokal, echte Clients (ChatGPT, Claude, iPhone-Shortcuts, Plattform-Passkeys)
sind nicht geprüft (`STATUS.md`).
