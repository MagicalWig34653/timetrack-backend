# Änderungsprotokoll

Format angelehnt an „Keep a Changelog“; Versionen nach SemVer (`0.x` = Alpha: Schnittstellen und Datenmodell können sich noch ändern).
Die Einzelpakete (A1, B2, …) stehen in `docs/ARBEITSPLAN.md`.

## 0.1.0 – 2026-10-17 (erster Release, Alpha)

Erster nutzbarer Stand von Timetrack (Backend, PWA, Apple-Apps). API-Vertrag: `contracts/openapi.yaml` Version 0.14.0.

### Enthalten
- **Zeiterfassung:** Timer, manuelle Abschnitte, Korrekturen mit Begründung, Arbeitsmodelle mit Gültigkeitszeitraum, Rohzeit/Korrektur/bewertete Zeit getrennt, Rundung (Standard 15 Minuten zugunsten des Arbeitnehmers, nur erster Beginn/letztes Ende des Tages), Pausenhinweise, Zeitkonto.
- **Planung:** Urlaub und Abwesenheiten, Feiertage aller 16 Bundesländer, Kalender, Planfreigaben zwischen Konten (standardmäßig privat).
- **Berichtsheft:** Lernfelder, Zeit und Notizen, kopierbare Ausgabe.
- **Import/Export:** CSV/Excel mit Vorschau und Rücknahme; Import und Export der Arbeitszeit-Tabelle (Jahresblätter, Wochenblöcke); Export als Tabelle, PDF, CSV; Dateianhänge mit Speicherregeln (Datenbank, S3, lokal).
- **Anmeldung:** Passkeys (mehrere pro Konto), Einladung statt offener Registrierung, Wiederherstellung (Recovery-Codes, Rückfallpasswort, E-Mail-Codes), optional OpenID Connect.
- **Zugänge für KI und Automatisierung:** MCP-Endpunkt mit OAuth 2.1 und persönlichen Tokens, Geräte-Tokens für Kurzbefehle.
- **Module** serverweit und je Konto abschaltbar; Konten- und Datenschutzfunktionen (Admin-Verwaltung, Datenexport, Selbstlöschung); Akzent und Erscheinungsbild im Konto.
- **Apps:** PWA, iOS/iPadOS, macOS und watchOS (SwiftUI), Widgets, Live Activity, Steuerzentrale und Komplikation.
- **Betrieb:** Docker-Image (amd64, arm64) mit eingebauter PWA, Compose-Variante und Swarm-Stack, Wartungsjob, Backup/Restore-Skripte, vertrauenswürdige Proxys, GitHub-Actions und Dokumentationsseite.

### Bekannte Einschränkungen
- Alpha: kein langfristiges Stabilitätsversprechen für die API und das Datenmodell.
- Die Passkey-Anmeldung in den nativen Apps braucht die bezahlte Apple-Mitgliedschaft und eine öffentlich erreichbare Domain mit `apple-app-site-association`.
- Erprobt vor allem auf einer Instanz mit MariaDB 12.3; ein echter Mehrknoten-Swarm, Lasttests und amd64-Emulation sind nicht erprobt.
- Berichtsheft-Ausgabe im IHK-Format, Rechtsprofile für Jugendliche, Standortautomatik und KI-Entwürfe sind noch nicht umgesetzt.
- Details und weitere Lücken: `docs/STATUS.md`.
