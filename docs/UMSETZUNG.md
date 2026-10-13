# Vorgeschlagene Umsetzung für Claude Code

Grundgerüste vorhanden, noch keine fachliche Implementierung oder Anwendungstests. Etappen setzen den bestätigten Umfang schrittweise um.
Offene fachliche Details jeweils vor dem betroffenen Schritt klären, nicht das ganze Vorhaben blockieren.

## 0. Technische Durchstiche

- Vapor/Fluent-Migration, konkurrierende Transaktionen auf MariaDB 12.3.3 und SQLite.
- Docker-Build und Laufzeit auf amd64/arm64, einschließlich nativer Abhängigkeiten.
- Swift-WebAuthn-Bibliothek und integrierbare OAuth-Authorization-Server-Komponente.
- Remote-MCP mit OAuth in ChatGPT und Claude sowie persönlichem Bearer-Token in einem weiteren Client.
- Shortcut-Aufenthaltsnachweis/Vorbeifahrtschutz auf Zielgerät.
- XLSX/CSV/PDF-Bibliotheken und Dateistreaming auf beiden Architekturen.
- Optionaler eigener Spike für ChatGPT-Plan-Nutzung; Kern davon unabhängig halten.

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

## 5. Native Apps

macOS zuerst: SwiftUI, optional Kalenderbrücke, lokale KI/persönlicher KI-Worker.
Danach iOS/iPadOS, native Standorterfassung und watchOS. Apple HIG/Liquid Glass.
Bei Mac offline/Modellfehler kein Datenverlust oder stiller Cloud-Fallback.
Kalenderkonflikte nach vereinbarter Regel; keine unbeabsichtigte Freigabe privater Titel.

## 6. Später

Selbstständigkeit: Kunden/Projekte/Stundensätze und macOS-Vordergrund-App-Tracking.
Google-Kalender, optionale E-Mail, Offline-Sync bei vertretbarem Aufwand.
Strukturierter PDF-Import und Kalender-Schreibzugriff nach eigener Entscheidung.

Offene Details siehe KONZEPT.md Abschnitt 9. Routinemäßige Implementierungsentscheidungen
selbst treffen und dokumentieren; bereits bestätigte Richtungen nicht erneut abfragen.
