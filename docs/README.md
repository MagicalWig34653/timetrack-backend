# Dokumentationslandkarte

Stand: 17.10.2026. Jede Information hat genau eine maßgebliche Datei; andere Dateien verweisen darauf
(Regeln: [ENTWICKLUNGSABLAUF.md](ENTWICKLUNGSABLAUF.md)).

## Was steht wo

| Frage | Maßgebliche Datei |
| --- | --- |
| **Selbst installieren: Überblick, Auswahl Compose oder Swarm, Image** | [INSTALLATION.md](INSTALLATION.md) |
| Installation, Seiten im Einzelnen: Compose, Swarm, eigene MariaDB, Reverse Proxy, Ersteinrichtung, Push, Sichern, Probleme, Konfigurationsreferenz | `installation/`: [compose](installation/compose.md), [swarm](installation/swarm.md), [mariadb](installation/mariadb.md), [proxy](installation/proxy.md), [ersteinrichtung](installation/ersteinrichtung.md), [push](installation/push.md), [backup](installation/backup.md), [probleme](installation/probleme.md), [konfiguration](installation/konfiguration.md) |
| Image selbst bauen (buildx, Build-Argumente, eigene Registry) | [IMAGE-BAUEN.md](IMAGE-BAUEN.md) |
| Aktualisieren, Datenbank-Migrationen, Rollback | [UPDATE.md](UPDATE.md) |
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
| Produktion einrichten, ausführlich (Swarm, eigene MariaDB, Proxy, erster Admin, Go-Live-Checkliste) | [DEPLOYMENT.md](DEPLOYMENT.md) |
| CI, Image-Build, Releases, GitHub Pages (Website `site/`) | [CI.md](CI.md) |
| Container/Deployment | [../deploy/README.md](../deploy/README.md), [../compose.yaml](../compose.yaml) |
| Designsprache (Tokens, Shell, Komponenten; native Entsprechung im Apple-Repo) | [DESIGN.md](DESIGN.md), ADR-0014 |
| Website (GitHub Pages), Quellen der Seite | [../site/](../site/) (Doku-Seiten werden aus diesen Dokumenten erzeugt), [CI.md](CI.md) |
| Code-Reviews | [reviews/](reviews/) (bisher nur der Codex-Review C9–C18) |
| Abhängigkeiten aller drei Repos (Lizenzinventar) | [LIZENZEN.md](LIZENZEN.md) |
| Agent-Einstiege | [../AGENTS.md](../AGENTS.md), [../CLAUDE.md](../CLAUDE.md), [../CLAUDE_STARTPROMPT.md](../CLAUDE_STARTPROMPT.md) (historischer Startauftrag) |

Client-Repositories (öffentlich, siehe [REPOSITORIES.md](REPOSITORIES.md)):

- **timetrack-pwa**: `docs/STATUS.md` (Stand, Testbefehle, Routen), `docs/SHORTCUTS.md` (Shortcuts-Anleitung), `docs/handoffs/` (L1–L23, P1, P2, X1, W1).
- **timetrack-apple**: `docs/STATUS.md` (Stand der Apps, Signierung, TestFlight), `docs/DESIGN-NATIVE.md` (native Designsprache), `docs/ICONS.md` (App-Symbole), `docs/handoffs/` (A1–A8, W1), `docs/screenshots/`.

**Hinweis zu Commit-Hashes:** Vor der Veröffentlichung am 17.10.2026 wurde die Historie bereinigt (alle Hashes neu). Hashes in älteren Handoffs und ADRs sind ungültig; Paket-ID und `git log --grep` verwenden.

## ADR-Index

