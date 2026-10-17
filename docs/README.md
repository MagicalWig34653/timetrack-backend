# Dokumentationslandkarte

Stand: 15.10.2026. Jede Information hat genau eine maßgebliche Datei; andere Dateien verweisen darauf
(Regeln: [ENTWICKLUNGSABLAUF.md](ENTWICKLUNGSABLAUF.md)).

## Was steht wo

| Frage | Maßgebliche Datei |
| --- | --- |
| Was ist tatsächlich gebaut, geprüft, offen? | [STATUS.md](STATUS.md) |
| Welche Pakete gab es/gibt es, wer, mit welchem Ergebnis? | [ARBEITSPLAN.md](ARBEITSPLAN.md), Belege je Paket in [handoffs/](handoffs/) |
| Was ist gefordert (bestätigt vs. Vorschlag)? | [KONZEPT.md](KONZEPT.md) |
| Wie ist es technisch aufgebaut und entschieden? | [ARCHITEKTUR.md](ARCHITEKTUR.md) und [decisions/](decisions/) (ADR-Index unten) |
| In welchen Etappen, mit welcher Abnahme? | [UMSETZUNG.md](UMSETZUNG.md) |
| API (Pfade, Felder, Fehler) | [../contracts/openapi.yaml](../contracts/openapi.yaml), Version im Kopf der Datei |
| Wie starte/teste ich lokal? | [../EINRICHTUNG.md](../EINRICHTUNG.md) |
| Testdienste (Mailpit, S3Mock, Dex), Ports, Testdomain, Speicherplatz | [TESTUMGEBUNGEN.md](TESTUMGEBUNGEN.md) |
| MCP-Anbindung (Tools, Scopes, Connector) | [MCP.md](MCP.md) |
| Abhängigkeitslizenzen | [LIZENZEN.md](LIZENZEN.md) |
| Repositories, Pfade, Wissensverteilung | [REPOSITORIES.md](REPOSITORIES.md) |
| IDE-Wahl | [IDE.md](IDE.md) |
| Arbeitsweise, Sprache, Parallelarbeit, Checks, Definition of Done | [ENTWICKLUNGSABLAUF.md](ENTWICKLUNGSABLAUF.md) |
| Ergebnisse des Codex-Reviews C9–C18 | [reviews/2026-10-15-codex-review.md](reviews/2026-10-15-codex-review.md) |
| Betrieb: Backup/Restore, Swarm-Stack, Reverse-Proxy-Anforderungen, amd64 | [BETRIEB.md](BETRIEB.md) |
| Produktion einrichten (Swarm, eigene MariaDB, Proxy, erster Admin, Go-Live-Checkliste) | [DEPLOYMENT.md](DEPLOYMENT.md) |
| CI, Image-Build, Releases, GitHub Pages (Website `site/`) | [CI.md](CI.md) |
| Container/Deployment | [../deploy/README.md](../deploy/README.md), [../compose.yaml](../compose.yaml) |
| Agent-Einstiege | [../AGENTS.md](../AGENTS.md), [../CLAUDE.md](../CLAUDE.md), [../CLAUDE_STARTPROMPT.md](../CLAUDE_STARTPROMPT.md) (historischer Startauftrag) |

PWA-spezifische Dokumentation (z. B. Shortcuts-Anleitung) liegt im Repository timetrack-pwa.

## ADR-Index

Alle ADRs sind akzeptiert; bei den Etappen-ADRs sind Details ausdrücklich als Lead-Annahmen markiert
und keine Nutzerentscheidungen (siehe jeweilige Statuszeile). Nummer 0004 existiert zweimal (Hauptdatei und Ergänzung).

