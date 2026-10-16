# Umsetzung in Etappen

Stand: 15.10.2026. Etappen 0–4 sind im Backend und in der PWA umgesetzt, Etappe 5 begonnen (A1, A2), Etappe 6 nicht begonnen.
Die Etappen setzen den bestätigten Umfang schrittweise um; **maßgeblich für geprüfte Zahlen und offene Punkte ist `STATUS.md`**,
Pakete und Belege stehen in `ARBEITSPLAN.md` und `handoffs/`. Die Abnahmekriterien unten sind der ursprüngliche Maßstab;
je Etappe steht darunter, welche davon belegt sind. „Belegt“ heißt: automatisierte Tests (SQLite und MariaDB, soweit
angegeben) oder vom Lead ausgeführte Läufe, nicht Prüfung auf Echtgeräten.
Offene fachliche Details jeweils vor dem betroffenen Schritt klären, nicht das ganze Vorhaben blockieren.

## Umsetzungsstand je Etappe

| Etappe | Stand | Pakete (Auswahl) | Wesentlich offen |
| --- | --- | --- | --- |
| 0 Durchstiche | überwiegend erledigt | C1, C2, C11, C13, C16/C17, L2/L3a | amd64 nur emuliert (SQLite, 14.10.); Shortcuts auf echtem Gerät; MCP in echtem ChatGPT/Claude; ChatGPT-Plan-Spike nicht begonnen |
| 1 Grundlage und Konten | erledigt (Backend + PWA) | C1–C4, C14, L1, L3b, L11 | echter Plattform-Passkey, echter SMTP-Versand (nur Mailpit/Fake) |
| 2 Zeittracking | erledigt (Backend + PWA) | C5–C7, L4, L5 | Shortcuts mit echtem Aufenthalt/Vorbeifahrt auf Gerät |
| 3 Planung und Datenaustausch | erledigt bis auf Restore | C8–C13, L6–L9, L12 | gemeinsames DB/Datei-Restore ungeprüft; XLSX/PDF nicht in Excel/Viewer geöffnet; S3 nur gegen S3Mock |
| 4 Berichtsheft, Hinweise, MCP | Backend und PWA umgesetzt, Geräteprüfung offen | C15–C19, L13–L16, X1 | IHK-Format nur Standardprofil; Push nur gegen Fake-Dienst; Connector in ChatGPT/Claude; Alt-PDF nur als Archivdatei |
| 4d Modulschalter (neu, ADR-0012) | in Arbeit | C20 Backend, L17 PWA | beides offen (Stand 15.10.) |
| 5 Native Apps | begonnen (16.10.2026) | A1 (integriert), A2 (Backend umgesetzt, Lead-Prüfung offen) | iOS/watchOS (A3/A4); echter Plattform-Passkey auf Gerät; Produktionsdomain `timetrack.example.org` und AASA-Auslieferung |
| 6 Später | nicht begonnen | – | alles |

Zusätzlich offen (Etappen-übergreifend, `ARBEITSPLAN.md` Backlog): Kontenverwaltung, Backup/Restore, Produktions-/Swarm-Stack,
Aufräumjobs, Vertragstests.

## 0. Technische Durchstiche

- Vapor/Fluent-Migration, konkurrierende Transaktionen auf MariaDB 12.3.3 und SQLite.
- Docker-Build und Laufzeit auf amd64/arm64, einschließlich nativer Abhängigkeiten.
- Swift-WebAuthn-Bibliothek und integrierbare OAuth-Authorization-Server-Komponente.
- Remote-MCP mit OAuth in ChatGPT und Claude sowie persönlichem Bearer-Token in einem weiteren Client.
- Shortcut-Aufenthaltsnachweis/Vorbeifahrtschutz auf Zielgerät.
- XLSX/CSV/PDF-Bibliotheken und Dateistreaming auf beiden Architekturen.
- Optionaler eigener Spike für ChatGPT-Plan-Nutzung; Kern davon unabhängig halten.

Stand: Migrationen und konkurrierende Transaktionen auf MariaDB 12.3 und SQLite belegt (C1, Tests laufen auf beiden).
Docker-Build arm64 belegt, amd64 nur emuliert und nur für SQLite (14.10., `handoffs/L3a.md`). WebAuthn: `webauthn-swift`;
OAuth-Server: eigene Implementierung (ADR-0009). Export/Import: eigene OOXML-/PDF-Writer plus ZIPFoundation, S3 über
eigenen SigV4-Client (ADR-0006). MCP: Protokoll, Tools und Rechte automatisiert und per Skript-Client im Browser-E2E (X1) belegt;
**nicht** in echtem ChatGPT/Claude. Shortcuts-Aufenthalt auf Zielgerät: nicht erprobt. ChatGPT-Plan-Spike: nicht begonnen.