Alle 20 ADRs (0001–0020) sind akzeptiert; es gibt keinen verworfenen oder ersetzten ADR. Bei den Etappen- und Paket-ADRs sind Details ausdrücklich als Lead- bzw. Paketannahmen markiert
und keine Nutzerentscheidungen (siehe jeweilige Statuszeile). Nummer 0004 existiert zweimal (Hauptdatei und Ergänzung 0004a). „umgesetzt“ heißt: das zugehörige Paket ist integriert, nicht: auf Echtgeräten geprüft.

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
| 0012 | Abschaltbare Module (Server und Konto) | akzeptiert (Nutzerentscheidung 15.10.); umgesetzt (C20, L17) | [ADR-0012](decisions/ADR-0012-modulschalter.md) |
| 0013 | Arbeitszeit-Tabelle (Import/Export) | akzeptiert (inkl. Nachträge); umgesetzt (C21–C23) | [ADR-0013](decisions/ADR-0013-arbeitszeit-tabelle.md) |
| 0014 | Designsprache | akzeptiert; umgesetzt in PWA (L21) und nativ (A6) | [ADR-0014](decisions/ADR-0014-designsprache.md) |
| 0015 | Native Clients: Anmeldung und API-Zugriff | akzeptiert (A1, mit Nachträgen A3–A8); umgesetzt, Passkey-Weg auf Gerät ungeprüft | [ADR-0015](decisions/ADR-0015-native-clients.md) |
| 0016 | Kontenverwaltung, Selbstauskunft und Löschung | akzeptiert; umgesetzt (B1, L23) | [ADR-0016](decisions/ADR-0016-kontenverwaltung.md) |
| 0017 | Wartung: Aufräumjob, Review-Restpunkte, MariaDB-Isolation unter `auth_lock` | akzeptiert; umgesetzt (B2) | [ADR-0017](decisions/ADR-0017-wartung.md) |
| 0018 | Vertrauenswürdige Proxys: Client-Adresse für Rate-Limits | akzeptiert; umgesetzt (B4); ohne echten Proxy getestet | [ADR-0018](decisions/ADR-0018-vertrauenswuerdige-proxys.md) |
| 0019 | Profil, E-Mail-Änderung per Code, geführte Einrichtung | akzeptiert; umgesetzt (P1) | [ADR-0019](decisions/ADR-0019-profil-onboarding.md) |
| 0020 | Darstellung (Akzentfarbe, Farbschema) je Konto | akzeptiert (Nutzerentscheidung 16.10.); umgesetzt (P2, A8) | [ADR-0020](decisions/ADR-0020-darstellung-konto.md) |
| 0021 | Wochenplanung (geplante Zeiten) und Wochenübersicht | Umsetzungsentscheidung (K1); Lead-Prüfung offen | [ADR-0021](decisions/ADR-0021-wochenplanung.md) |
| 0025 | Urlaubsplanung (Urlaubsvorschläge) | Umsetzungsentscheidung (V2); Lead-Prüfung offen | [ADR-0025](decisions/ADR-0025-urlaubsplanung.md) |
| 0026 | Vorlage für den Urlaubsantrag je Konto | Umsetzungsentscheidung (B7); Lead-Prüfung offen | [ADR-0026](decisions/ADR-0026-urlaubsantrag-vorlage.md) |
| 0027 | Abgang beendet fremd gestartete Timer; Auslöse-Links (`GET /t/<token>/…`) | Umsetzungsentscheidung (W1); Lead-Prüfung offen | [ADR-0027](decisions/ADR-0027-ausloese-links.md) |
| 0028 | JArbSchG-Rechtsprofil und Berufsschulgutschrift | R2-Worktree; fachliche Prüfung offen | [ADR-0028](decisions/ADR-0028-jugendarbeitsschutzprofile.md) |
| 0031 | Mehrere Planblöcke pro Tag, Alt-API und Migration | Umsetzungsentscheidung (P13); Prüfung im Worktree | [ADR-0031](decisions/ADR-0031-planbloecke.md) |

## Namensgebung und Kennungen (Entscheidung 17.10.2026)

- Das Projekt, die Repos, Pakete und Oberflächen heißen weiter **Timetrack**. **Chronolog** ist nur der Name des App-Eintrags in App Store Connect („Chronolog – Arbeitszeit“); der Anzeigename in den Apps und der PWA bleibt Timetrack. Eine geplante Umbenennung (Paket N1) wurde verworfen.
- Die produktive Domain (zugleich Passkey-RP-ID) und die Bundle-ID bleiben unverändert; die Bundle-ID ist nach dem Anlegen in App Store Connect nicht mehr änderbar. **Konvention:** Im Backend-Repo (und seiner Website) stehen dafür ausschließlich Platzhalter (`timetrack.example.org`, `com.example.timetrack`, Team-ID `ABCDE12345`); die tatsächlichen Werte stehen nur im Apple-Repo (`project.yml`, funktional nötig) und in der privaten Betreiber-Konfiguration. Neue Dokumente im Backend-Repo behalten diese Platzhalter.
- Öffentliche Repos: `MagicalWig34653/timetrack-backend`, `-pwa`, `-apple` (Pseudonym des Projekts; Historie am 17.10.2026 von persönlichen Angaben bereinigt; unbereinigte Sicherungen nur lokal außerhalb der Repos, siehe [REPOSITORIES.md](REPOSITORIES.md)).
- Commit-Autor ist die Pseudonym-Identität des Projekts. Keine privaten E-Mail-Adressen, Pfade, Hostnamen, IP-Adressen oder Domains in Repos.
