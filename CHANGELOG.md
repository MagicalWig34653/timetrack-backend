# Änderungsprotokoll

Format angelehnt an „Keep a Changelog“; Versionen nach SemVer (`0.x` = Alpha: Schnittstellen und Datenmodell können sich noch ändern).
Die Einzelpakete (A1, B2, …) stehen in `docs/ARBEITSPLAN.md`.

## Unveröffentlicht

- **Kalenderabo und Feiertagsanzeige (N2, Vertrag 0.31.0):** Widerrufbare ICS-Abo-Links `GET /ics/{token}.ics` (RFC 5545; Abwesenheiten mit Status, Feiertage, optional Plan und erfasste Zeit; Fenster -60 bis +400 Tage; ETag/304; Token nur als Hash, 404 ohne Orakel, Ratenbegrenzung), Verwaltung unter `/me/calendar-feeds`, nicht per MCP. `TimeWeekDay.holidayName` nennt Feiertage auch am Wochenende und außerhalb von Arbeitsmodellen; Feiertagstabellen aller Länder mit Tests für 2026/2027 abgesichert.
- **Korrekturen Jugendprofil und Zeitkonto (X4, Vertrag 0.30.1):** Arbeit an einem vollen Berufsschultag wird auch vor Schulbeginn gewarnt; Feiertags-Ausfall zählt in die gesetzliche Wochensumme (§ 4 Abs. 4 JArbSchG); Kontostart berücksichtigt nach Löschen des Eröffnungssaldos frühere Anpassungen.
- **Jugendrechtsprofil (R2, Vertrag 0.29.0):** `jarbschg-minor-de` neben `arbzg-adult-de`, Profilwahl je datiertem Arbeitsmodell, Berufsschulstunden und 8-/40-Stunden-Gutschrift, Pausen-, Ruhezeit- und Grenzhinweise; `GET /legal-profiles`, Migration und additive Tages-/Wochen-/Statistikfelder. Hinweise sind informativ und keine Rechtsberatung.
- **Client-Lücken X3 (Vertrag 0.30.0):** `needsReview` endet nach Ende-Korrektur oder Entscheidung über einen Ende-Vorschlag; ausdrückliche Quittierung per `PATCH` möglich. Zeitkonto-Anpassungen sind seitenweise lesbar und einzeln löschbar; der Saldo wird neu berechnet. MCP kann die Anpassungen lesen.
- **Stornierte Abschnitte und Statistik (W3, Vertrag 0.28.0):** Übersicht (`GET /time/segments/cancelled`), Wiederherstellen (`POST /time/segments/{id}/restore`) und endgültiges Löschen stornierter Abschnitte (einzeln `DELETE …?permanent=true`, gesammelt `DELETE /time/segments/cancelled` mit `dryRun`); MCP nur Liste und Wiederherstellen. Neue Statistikreihe für Diagramme `GET /time/statistics` (Tag/Woche/Monat; Soll, Ist, Differenz, Zeitkonto, Arten, Abwesenheiten, Pausen).
- **Letzten Timer fortsetzen (W2, Vertrag 0.27.0):** `PATCH /time/segments/{id}` mit `endedAt: null` öffnet einen beendeten Abschnitt wieder (nur wenn kein Timer läuft und kein späterer Abschnitt existiert; sonst 409 `timer_already_running` bzw. `segment_overlap`), auch über MCP `correct_segment`.

## 0.1.0 – 2026-10-19 (erster Release, Alpha)

Erster nutzbarer Stand von Timetrack (Backend, PWA, Apple-Apps). API-Vertrag: `contracts/openapi.yaml` Version 0.22.0.

### Enthalten
- **Zeiterfassung:** Timer, manuelle Abschnitte, Korrekturen mit Begründung, Arbeitsmodelle mit Gültigkeitszeitraum, Rohzeit/Korrektur/bewertete Zeit getrennt, Rundung (Standard 15 Minuten zugunsten des Arbeitnehmers, nur erster Beginn/letztes Ende des Tages), Pausenhinweise, Zeitkonto.
- **Planung:** Urlaub und Abwesenheiten, Feiertage aller 16 Bundesländer, Kalender, Planfreigaben zwischen Konten (standardmäßig privat).
- **Berichtsheft:** Lernfelder, Zeit und Notizen, kopierbare Ausgabe.
- **Import/Export:** CSV/Excel mit Vorschau und Rücknahme; Import und Export der Arbeitszeit-Tabelle (Jahresblätter, Wochenblöcke); Export als Tabelle, PDF, CSV; Dateianhänge mit Speicherregeln (Datenbank, S3, lokal).
- **Anmeldung:** Passkeys (mehrere pro Konto), Einladung statt offener Registrierung, Wiederherstellung (Recovery-Codes, Rückfallpasswort, E-Mail-Codes), optional OpenID Connect.
- **Zugänge für KI und Automatisierung:** MCP-Endpunkt mit OAuth 2.1 und persönlichen Tokens, Geräte-Tokens für Kurzbefehle.
- **Module** serverweit und je Konto abschaltbar; Konten- und Datenschutzfunktionen (Admin-Verwaltung, Datenexport, Selbstlöschung); Akzent und Erscheinungsbild im Konto.
- **Wochenplanung und Urlaubsplanung:** Wochenplaner und Wochenübersicht mit geplanten und tatsächlichen Zeiten; Urlaubsempfehlungen (Brückentage, Feiertagsblöcke, Schulferien-Verlängerung) auf Basis von Feiertagen, Arbeitsmodell, Resturlaub und erfassten Ferien, mit Übernahme in den Urlaub.
- **Betriebsdiagnose:** Versions- und Build-Angaben im Hilfedialog (`GET /api/v1/system/info`), SMTP-Prüfung mit optionaler Testmail in den Servereinstellungen, Datenbankausfall als `503 database_unavailable` mit `Retry-After`, selbstheilender Start der PWA bei fehlenden Dateien nach Updates.
- **Darstellung:** 21 Akzentfarben (davon sechs mit besonders gutem Kontrast zu weißer Schrift), Glow-Stufen, Hell/Dunkel; App-Icons mit Varianten.
- **Apps:** PWA, iOS/iPadOS, macOS und watchOS (SwiftUI), Widgets, Live Activity (mit Nachholen im Vordergrund), Steuerzentrale und Komplikation, Fokus-Filter mit Diagnose, Standortautomatik (Regionen, Verweilzeit, Warteschlange) und Kurzbefehle.
- **Betrieb:** Docker-Image (amd64, arm64) mit eingebauter PWA, Compose-Variante und Swarm-Stack, Wartungsjob, Backup/Restore-Skripte, vertrauenswürdige Proxys, GitHub-Actions und Dokumentationsseite.

### Bekannte Einschränkungen
- Alpha: kein langfristiges Stabilitätsversprechen für die API und das Datenmodell.
- Die Passkey-Anmeldung in den nativen Apps braucht die bezahlte Apple-Mitgliedschaft und eine öffentlich erreichbare Domain mit `apple-app-site-association`.
- Erprobt vor allem auf einer Instanz mit MariaDB 12.3; ein echter Mehrknoten-Swarm, Lasttests und amd64-Emulation sind nicht erprobt.
- Berichtsheft-Ausgabe im IHK-Format, Rechtsprofile für Jugendliche, KI-Entwürfe und die Kalenderanbindung sind noch nicht umgesetzt; Standortautomatik, Fokus-Filter und Live Activity sind auf echten Geräten noch nicht vollständig geprüft.
- Details und weitere Lücken: `docs/STATUS.md`.