## 1. Grundlage und Konten

Beschlossen: drei Repos gemäß `REPOSITORIES.md`. Backend führt contracts/, deploy/ und globale docs/.
AGPLv3-Lizenztext und Abhängigkeitsprüfung, reproduzierbare Builds, statische PWA mit Swift-API,
Passkeys, Einladungen, Kontentrennung und Servereinstellungen. OIDC als optionaler Adapter.

Abnahme:

- Zwei Konten sehen auch über direkte IDs, Suche und Exporte keine fremden Daten.
- Mehrere Passkeys, einzelner Widerruf und dokumentierte Wiederherstellung funktionieren.
- E-Mail-Code, Rückfallpasswort und Recovery-Code als wählbare Verfahren geprüft;
  abgelaufene/verbrauchte Codes und parallele Wiederverwendung abgelehnt.
- Ohne Mailkonfiguration ist E-Mail-Recovery nicht wählbar; andere Verfahren funktionieren.
- Einladung abgelaufen/verbraucht wird abgelehnt; paralleles Einlösen bleibt einmalig.
- OIDC darf Einladungspflicht nicht umgehen. Kein Node im Produktionsbetrieb erforderlich.

Stand: erledigt. Belegt durch `AuthTests`/`AuthHTTPTests` (u. a. Isolation und CSRF, Wiederverwendung von Recovery-Codes,
E-Mail-Code mit Ablauf und Versuchslimit, Passwort ohne Mailversand, parallele Einladung/Recovery, letzter Passkey bleibt
bei parallelem Widerruf), `OIDC*Tests` (Einladungspflicht) und Browser-E2E der PWA. Nicht belegt: echter Plattform-Passkey,
echter SMTP mit TLS/AUTH. Eine Suchfunktion existiert nicht, daher entfällt das Kriterium „Suche“.

## 2. Zeittracking

Arbeitsmodelle, Tageszeitleiste, HO/Büro/Fahrt/Pausen, Automatik, Rundung, Konto und Korrekturen.

Abnahme:

- 38,5 Wochenstunden und Tageswerte berechenbar; 7,7 korrekt als 7:42 dargestellt.
- Regelwechsel verändert Historie nicht still. Rohzeit/Bewertung unterscheidbar.
- Ortswechsel verdoppelt keine Zeit, übersprungene Pause wird nicht erfunden.
- Nur äußerste Tagesgrenzen runden. Beispiel: 08:07–12:00 und 13:00–16:02 ergeben
  6:55 tatsächliche Arbeit und 7:15 bewertet; die einstündige Pause bleibt unverändert.
- Berufsschule unter der Schwelle füllt nicht still zum vollen Tag auf; manuelle Ergänzung möglich.
- Wiederholte/verspätete Shortcuts und PWA-Rennen erzeugen keine zweite aktive Buchung.
- Vorbeifahrt verworfen oder zur Prüfung gestellt, nicht allein per Timer gebucht.
- Sommerzeit, Mitternacht, Berufsschulschwelle und vereinbarte Rundungsgrenzen getestet.

Stand: erledigt, soweit automatisiert prüfbar. Belegt durch `TimeEngineTests` (Rundungsbeispiele, Pausen, Schulschwelle,
Nachtschicht, Sommerzeit, Property-Tests), `TimeHTTPTests` (Timer-Idempotenz und Parallelität, Modellhistorie, Isolation
je direkter Ressource) und `AutomationHTTPTests` (direkt/Vorschlag/aus, Vorbeifahrt, Reihenfolge, Gerätetoken).
Nicht belegt: Shortcuts mit echter Standortauslösung auf iPhone/Mac.

## 3. Planung und Datenaustausch

Urlaubskonto, HO-/Arbeitsplanung, Ferien/Feiertage, Einreichungsdokumente, Planfreigaben,
visueller CSV/XLSX-Import, XLSX/PDF-Export und flexible Dateispeicherung.

Abnahme:

- Restbestand nicht zusätzlich zu vollem Anspruch gutgeschrieben; genehmigt → genommen nicht doppelt verbraucht.
- Freigabewiderruf sperrt neue Abrufe; Dokumente waren nie automatisch geteilt.
- Freigaben von Planung, Ist-Zeiten und Urlaub begrenzen REST/MCP auf die ausgewählten Ansichten.
- Importvorschau zeigt Formate/Fehler; Wiederholung ohne Duplikate; Dezimalstunden korrekt.
- Formelzellen/CSV-Werte sicher verarbeiten. Fehlende Daten nicht erfinden.
- Exakte Speichergrenzen, Bestandszugriff nach Regeländerung und gemeinsames DB/Datei-Restore geprüft.