| Nr. | Titel | Status | Datei |
| --- | --- | --- | --- |
| 0001 | Repository als Projektgedächtnis | akzeptiert (Nutzervorgabe 13.10.) | [ADR-0001](decisions/ADR-0001-repository-als-projektgedaechtnis.md) |
| 0002 | Drei Repositories, Backend als Hauptrepo | akzeptiert (Nutzervorgabe 13.10.) | [ADR-0002](decisions/ADR-0002-getrennte-repositories.md) |
| 0003 | Etappe 1: Auth-Verträge, Annahmen, Paketaufteilung | akzeptiert (Lead 14.10.) | [ADR-0003](decisions/ADR-0003-etappe1-auth-vertraege-und-aufteilung.md) |
| 0004 | Etappe 2: Zeittracking, Fachregeln, Vertrag | akzeptiert (Lead 14.10.) | [ADR-0004](decisions/ADR-0004-etappe2-zeittracking-fachregeln.md) |
| 0004a | Ergänzung: Zuordnung bei Modellwechseln (C7) | akzeptiert (14.10.) | [ADR-0004-addendum](decisions/ADR-0004-addendum-model-transition.md) |
| 0005 | Etappe 3: Planung und Urlaub, Nutzervorgaben | akzeptiert (Nutzer 14.10., Regeln Lead-Annahmen) | [ADR-0005](decisions/ADR-0005-etappe3-planung-urlaub-vorgaben.md) |
| 0006 | Etappe 3b: Export, Import, Dateispeicher (eigene Writer, eigener S3-Client) | akzeptiert (Lead 14.10.); ergänzt durch ADR-0011 | [ADR-0006](decisions/ADR-0006-etappe3b-export-import-dateispeicher.md) |
| 0007 | Optionales OpenID Connect | akzeptiert (Lead 14.10.) | [ADR-0007](decisions/ADR-0007-oidc-optional.md) |
| 0008 | Berichtsheft (Standardformat) | akzeptiert (Lead 15.10.) | [ADR-0008](decisions/ADR-0008-berichtsheft.md) |
| 0009 | MCP-Server, OAuth-Server, persönliche Tokens | akzeptiert (Lead 15.10.); ergänzt durch ADR-0011 | [ADR-0009](decisions/ADR-0009-mcp-oauth-tokens.md) |
| 0010 | Hinweise, Web Push, PWA-Installierbarkeit | akzeptiert (Lead 15.10.); ergänzt durch ADR-0011 | [ADR-0010](decisions/ADR-0010-benachrichtigungen-push-pwa.md) |
| 0011 | C19: Speicherbindung, OAuth- und Push-Härtung | akzeptiert (Reparaturauftrag 15.10.) | [ADR-0011](decisions/ADR-0011-c19-review-haertung.md) |
| 0012 | Abschaltbare Module (Server und Konto) | akzeptiert (Nutzerentscheidung 15.10.); umgesetzt (C20/L17) | [ADR-0012](decisions/ADR-0012-modulschalter.md) |
| 0013 | Arbeitszeit-Tabelle (Import/Export) | akzeptiert (inkl. Nachträge) | [ADR-0013](decisions/ADR-0013-arbeitszeit-tabelle.md) |
| 0014 | Designsprache | akzeptiert | [ADR-0014](decisions/ADR-0014-designsprache.md) |
| 0015 | Native Clients: Anmeldung und API-Zugriff | Entwurf (A1); offene Fragen im ADR | [ADR-0015](decisions/ADR-0015-native-clients.md) |
| 0016 | Kontenverwaltung, Selbstauskunft und Löschung | akzeptiert (B1, integriert) | [ADR-0016](decisions/ADR-0016-kontenverwaltung.md) |
| 0017 | Wartung: Aufräumjob, Review-Restpunkte, MariaDB-Isolation unter `auth_lock` | akzeptiert (B2, integriert) | [ADR-0017](decisions/ADR-0017-wartung.md) |
| 0018 | Vertrauenswürdige Proxys: Client-Adresse für Rate-Limits | akzeptiert (B4, Lead-Prüfung offen) | [ADR-0018](decisions/ADR-0018-vertrauenswuerdige-proxys.md) |
| 0019 | Profil, E-Mail-Änderung per Code, geführte Einrichtung | akzeptiert (P1, Lead-Prüfung offen) | [ADR-0019](decisions/ADR-0019-profil-onboarding.md) |
| 0020 | Darstellung (Akzentfarbe, Farbschema) je Konto | akzeptiert (P2, Nutzerentscheidung 16.10.; Lead-Prüfung offen) | [ADR-0020](decisions/ADR-0020-darstellung-konto.md) |

## Namensgebung und Kennungen (Entscheidung 17.10.2026)

- Das Projekt, die Repos, Pakete und Oberflächen heißen weiter **Timetrack**. **Chronolog** ist nur der Name des App-Eintrags in App Store Connect („Chronolog – Arbeitszeit"); Anzeigename in den Apps und der PWA bleibt vorerst Timetrack.
- Produktionsdomain und Passkey-RP-ID: `timetrack.linolaske.de` (bleibt). Bundle-ID: `de.linolaske.timetrack` (bleibt; nach dem Anlegen in App Store Connect nicht mehr änderbar).
- Öffentliche Repos: `MagicalWig34653/timetrack-backend`, `-pwa`, `-apple` (Historie am 17.10.2026 von persönlichen Angaben bereinigt; Original-Sicherung lokal in `_old-repos/`).