Stand: erledigt bis auf Restore. Belegt durch `VacationEngineTests`, `PlanningHTTPTests`, `ExportTests`, `ImportEngineTests`,
`ImportHTTPTests`, `StorageTests`, `StorageHTTPTests` und die Regressionen aus C10/C19 (Speicherbindung, Zahlen-/Datumsgrenzen).
Nicht belegt: gemeinsames DB-/Datei-Restore (Verfahren fehlt, Backlog), Öffnen der Exporte in Excel/PDF-Viewer, Import mit
20 000 Zeilen auf MariaDB, Blobs nahe 64 MiB, S3 gegen echte Signaturprüfung (nur S3Mock/In-Process-Fake).

## 4. Berichtsheft, Benachrichtigungen und MCP

Text/Bildquellen, PDF-Altberichte, kopierbare IHK-Ausgabe, In-App/Web Push;
MCP-Lesezugriff und vereinbarte Schreibaktionen über gemeinsame Dienste.

Abnahme:

- Berichtsheft ohne KI nutzbar; Ausgabe passt zum vereinbarten Portalformat.
- Lernfeld, Zeit und Notizen sind erfassbar und kopierbar.
- Push-Ablehnung verhindert weder Tracking noch In-App-Hinweise.
- MCP Discovery/Login/Consent in ChatGPT und Claude; falsche Audience/Scopes und widerrufene Grants abgelehnt.
- Persönliche Bearer-Tokens ohne OAuth nutzbar, mit denselben Konten-/Scope-Grenzen;
  abgelaufene/widerrufene Tokens abgelehnt, Geheimnisse nicht in Logs/URLs.
- Lesetoken kann nicht schreiben; Dokumentrechte nicht aus Zeitplanfreigabe ableiten.
- Wiederholte Schreibaufrufe/veraltete Korrekturen korrekt behandelt.

Stand: Backend und PWA umgesetzt (C15–C19, L13–L16, X1). Belegt: Berichtsheft ohne KI mit Lernfeldern, Zeit, Notizen und
kopierbarem Text im Standardformat (`ReportHTTPTests`, Echt-E2E); OAuth-Server inkl. PKCE, Refresh-Rotation und Grants
(`OAuthHTTPTests`); persönliche Tokens und Scope-Prüfung, Kontentrennung und Audit (`MCPTests`); Hinweise, Scheduler mit Lease und
Web-Push-Verschlüsselung gegen den RFC-8291-Vektor (`Notification*Tests`, `C19PushTests`). Nicht belegt: Ausgabe gegen ein echtes
IHK-Portalformat (kein Beispiel vorhanden, Standardprofil angenommen, ADR-0008); Discovery/Login/Consent in echtem ChatGPT/Claude;
Push-Zustellung auf echten Geräten (nur Fake-Dienst); strukturierter PDF-Altberichtimport (nur Archivdatei möglich).

## 4d. Modulschalter (ergänzt 15.10.2026)

Betreiber und Konto können Module abschalten (ADR-0012, Vertrag v0.9.0): `reports`, `planning`, `transfer`, `automation`, `mcp`.
Stand: entschieden und im Vertrag beschrieben; Backend (C20) und PWA (L17) offen. Abnahme: je Modul Tests für Server aus,
Konto aus, beide an, Operator-Override (`MODULES_DISABLED`) und Tokens; Daten bleiben beim Abschalten erhalten.

## 5. Native Apps

macOS zuerst: SwiftUI, optional Kalenderbrücke, lokale KI/persönlicher KI-Worker.
Danach iOS/iPadOS, native Standorterfassung und watchOS. Apple HIG/Liquid Glass.
Bei Mac offline/Modellfehler kein Datenverlust oder stiller Cloud-Fallback.
Kalenderkonflikte nach vereinbarter Regel; keine unbeabsichtigte Freigabe privater Titel.

Stand: nicht begonnen. Vorhanden ist nur das XcodeGen-Grundgerüst im Repository timetrack-apple.

## 6. Später

Selbstständigkeit: Kunden/Projekte/Stundensätze und macOS-Vordergrund-App-Tracking.
Google-Kalender, optionale E-Mail, Offline-Sync bei vertretbarem Aufwand.
Strukturierter PDF-Import und Kalender-Schreibzugriff nach eigener Entscheidung.

Stand: nicht begonnen.

Offene Details siehe KONZEPT.md Abschnitt 9. Routinemäßige Implementierungsentscheidungen
selbst treffen und dokumentieren; bereits bestätigte Richtungen nicht erneut abfragen.
