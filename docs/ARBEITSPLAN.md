# Arbeitsplan und Agent-Übergabe

Stand: 17.10.2026. Alle Pakete der Tabellen sind abgeschlossen (integriert, abgeschlossen, verworfen oder als nicht ausgeführt vermerkt); es gibt kein laufendes Paket. Zuweisung gemäß ADR-0003.
Gewichte sind Schätzwerte (Startvorschlag, nie nachträglich neu bewertet). **Commit-Hashes** in älteren Handoffs und Dokumenten stammen aus der Zeit vor der Historienbereinigung (17.10.2026) und passen nicht mehr zur veröffentlichten Historie; maßgeblich sind Paket-IDs, Merge-Nachrichten (`git log --grep`) und die Handoffs.
Die Punktebilanz (Codex gegen Claude) steht im Abschnitt „Punktebilanz“.
Abnahmebedingungen: `UMSETZUNG.md`. Vorgehen: `ENTWICKLUNGSABLAUF.md`.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| P0 | Voraussetzungen, Git, API-Vertrag (`contracts/openapi.yaml`, ADR-0003), Zuweisung | Claude-Lead | – | integriert | keine |
| C1 | Swift-Konfiguration, MariaDB/SQLite, Migrationen, Modelle, /ready, DB-Testbasis | Codex | 5 | integriert  | P0 |
| C2 | Einladung/Konten, Sitzung/CSRF, WebAuthn, Recovery, Admin-API, statische PWA, Integrationstests | Codex | 8 | integriert  | C1 |
| C3 | SMTP-Sender (STARTTLS/implicit, AUTH) für E-Mail-Recovery | Codex | 3 | integriert , nur gegen Fake-Server getestet | C2 |
| C4 | Lizenzinventar Swift + npm (`docs/LIZENZEN.md`) | Codex | 1 | integriert  | – |
| L1 | Svelte-Oberfläche Auth/Passkeys/Recovery/Einladungen (Repo timetrack-pwa) | Claude-Agent | 8 | integriert (PWA) | P0 |
| L2 | Dockerfile, Compose dev, MariaDB-Dev, Skripte | Claude-Agent | 3 | integriert  | P0 |
| L3a | Image-Builds arm64/amd64, Container-Läufe | Claude-Agent | 2 | integriert; arm64 belegt, amd64 emuliert belegt (SQLite) | L2, C2 |
| L3b | Browser-E2E (Playwright, virtueller Passkey) gegen echtes Backend | Claude-Agent | 3 | integriert (PWA), 15/15 vom Lead nachgelaufen | C2, L1 |
| C5 | Etappe 2: reine Zeit-Engine `TimeEngine` (ADR-0004) mit Tests | Codex | 5 | integriert; 49 Tests, 0 Fehler (Lead nachgelaufen), 18 neue Engine-Tests | ADR-0004 |
| C6 | Etappe 2: Persistenz, Migrationen, REST, Automation (Geräte-Token) | Codex | 8 | integriert; 61 Tests, 0 Fehler inkl. MariaDB 12.3.3 (Lead nachgelaufen) | C5 |
| L4 | Etappe 2: PWA Zeiterfassung/Modelle/Orte/Vorschläge gegen Mock | Claude-Agent | 8 | integriert (PWA-Repo `main`); 101 Unit- + 6 Mock-E2E-Tests vom Lead nachgelaufen; nur gegen Mock | Vertrag v0.2.0 |
| L5 | Etappe 2: Shortcuts-Anleitung, Echt-Integration, E2E | Claude-Agent | 4 | integriert (PWA); 29 E2E gegen echtes Backend vom Lead nachgelaufen | C6, L4 |
| C7 | Review-Fixes: Automation-Besuchsgrenze, Modellwechsel-Zuordnung (Codex-Review-Befunde) | Codex | 2 | integriert; 64 Tests, 0 Fehler inkl. MariaDB; 3 Regressionstests | C6 |
| P3 | Etappe 3: Vertrag v0.3.0 + Paketschnitt (ADR-0005) | Claude-Lead | – | integriert (Vertrag v0.3.0, ADR-0005 Fachregeln) | Nutzerantworten 14.10. erfasst |
| C8 | Etappe 3a: Feiertage (DE, 16 Länder), Urlaubs-/Abwesenheits-Engine, Tageseffekte (pure) | Codex | 5 | integriert; 78 Tests, 0 Fehler inkl. MariaDB (Lead nachgelaufen); Codex arbeitet jetzt im Hauptordner (Worktrees für Codex nicht beschreibbar) | P3 |
| C9 | Etappe 3a: Persistenz/REST Urlaub, Abwesenheiten, Kalender, Planung, Freigaben | Claude-Agent (Ersatz für Codex) | 8 | integriert (Merge); 81 Tests, 0 Fehler inkl. MariaDB (Lead nachgelaufen); Claude-Umsetzung wegen Codex-Limit (bis 20.10.), Nutzerentscheidung 14.10. | C8 |
| L6 | Etappe 3a: PWA Urlaub/Kalender/Planung/Freigaben gegen Mock | Claude-Agent | 8 | integriert (PWA); 158 Unit, 13 Mock-E2E, 29 E2E vom Lead nachgelaufen | P3 |
| L7 | Etappe 3a: Echt-Integration + E2E | Claude-Agent | – | aufgeteilt in L7a (2 Punkte, integriert; in der PWA-Historie) und L7b (unten); kein eigenes Paket, nicht gezählt | C9, L6 |
| C10 | Review-Fixes C9 (Überlauf-Absturz, Modellende, Buß- und Bettag, Kleinigkeiten) | Claude-Agent | 2 | integriert; 86 Tests inkl. MariaDB, 49 E2E vom Lead nachgelaufen | C9 |
| L7b | Etappe 3a: Echt-Integration E2E (20 neue Specs) | Claude-Agent | 3 | integriert (PWA); 49 E2E zweimal vom Lead nachgelaufen | C9, L7a |
| C11 | Etappe 3b: Export XLSX/PDF/CSV (eigene Writer, ADR-0006) | Claude-Agent (Codex-Limit) | 5 | integriert; 96→111 Tests inkl. MariaDB (Lead) | Vertrag v0.4.0 |
| C12 | Etappe 3b: Import CSV/XLSX mit Vorschau, Commit, Rollback | Claude-Agent (Codex-Limit) | 8 | integriert; 111 Tests inkl. MariaDB (Lead) | Vertrag v0.4.0 |
| C13 | Etappe 3b: Dateispeicher DB/S3/lokal, Admin-Regeln, Anhänge | Claude-Agent (Codex-Limit) | 8 | integriert (Merge); 127 Tests inkl. MariaDB vom Lead nachgelaufen; S3 nur gegen In-Process-Fake geprüft (S3Mock-Lauf offen) | Vertrag v0.4.0 |
| L9 | Etappe 3b: PWA Export/Import/Speicher/Anhänge gegen Mock | Claude-Agent | 8 | integriert (PWA-Repo `main`); 262 Unit, 23 Mock-E2E, 49 E2E vom Lead nachgelaufen; nur gegen Mock | Vertrag v0.4.0 |

Belege je Paket in `docs/handoffs/` (Backend) bzw. im PWA-/Apple-Repo (`docs/handoffs/`). Der Codex-Anteil besteht aus
eigenständig implementierten Features und Tests, nicht aus Reviews. Reviews (getrennt erfasst): Claude hat C1–C4 gelesen und
Tests selbst ausgeführt; Codex hat C9–C18 geprüft (R1, 12 Befunde, behoben in C19). Codex-Reviews für die PWA, die Apple-Apps und die Pakete ab C19 (außer eigenem Code) wurden nicht durchgeführt.
Koordination und gegenseitige Reviews getrennt erfassen, nicht als Implementierung umetikettieren.
Große Pakete vor Vergabe in überprüfbare Teilaufgaben zerlegen; keine acht Punkte als einen
unbegrenzten Agent-Auftrag vergeben. Spätere Etappen stehen in `UMSETZUNG.md`.

## Übergabeformat pro aktivem Paket

- Paket-ID, Ziel und Abnahmekriterien:
- Verantwortlicher und ausführender Agent/Plugin:
- Branch/Worktree, erlaubte Dateien und gemeinsam koordinierte Verträge:
- Status: offen / in Arbeit / blockiert / in Review / integriert:
- Implementierte Ergebnisse und Commit/Dateien:
- Tests mit Befehl, Ergebnis und Codezustand:
- Reviewbefunde und Auflösung:
- Migrationen/Daten-/Rechtefolgen:
- Laufende Jobs, Zustand und Übernahmeanleitung:
- Offene Probleme, nötige Nutzerinformation und nächster konkreter Schritt:

Nur ein Lead aktualisiert diese gemeinsame Datei während paralleler Arbeit.
Nach Integration Paketstatus, Punktezählung und `STATUS.md` gemeinsam aktualisieren.

Repo-Einrichtung durch Codex in dieser Vorbereitung; kein Claude-Plugin-Implementierungslauf.
Diese Vorarbeit zählt nicht als abgeschlossene C1/C2/L1/L2-Punkte.

14.10.2026: Sprachvorgabe in allen Agent-Einstiegen und im Startprompt dokumentiert.
L1 übernimmt auch die Auslagerung der bisherigen PWA-Texte in Lokalisierungsressourcen;
die native App folgt bei ihrem ersten Implementierungspaket. Kein aktiver Agent-Auftrag.

## Punktebilanz und Abweichung vom 50-%-Ziel (Stand 17.10.2026, Nachrechnung aus den Tabellen)

Summe der Paketpunkte (Schätzwerte; nur Umsetzungspakete mit Punkten; Reviews, Koordination, Lead-Verträge/Integration, aufgeteilte, verworfene oder nicht ausgeführte Pakete – L7, X2, N1, R1, P0, P3 – zählen nicht):

| Seite | Pakete | Punkte |
| --- | --- | --- |
| Codex | C1 5, C2 8, C3 3, C4 1, C5 5, C6 8, C7 2, C8 5, C19 8, C20 8, C21 10, C22 8, C23 6 | **77** |
| Claude-Agents, bis 15.10. | L1 8, L2 3, L3a 2, L3b 3, L4 8, L5 4, L6 8, L7a 2, L7b 3, C9 8, C10 2, C11 5, C12 8, C13 8, L9 8, L10 3, C14 8, L11 5, L12 5, C15 6, L13 6, L14 4, C16 8, C17 8, L15 5, X1 4, C18 8, L16 8, L17 6, D1 3, L18 8 | 175 |
| Claude-Agents, ab L19 | L19 4, L20 3, L21 10, L22 4, A1 10, A2 4, A3 8, A4 6, A5 5, A6 10, A6b 4, A6c 4, A6d 3, A7 8, A8 4, L23 8, B1 8, B2 8, B3 6, B4 3, B5 4, P1 8, P2 3, D2 3, W1 5, M1 6, MAIL1 6 | 155 |
| Claude-Agents gesamt | | **318** |

Formel: Codex-Anteil = 77 / (77 + 318) = 77 / 395 ≈ **19,5 %** – deutlich unter dem Richtwert 40–60 % (bis C22: 71 von 246 ≈ 29 %; der Anteil fiel, weil danach fast nur Claude-Pakete folgten, vor allem die gesamten Apple-Apps A1–A8, Betrieb, Dokumentation und Oberflächen).
Ursachen: Das Codex-Kontingent war vom 14.10. (nach C8) bis 15.10. erschöpft; C9–C18 (Backend-Fachpakete) setzten auf Nutzerentscheidung Claude-Agents um. Codex schreibt nur im Backend-Hauptordner (keine Worktrees, nicht in PWA/Apple), daher gingen Oberflächen-, E2E-, Apple-, Doku- und Betriebspakete an Claude-Agents. Seit C19 gingen alle Backend-Fachpakete mit Schwerpunkt Fachlogik (C19–C23) an Codex; die Backend-Pakete B1–B5, P1, P2, A2, D2 setzte Claude um. Ein Ausgleich auf 50 % ist ohne Rückbau fertiger Arbeit nicht möglich und wird nicht künstlich hergestellt. Die frühere Aussage „Codex 59 von 96“ (Sitzungszusammenfassung 15.10.) war falsch.
Codex-Reviews (R1: C9–C18, 12 Befunde, behoben in C19) zählen **nicht** als Umsetzung. Offen: Codex-Reviews für die Pakete B1–B5, P1/P2, A2 und die PWA ab L4.

## Etappe 1b/3c: Testumgebungen und OIDC (14.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| L10 | Testumgebungen Mailpit, Adobe S3Mock, Dex, Bind-Adressen (`docs/TESTUMGEBUNGEN.md`) | Claude-Agent | 3 | integriert; Mail-Recovery Ende-zu-Ende mit Mailpit belegt; S3Mock-/Dex-Grundfunktion belegt; Backend gegen S3Mock/Dex noch nicht | C3 |
| C14 | Optionales OIDC (ADR-0007, Vertrag v0.5.0): Backend | Claude-Agent (Codex-Limit) | 8 | integriert (Merge); 158 Tests inkl. MariaDB vom Lead nachgelaufen; Lauf gegen echtes Dex (Agent) | Vertrag v0.5.0, L10 |
| L11 | OIDC-Oberfläche (Login, Einladung, Identitäten) gegen Mock | Claude-Agent | 5 | integriert (PWA); 297 Unit, 29 Mock-E2E, 49 E2E vom Lead nachgelaufen; nur gegen Mock | Vertrag v0.5.0 |
| L12 | Echt-Integration Export/Import/Speicher/Anhänge inkl. Adobe S3Mock | Claude-Agent | 5 | integriert (PWA); 74 E2E (49+25) vom Lead nachgelaufen, S3Mock-Test lief | C11–C13 |

## Etappe 4a: Berichtsheft (15.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| C15 | Berichtsheft-Backend (ADR-0008, Vertrag v0.6.0) | Claude-Agent (Codex-Limit) | 6 | integriert (Merge); 163 Tests inkl. MariaDB, Linux-Image baut (Lead) | C13 |
| L13 | Berichtsheft-Oberfläche gegen Mock | Claude-Agent | 6 | integriert (PWA); 346 Unit, 39 Mock-E2E (Lead) | Vertrag v0.6.0 |
| L14 | Berichtsheft Echt-Integration + E2E | Claude-Agent | 4 | integriert (PWA-`main`); 347 Unit, 93 E2E vom Lead nachgelaufen | C15, L13 |
| C16 | Etappe 4b: OAuth-Server, persönliche Tokens, Grants (ADR-0009, Vertrag v0.7.0) | Claude-Agent (Codex-Limit) | 8 | integriert (Merge); mit C17 verdrahtet; 169 Tests inkl. MariaDB (Lead) | Vertrag v0.7.0 |
| C17 | Etappe 4b: MCP-Endpunkt `/mcp` + Tools (gegen abgestimmte Authenticator-Schnittstelle) | Claude-Agent (Codex-Limit) | 8 | integriert (Merge); 166 Tests inkl. MariaDB (frische DB, 2 Läufe) vom Lead; `/mcp` liefert 401, bis C16 verdrahtet ist | Vertrag v0.7.0 |
| L15 | Etappe 4b: PWA Consent, API-Tokens, Verbindungen, MCP-Hilfe gegen Mock | Claude-Agent | 5 | integriert (PWA); 384 Unit, 48 Mock-E2E vom Lead; nur gegen Mock | Vertrag v0.7.0 |
| X1 | Verdrahtung C16↔C17 (Adapter), Gesamt-E2E MCP mit Skript-Client, OAuth-Flow im Browser | Lead + Claude-Agent | 4 | integriert (PWA); 120 E2E (93+27) vom Lead nachgelaufen | C16, C17, L15 |

## Etappe 4c: Hinweise, Web Push, PWA-Installierbarkeit (15.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| C18 | Hinweise, Erinnerungs-Scheduler, Web-Push-Sender (ADR-0010, Vertrag v0.8.0) | Claude-Agent (Codex-Limit) | 8 | integriert (Merge); 177 Tests inkl. MariaDB (Lead nachgelaufen); Web-Push-Verschlüsselung gegen RFC-8291-Vektor, Zustellung nur gegen Fake-Dienst | Vertrag v0.8.0 |
| L16 | PWA: Manifest/Icons, Service Worker, Offline-Hinweis, Hinweiszentrum, Push-Einstellungen | Claude-Agent | 8 | integriert (PWA); Details im PWA-Repo | Vertrag v0.8.0 |
| X2 | E2E mit Fake-Push-Dienst, Gesamtabgleich | Claude-Agent | – | als eigenes Paket nicht ausgeführt, nicht gezählt; Push gegen Fake-Dienst wird in Backend-Tests (C18/C19) und `npm run test:e2e:pwa` (PWA) geprüft | C18, L16 |

## C19 – Review-Härtung (15.10.2026)

Codex, alleiniger Schreiber auf `c19-review-fixes` im Backend-Hauptverzeichnis. Umfang: alle zwölf Befunde
in `reviews/2026-10-15-codex-review.md`, Zahlen-/Datums-Sweep, Regressionstests und angehängte Migrationen.
Vertrag v0.8.0 unverändert. Entscheidungen: `decisions/ADR-0011-c19-review-haertung.md`.
Stand: integriert (Merge), 193 Tests inkl. MariaDB vom Lead nachgelaufen; Zwischenstände der Sandbox stehen im Handoff C19.
Details: `handoffs/C19.md`.
| C19 | Codex-Review-Fixes (12 Befunde C9–C18, Sweep nach Absturzmustern) | **Codex** | 8 | integriert (Merge); 193 Tests inkl. MariaDB vom Lead nachgelaufen | Review 15.10. |
| R1 | Codex-Adversarial-Reviews C9–C18 (3 Blöcke) | Codex (Review, nicht als Umsetzung gezählt) | – | abgeschlossen; Befunde in `docs/reviews/2026-10-15-codex-review.md` | – |
| N1 (im Auftrag „R1“ genannt) | Umbenennung der App/Oberfläche (Branch `n1-rename`) | Claude-Agent | – | **verworfen**: Anzeigename bleibt Timetrack; Chronolog nur App-Store-Eintrag (Entscheidung 17.10.2026). Nicht gezählt. Der Branch liegt nur noch als lokaler Worktree-Rest vor (enthält keine Änderungen, die nicht in `main` sind) | – |

## Etappe 4d: Modulschalter und Dokumentationsabgleich (15.10.2026)

Nutzerentscheidung 15.10.: Module abschaltbar durch Betreiber **und** je Konto (ADR-0012, Vertrag v0.9.0). Die Pakete C20, L17 und D1 stehen mit ihrem Endstatus (integriert) in der Tabelle „Etappe 4e“ weiter unten.

## B3 – Betrieb: Backup/Restore, Swarm-Stack, Gesamtprüfung (16.10.2026)

Claude-Agent im Worktree `timetrack-backend-wt/b3`, Branch `b3-ops`. Schreibt nur `scripts/`, `deploy/`, Dockerfile, Compose, Betriebsdokumentation; kein Swift-Code unter `Sources/`.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| B3 | Backup/Restore-Skripte mit Beweislauf (SQLite, MariaDB), Swarm-Stack-Vorlage, Image-Einstiegspunkt für `*_FILE`-Secrets, `scripts/check-all.sh`, amd64-Versuch, `docs/BETRIEB.md` | Claude-Agent | 6 | integriert; Lead hat den Restore-Beweis (36 Prüfungen, SQLite und MariaDB) und `check-all.sh --fast` nachgelaufen; amd64-Build unter Emulation nicht fertig geworden (nativ nötig); echter Swarm, Last, Restore auf anderem Host ungeprüft | Backlog 2 und 3 |

## B4 – Vertrauenswürdige Proxys (16.10.2026)

Claude-Agent im Worktree `timetrack-backend-wt/b4`, Branch `b4-proxy`.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| B4 | `TRUSTED_PROXY_CIDRS`/`TRUSTED_PROXY_HEADER`, zentrale Client-Adresse für alle Rate-Limits, Tests, ADR-0018, Betriebsdoku | Claude-Agent | 3 | integriert; Lead: 12 neue Tests grün, /0-Netze nachträglich abgelehnt; zwei Push-Timing-Tests (C19) schlugen bei Systemlast ~230 fehl, auch in Einzelläufen (Ursache offen, siehe STATUS); kein Test mit echtem Proxy | B3 |

## D2 – Deployment-Anleitung Produktion (17.10.2026)

Claude-Agent im eigenen Worktree, Branch `d2-deployment-guide`; integriert. Schrieb nur `deploy/`, `docs/`; kein Swift-Code, nicht `.github/` oder `site/` (Paket W1).

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| D2 | `docs/DEPLOYMENT.md` (Schritt-für-Schritt für `timetrack.example.org`), Stack ohne DB-Container mit allen Variablen, `deploy/swarm/create-secrets.sh` (`--dry-run`), Abgleich BETRIEB/deploy-README | Claude-Agent | 3 | integriert; Lead: `check-all.sh --fast` im Merge, Stack-Validierung und Skript-Trockenlauf laut Agent; nie auf echtem Swarm/Proxy/MariaDB 12.3.3 getestet; Lücke: `DB_TLS=required` ohne eigene CA | B3, B4 |

## X1 – Performance und Stabilität (17.10.2026)

Claude-Agent im eigenen Worktree (Backend und PWA), Branch `x1-perf`.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| X1 | Vorbereitete Tagesbewertung (Zeitkonto 5,9 s → 53 ms bei 800 Tagen), Fensterabfragen, Index, Lesen ohne `auth_lock`, `/ready` robust, Pool-Keep-Alive; Ursache des Fehlers beim ersten Anlegen des Arbeitsmodells; PWA-Wiederholung, Zeitkonto-Zwischenspeicher | Claude-Agent | 8 | umgesetzt, Lead-Prüfung offen (Details `docs/handoffs/X1.md`) | A, B3 |

## Backlog Backend (Stand 17.10.2026)

1. **Kontenverwaltung**: umgesetzt (B1, PWA L23). Offen: S3-Löschung nicht gegen S3Mock geprüft.
2. **Backup/Restore**: B3 integriert (`BETRIEB.md`), Restore-Beweis auf SQLite und MariaDB. Offen: Restore auf anderem Host, Beweis auf der Produktionsinstanz.
3. **Betrieb**: Stack-Vorlage, Migrationsjob, `check-all.sh`, Entrypoint (B3), Trusted-Proxy-Header (B4), Deployment-Anleitung (D2). Offen: Metriken, echter Swarm, Last, amd64-Nachweis für den aktuellen Stand.
4. **Aufräumjobs**: umgesetzt (B2, ADR-0017).
5. **Vertragstreue**: B5 integriert (Routenabgleich, Antwortformen, Redocly-Lint nicht blockierend). Offen: `operation-summary` (Lint meldet 189 Fehler, überwiegend dies), Request-Schemas und Fehlerstatus je Endpunkt, Typgenerierung für Swift-Clients.
6. **Restpunkte Review/Tests**: Lernfeld-409, `pushsubscriptionchange`, `PUSH_ALLOWED_HOSTS` (B2/L23 umgesetzt). Offen: Import mit 20 000 Zeilen und Blobs nahe 64 MiB auf MariaDB messen, `auth_lock`-Durchsatz, Linux-Testkompilierung (`XMLParser` in `ExportTests.swift` braucht `FoundationXML`; Backend-CI auf GitHub deshalb rot).
7. **Fachlich/Produkt (offen)**: IHK-Ausgabeformat, Rechtsprofile für Jugendliche, Selbstständigenfunktionen (Kunden/Projekte/Sätze), Kalenderbrücke und KI-Worker-Schnittstellen (Job-Queue), Standortautomatik auf iOS. Onboarding und Profilpflege sind umgesetzt (P1).

## B5 – Vertragstreue und Testrobustheit (16.10.2026)

Claude-Agent im Worktree `timetrack-backend-wt/b5`, Branch `b5-conformance`. Schreibt Tests, Skripte, Doku; am Vertrag nur reine Dokumentationsfehler (YAML-Quoting).

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| B5 | Contract-Tests (Routenabgleich, Antwortformen mit eigenem JSON-Schema-Validator), `scripts/contract-json.sh`, Redocly-Lint, deterministische C19-Push-Tests (Ursache: tagesabhängige `report_gap`-Erinnerung), Handoff `handoffs/B5.md` | Claude-Agent | 4 | integriert; Lead: nach Merge mit P1 (Vertrag 0.13.0, JSON-Kopie neu erzeugt) 302 Tests auf SQLite, 0 Fehler; MariaDB 295/0 und Linux-Build laut Agent; Push-Tests 20/20 stabil; Antwortformen ca. 55 Endpunkte ohne Abweichung, Anfrageschemas/MCP/OAuth/Dateien ungeprüft; Redocly: 100 Operationen ohne `summary` | Backlog 5 |

## Etappe B: Kontenverwaltung und Datenschutz (16.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| B1 | Kontenverwaltung: Admin-API (Liste, deaktivieren, Rolle, Sitzungen, löschen), `GET /me/export`, `DELETE /me`, Kaskade inkl. Dateien, Vertrag v0.11.0, ADR-0016 | Claude-Agent | 8 | integriert (Vertrag v0.11.0); 250 Tests auf SQLite vom Lead nachgelaufen, MariaDB (250) und Linux-Build laut Agent; S3-Löschung und sehr große Exporte ungeprüft (Handoff `handoffs/B1.md`); die PWA-Oberfläche folgte in L23 | – |

## Etappe 4e: Arbeitszeit-Tabelle als Import-/Exportprofil (15.10.2026)

Nutzerwunsch 15.10.: Das Tabellenformat der Beispiel-Arbeitszeittabelle (Jahresblätter, Wochenblöcke) soll Import **und** Export können (ADR-0013, Vertrag v0.10.0). Entscheidungen: „Freigestellt“ = neuer Typ `excused`; Export mit bewerteten Zeiten (Option tatsächlich).

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| C20 | Modulschalter Backend (ADR-0012) | Codex | 8 | integriert (Merge); 202 Tests inkl. MariaDB (Lead) | – |
| L17 | Modulschalter PWA + PWA-Doku + Flaky-Test-Fix | Claude-Agent | 6 | integriert (PWA); 455 Unit, 58 Mock-E2E, 128 Echt-E2E (Lead; zwei Specs an C19-Verhalten angepasst) | C20 |
| D1 | Dokumentationsabgleich Backend (README, KONZEPT, ARCHITEKTUR, UMSETZUNG, EINRICHTUNG, ADR-Index) | Claude-Agent | 3 | integriert (Merge) | – |
| C21 | `excused` durchgängig + Import-Profil `worktime_workbook` (Erkennung, Parser, Regeln, Absenzen, Rollback) | Codex | 10 | integriert (Merge „C21“; Vertrag v0.10.1 präzisiert); Belege `handoffs/C21.md` | ADR-0013 |
| C22 | Export-Profil `worktime-xlsx` (Formelschreiber mit Cache-Werten, Jahresblätter) + Round-trip-Tests | Codex | 8 | integriert (Merge „C22“); Belege `handoffs/C22.md`; Öffnen in Excel/LibreOffice weiter ungeprüft | C21 |
| L18 | PWA: excused, Import-Assistent-Zweig (Regeltabelle, nicht zugeordnete Bemerkungen), Export-Option; Modul-Echt-E2E | Claude-Agent | 8 | integriert (PWA); 488 Unit, 63 Mock-E2E, 6 PWA-Build-Specs, 138 Echt-E2E (Lead); Tabellen-Import/Export bisher nur gegen Mock | Vertrag v0.10.0 |
| L19 | Echt-E2E Import/Export Tabelle (synthetische Mappe; lokale Prüfung gegen Nutzerdatei ohne Ablage) | Claude-Agent | 4 | integriert (PWA-`main`); 156 Echt-E2E + 1 `test.fixme` (Lead nachgelaufen, einzeln stabil; bei Systemlast ~280 einzelne Timeouts) | C21, C22, L18 |

## Etappe 4f: Designsprache (15.10.2026)

Nutzerwunsch 15.10.: Gestaltung eines bereitgestellten UI-Entwurfs festhalten und übernehmen (ADR-0014, `docs/DESIGN.md`).

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| L20 | Diagnose Zeitkonto-Abweichung Tabelle ↔ App (nur Aggregatzahlen, lokal) | Claude-Agent | 3 | abgeschlossen: kein systematischer Fehler, vier Datenfälle (Feiertagszeilen, Teilgutschrift, Modellbeginn, Zeilen nach heute) | C21, C22 |
| L21 | PWA: Designsprache umsetzen (Tokens, Shell, Seitenkopf, Karten, Glas, Akzent, Barrierefreiheit) | Claude-Agent | 10 | integriert (PWA); 500 Unit, 69 Mock-E2E, 6 PWA-Build-Specs, 156 Echt-E2E vom Lead (Last ~250 verursacht einzelne Timeouts bei Gesamtläufen); Screenshots Heute/Kalender gesichtet | ADR-0014 |
| C23 | Import-Verfeinerung nach Diagnose: Feiertagszeiten verwerfen (`holidayTimes`), Teilgutschriften als Arbeit (`partialCredit`), getrennte Tabellensalden, `firstContentDate` | Codex | 6 | integriert (Merge); 231 Tests inkl. MariaDB (Lead) | L20, Nutzerentscheidung 15.10. |
| L22 | PWA-Import-Assistent für C23 (Optionen, Warnungen, Salden, Modellbeginn-Hinweis) im neuen Design | Claude-Agent | 4 | integriert (PWA; check 0 Fehler, 522 Unit, 71 Mock-E2E, 6 PWA-Build, 158 Echt-E2E; live auf der Testinstanz) | C23, L21 |

Etappe 5 (Native Apps, Repo timetrack-apple), Start 16.10.2026:

| Paket | Inhalt | Verantwortlich | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| A1 | Swift-Paket TimetrackCore (API-Client, Auth, Stores) + macOS-App (Heute, Zeit, Einstellungen, Menüleiste) | Claude-Agent | 10 | integriert (Apple); 43 Tests inkl. Integrationslauf gegen Wegwerf-Backend, macOS- und iOS-Build vom Lead nachgelaufen; Oberfläche nie gesichtet (kein Screenshot möglich) | ADR-0015 |
| A2 | Backend: `/.well-known/apple-app-site-association` (`APPLE_APP_IDS`), WebAuthn-Origin für native Apps | Claude-Agent (Branch a2-aasa) | 4 | integriert (v0.10.4); 236 Tests auf SQLite vom Lead nachgelaufen, MariaDB und Linux-Build laut Agent; echter Apple-Passkey und AASA hinter dem Proxy ungeprüft (Handoff `handoffs/A2.md`) | A1 |
| A3 | iOS/iPadOS-App (Heute, Zeit, Urlaub read-only, Einstellungen, App Intents) | Claude-Agent | 8 | integriert (Apple); 50 Package-Tests und Mac-/iOS-Build vom Lead nachgelaufen, UI-Smoke-Test auf iPhone- und iPad-Simulator laut Agent; Passkey, Intents, Echtgerät, VoiceOver, Dark Mode/Dynamic Type ungeprüft | A1, A2 |
| A4 | watchOS-App (direkt zum Server, Sitzung per WatchConnectivity vom iPhone) | Claude-Agent | 6 | integriert (Apple `Merge A4`); 59 Package-Tests und Watch-/iOS-/Mac-Build vom Lead nachgelaufen; Simulator-Lauf mit Wegwerf-Backend laut Agent (3 Screenshots); WatchConnectivity nur gegen Mock, nie auf Gerät/Simulator-Paar; Komplikation und Art-Auswahl offen | A3 |
| A5 | watchOS: Art-Auswahl, Komplikation (WidgetKit, App Group, nicht geheimer Snapshot), iPhone-Knopf „Sitzung an Uhr senden", Dynamic-Type-Korrektur iOS | Claude-Agent | 5 | integriert (Apple-Merge A5); 69 Paket-Tests und Watch-/iOS-/Mac-Build vom Lead nachgelaufen; Simulator-Screenshots laut Agent (Picker, Komplikations-Galerie, iPhone XXL dunkel); echte Komplikation auf Zifferblatt, Signierung mit App Group und Echtgerät ungeprüft | A4 |
| A6 | Native Designpass (TimetrackDesign, iOS/iPadOS/macOS/watch, App-Icon als Asset-Set) | Claude-Agent | 10 | integriert (Apple-Merge A6); 69+3 Paket-Tests und iOS-/macOS-/Watch-Build vom Lead nachgelaufen, iPhone-Screens (Heute laufend, Zeit dunkel) gesichtet; macOS nur als Hierarchie-Aufnahme, iPad/Uhr teils ungesehen | A5 |
| A6b | App-Icon im Icon-Composer-Format (`.icon`, Ebenen als SVG, ruhiger Bogen mit Zeiger in #2563EB, Hell/Dunkel/Getönt) plus 3–4 alternative Icon-Varianten, in den iOS-Einstellungen wählbar (`setAlternateIconName`); macOS: nur Standardicon (kein dauerhaftes Wechseln möglich), Uhr: nur Standard | Claude-Agent | 4 | integriert (Apple-Merge A6b); Builds iOS/macOS/watch vom Lead nachgelaufen, Primärvorschau gesichtet (wirkt wie ein Tacho), Varianten und Auswahl-Ansicht nicht gesichtet, Einbau der Auswahl in die Einstellungen nach A6 | A6 |
| A6c | App-Icon neu nach Nutzervorlage (geschlossener Ring, weiße Zeiger, dunkle Fläche) mit Akzent-Varianten Blau/Türkis/Violett/Grün/Orange/Rosa; Auswahlansicht | Claude-Agent | 4 | integriert (Apple-Merge A6c); sieben Varianten gebaut, Variante „Hell“ vom Lead gestrichen (Zeiger im Dunkelmodus kaum sichtbar); Dark/Tinted-Spezialisierungen werden von ictool/actool ignoriert (Systemableitung); Wechsel im Simulator nur für Orange gesehen | A6b |
| A6d | Native Einstellungsseite „Darstellung" (iOS/iPadOS/macOS): **App-Akzentfarbe und App-Symbol getrennt wählbar** (Nutzerentscheidung 16.10.), Erscheinungsbild System/Hell/Dunkel, Auswahlansicht aus A6c einbauen; Akzent lokal je Gerät (Synchronisation über das Konto offen) | Claude-Agent | 3 | integriert (Apple-Merge A6d); 69+11 Paket-Tests (Kontrast ≥4,5:1 über alle Presets) und drei Builds vom Lead nachgelaufen, Darstellungsseite (Orange/dunkel) gesichtet; macOS-Tab, Graphit, ColorPicker, iPad/Uhr ungesehen; Akzent nur lokal, nicht im Konto, Widgets folgen ihm noch nicht | A6, A6c |
| A7 | Widgets: iOS-Homescreen/Sperrbildschirm (interaktiv per App Intents), Live Activity, Steuerzentrale, macOS-Widgets | Claude-Agent | 8 | integriert (Apple-Merge A7); 72+11 Paket-Tests und drei Builds nach dem Merge vom Lead; Widgets/Intents/Live Activity/Control Center nur kompiliert, nur Debug-Galerie in der App gesichtet (Home/Sperrbildschirm/Live-Activity-Attrappen), macOS-Widgets ungesehen; signierter iOS-Build mit App Group und gemeinsamer Keychain-Gruppe laut Agent; Keychain-Lesen aus der Erweiterung auf dem Gerät ungeprüft | A6b |
| A8 | Native Apps: Akzent und Erscheinungsbild aus dem Konto (`/me/preferences`, ADR-0020) laden/speichern mit lokalem Cache; Akzent in den Widget-Snapshot; Abgleich nach „Vertrag für native Clients“ (docs/handoffs/P2.md) | Claude-Agent | 4 | integriert (Apple-Merge A8); 93+14 Paket-Tests und drei Builds vom Lead nachgelaufen, „Heute“ mit Konto-Akzent Orange nach Neuinstallation gesichtet; macOS-UI, Widgets/Komplikation auf dem Gerät, Offline-/Fehlerzustände der Statuszeile, Zwei-Geräte-Konflikt ungeprüft | P2, A7 |
| L23 | PWA: Konten-Verwaltung, Daten & Datenschutz (Export, Selbstlöschung), `pushsubscriptionchange` im Service Worker | Claude-Agent | 8 | integriert (PWA); check 0 Fehler, 551 Unit, 77 Mock-E2E, 6 PWA-Build (Lead), 10 neue Echt-E2E (Lead, gegen frisch gebautes Backend), Agent: 168 Echt-E2E gesamt; `reauth_required`/503 nur Mock | B1, B2 |

Backend-Wartung (Start 16.10.2026):

| Paket | Inhalt | Verantwortlich | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| B2 | Aufräumjob (Lease, CLI `maintenance`), Lernfeld-409, `pushsubscriptionchange`-Endpunkt, `PUSH_ALLOWED_HOSTS`-Vorschlag, `auth_lock`-Messung, MariaDB-READ-COMMITTED-Fix (ADR-0017, Vertrag v0.10.5) | Claude-Agent (Branch b2-cleanup) | 8 | integriert (Vertrag v0.12.0 zusammen mit B1); nach Merge 277 Tests auf SQLite und auf MariaDB vom Lead; S3Mock-Lauf und Mehr-Replikas-Betrieb ungeprüft | ADR-0011 |

## P1 – Profil und geführte Einrichtung (16.10.2026)

Claude-Agent in getrennten Worktrees je Repo, Branch `p1-profile`; integriert.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| P1 | Profilbearbeitung (Name, E-Mail per Code), Einrichtungsmerker, Vertrag v0.13.0, ADR-0019; PWA: Profilseite, Einrichtungsassistent, gruppierte Einstellungsnavigation, Mock, Unit-/Mock-/Echt-E2E | Claude-Agent | 8 | integriert (Backend Vertrag v0.13.0; PWA-Merge); Lead: PWA check 0 Fehler, 575 Unit, 81 Mock-E2E, 6 PWA-Build, Echt-E2E profile+stage1 23/23 gegen frisch gebautes Backend; Backend 296 Tests SQLite (bis auf die 2 bekannten lastempfindlichen Push-Tests grün); echte E-Mail-Zustellung ungeprüft; Live-Instanz aktualisiert | B1, C20 |


## P2 – Darstellung je Konto (16.10.2026)

Claude-Agent in getrennten Worktrees je Repo, Branch `p2-accent`; integriert. Nutzerentscheidung 16.10.2026: Akzent und Farbschema je Konto, App-Symbol bleibt Gerätewahl; die nativen Apps folgten in A8.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| P2 | `GET/PATCH /me/preferences` (Akzent, eigene Farbe, Farbschema), `account.preferences` in der Sitzung, Export `preferences.json`, Vertrag v0.14.0, ADR-0020; PWA: Darstellungsseite am Konto mit localStorage-Cache und Abgleich, Mock, Unit-/Mock-/Echt-E2E; Vertrag für native Clients in `handoffs/P2.md` | Claude-Agent | 3 | integriert (Vertrag v0.14.0, ADR-0020); Lead: Backend 305 Tests SQLite, 0 Fehler; PWA check 0 Fehler, 587 Unit, 84 Mock-E2E, Echt-E2E 180/180 gegen frisch gebautes Backend; Live-Instanz aktualisiert (alte Build-Dateien in deploy/pwa-static nicht gelöscht, nur überschrieben); native Apps in A8 angepasst | P1 |

## M1 – Arbeitsmodelle korrigieren, Urlaubskonto sichtbar (17.10.2026)

Claude-Agent in getrennten Worktrees (Branch `m1-model-edit`), nicht gemergt.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| M1 | `PUT /work-models/{id}` (Korrektur) und `POST /work-models/{id}/preview` (Zeitkonto vorher/nachher), `WorkModel.version`, Audit `work_model.updated`, Vertrag v0.16.0, ADR-0004-Nachtrag; PWA: Bearbeiten mit zwei Modi, Warnung, Vorschau, Bestätigung; Urlaubskonto-Karte mit Handlungsaufforderung | Claude-Agent | 6 | fertig, Lead-Prüfung offen | X1, P1 |

## W1 – GitHub Actions und Pages (17.10.2026)

Claude-Agent in getrennten Worktrees je Repo (Branches `w1-ci-pages`, `w1-ci`); integriert. Parallel schrieb D2 `deploy/swarm/*`, `docs/DEPLOYMENT.md`, `docs/BETRIEB.md`.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| W1 | Workflows (CI, Docker multi-arch, Pages, Release, CodeQL, Dependency Review, Dependabot), Vorlagen, `SECURITY.md`, `CODEOWNERS` in allen drei Repos; Website `site/` (VitePress, Landingpage, Doku aus Repo-Dokumenten, API-Referenz); `docs/CI.md` | Claude-Agent | 5 | integriert (alle drei Repos); actionlint ohne Befund (Lead), Stand 17.10. nach der Veröffentlichung: Workflows laufen auf GitHub (Pages und CodeQL grün; Backend-CI rot wegen Linux-Testkompilierung, Apple-CI rot, siehe `STATUS.md`); Seite lokal gebaut und gesichtet (Agent) | – |

## D3 – Dokumentationsabgleich (17.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| D3 | Abgleich aller Dokumente in den drei Repos mit dem tatsächlichen Stand (STATUS, ARBEITSPLAN, UMSETZUNG, READMEs, Agent-Einstiege, LIZENZEN, Links, Personenbezug) | Claude-Agent | – (nicht gezählt, keine Punktschätzung) | integriert; Belege und Unsicherheiten `handoffs/D3.md`; Zahlen nicht neu gemessen | W1, D2 |

## D4 – PWA im Image, Stack ohne Volumes (17.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| D4 | Dockerfile baut die PWA (Build-Kontext `pwa-src`), Docker-Workflow mit zweitem Checkout, Smoke-Test `EXPECT_PWA`, Stack ohne Volumes und Knotenbindung, Dokumentation | Claude-Agent | – (nicht gezählt) | umgesetzt, Lead-Prüfung offen; Belege `handoffs/D4.md` | D2, W1 |

## Veröffentlichung und Historienbereinigung (17.10.2026)

Am 17.10.2026 wurden die drei Repositories öffentlich auf GitHub veröffentlicht. Vorher wurde die Git-Historie aller drei Repos von persönlichen Angaben bereinigt (umgeschrieben); dabei änderten sich alle Commit-Hashes. Die unbereinigten Originale liegen als lokale Sicherungen außerhalb der Repos (Verzeichnisse `_old-repos/` und `_repo-backups-before-scrub/` neben den Arbeitsordnern; das Austauschskript liegt in `_publish/`). Sie dürfen nie in ein öffentliches Repo gelangen. Seither laufen die Workflows (W1) auf GitHub; Dependabot-Pull-Requests sind offen. Zugehörige Folgeänderungen: Platzhalter statt persönlicher Domain/Kennungen im Backend-Repo (`docs/README.md`, Abschnitt „Namensgebung und Kennungen“), Vereinfachung der Website-Schwärzungsprüfungen (`492acdc`, nach der Bereinigung), TestFlight-Skript im Apple-Repo.
Zusammenarbeit durch Dritte (Pull Requests, Issues) ist über die GitHub-Vorlagen vorbereitet, aber nicht erprobt.

## Roadmap nach Release v0.1.0 (Nutzerentscheidungen 17.10.2026)

**Betrieb des Nutzers:** Produktion läuft als Cluster aus **2 Replikaten** hinter einem Reverse Proxy mit **Sticky Sessions**. Die Ratenbegrenzung und Sitzungen liegen in der Datenbank (kein Sticky-Zwang für die Korrektheit); `TRUSTED_PROXY_CIDRS` muss das Netz der Proxy-Verbindungen enthalten.

**Reihenfolge und Umfang** (Kernfunktionen aus `KONZEPT.md`, außer IHK-Format und Selbstständigenfunktionen, die zurückgestellt sind):

| ID | Paket | Status |
| --- | --- | --- |
| K1 | Wochenplanung (Plan mit Beginn/Ende) und Wochenübersicht, Backend + PWA | integriert (Vertrag 0.17.0); Backend 315 Tests SQLite, PWA 692 Unit + Echt-E2E 186 vom Lead |
| REL | Release v0.1.0 (Changelog, Tag in allen drei Repos, Docker-Image 0.1.0) | wartet auf stabile Produktion und K1 |
| A12 | Apple Watch: schneller Start (Snapshot zuerst), eigenständig (Sitzung, Offline-Warteschlange, Hintergrundaktualisierung) | integriert (Apple-Merge A12); 141+22 Paket-Tests und drei Builds vom Lead; Kaltstart-Ziel 2,5 s verfehlt (2,9 s, ein Lauf); Anmeldung auf der Uhr ohne iPhone nicht möglich (watchOS), Gerätekopplung im Backend wäre nötig; echte Uhr ungeprüft |
| S1 | Sicherheit und Vertragsqualität: `summary` je Operation, Authentifizierung nur einmal pro Anfrage, Pool-Zeitlimit als 503 mit `Retry-After`, Lizenzprüfung vor Release (BoringSSL) | S1a und S1b umgesetzt (Lead-Prüfung offen); Lizenzbeilage im Image siehe L3; BoringSSL-Klärung weiter offen (Entscheidung Rechteinhaber) |
| N1 | Native Apps auf PWA-Stand: Wochenplanung/-übersicht (K1), Arbeitsmodell bearbeiten und Urlaubskarte (M1), acht neue Akzente und Leuchteffekt (G1), Haptik-Schalter für Uhr/Mac | geplant (nach K1) |
| F2 | Fokus-Filter (iOS `SetFocusFilterIntent`, Modi aus/Vorschlag/direkt wie bei der Standortautomatik) zusammen mit Wochenplan und -übersicht im nächsten Release | geplant |
| LA1 | Live Activity (iPhone, Uhr/Smart Stack) überarbeiten: geplante Feierabendzeit, Fortschritt „wie viel schon rum", Knopf **Pause/Weiter** (Pause = Timer anhalten, Lücke bleibt echte Pause, nichts erfundenes) und Stopp | geplant (nach K1, nutzt Plan-Endpunkte) |
| L1' | Standortautomatik: in-App energiesparend (Signifikante Standortänderung und Regionenüberwachung, nie minütliches Abfragen) **und** über Kurzbefehle (Ankunft/Verlassen als Automation, App Intents), in der App „Kurzbefehl erstellen" wo die Plattform es erlaubt; Modi pro Ort direkt/Vorschlag/aus, Vorbeifahrt wird nicht gebucht | geplant (größeres Paket, Abstimmung nötig) |
| E1 | Kalenderbrücke nur nativ (EventKit, ohne App-Passwort), Standard lesen | geplant |
| AI1 | KI-Entwürfe fürs Berichtsheft (bearbeitbar, nichts erfunden): **in der App nur über Apple Foundation Models und nur auf unterstützten Geräten**; zusätzlich nutzen ChatGPT/Claude den vorhandenen MCP-Zugang (getrennt vom App-Login) | geplant |
| R2 | Rechtsprofile für Jugendliche (Pausen/Zeitgrenzen) | geplant |
| Q1 | Codex-Reviews (Kontingent nur noch ~6 %: gezielt, `gpt-6-sol`, Aufwand mittel) für sicherheitsrelevante Pakete (B1 Konten, A2/OAuth, B4 Proxys) | geplant |
| M2 | Mac-App: Vorbereitung dort, wo es sich anbietet; sonst hinten angestellt (nichts vor 19.10. 8 Uhr) | zurückgestellt |
| CI | Apple-CI auf dem gehosteten Image `xcode-27` (GitHub, seit 15.10.2026 allgemein verfügbar) | umgesetzt (17.10.); Lauf offen |

Zurückgestellt (auf Nutzerwunsch): IHK-Berichtsheft-Format, Selbstständigenfunktionen.

Entscheidungen (17.10.2026, Nachtrag): **Pause** = normale Pause (Timer anhalten, Lücke bleibt Pause, kein eigener Typ). **Fokus-Filter** wie vorgeschlagen (Modus aus/Vorschlag/direkt plus Art), muss am Ende selbsterklärend sein. Das Claude-Kontingent muss nicht mehr geschont werden (Klärung des Nutzers, 18.10.); nur die Mac-App ruht.

## K1 – Wochenplanung und Wochenübersicht (17.10.2026)

Claude-Agent in getrennten Worktrees (Branches `k1-week`), nicht gemergt.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| K1 | Geplante Zeiten am Plantag, `GET/PUT /plan/weeks/{isoWeek}`, `GET /time/weeks/{isoWeek}`, Vertrag v0.17.0, ADR-0021; PWA: „Woche“ mit Übersicht (Tageskarten, Summen, Icons) und Planer (Schnellaktionen, Speichern, Schutz vor Verlassen); Details `docs/handoffs/K1.md` | Claude-Agent | 8 | umgesetzt, Lead-Prüfung offen | X1, M1 |

## MAIL1 – E-Mail-Prüfung in den Servereinstellungen (17.10.2026)

Claude-Agent in getrennten Worktrees (Branches `mail1-smtp-check`), nicht gemergt.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| MAIL1 | `GET /admin/mail`, `POST /admin/mail/check` (Live-Diagnose DNS/TCP/TLS/EHLO/Anmeldung/Absender ohne Nachricht), `POST /admin/mail/test` (feste Testmail, frische Sitzung), Vertrag v0.18.0, ADR-0022; PWA: Seite `/admin/mail` mit Statuskarte, Schrittanzeige, Testmail; Details `docs/handoffs/MAIL1.md` | Claude-Agent | 6 | integriert (Backend 323 Tests SQLite, PWA 708 Unit, 188 Echt-E2E vom Lead) | B1, P1, K1 |

## V1 und L2 (18.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| V1 | Versions- und Build-Angaben: `GET /api/v1/system/info`, `/health` mit Version/Revision, Build-Argumente in Dockerfile und Workflow, Vertrag v0.19.0, ADR-0023; PWA: Abschnitt „Version und Build“ im Hilfedialog, `version.json`, Abweichungshinweis; Details `docs/handoffs/V1.md` | Claude-Agent | 6 | integriert; Backend 327 Tests (SQLite und MariaDB), PWA 716 Unit, 189 Echt-E2E (Agent); Workflow auf GitHub noch zu beobachten | MAIL1 |
| L2 | Standortautomatik iOS (Apple-Repo): `CLMonitor`-Regionen, Verweilzeit-/Geschwindigkeitsfilter, Warteschlange, Geräte-Token, App Intents, Einstellungsseite, Kurzbefehl-Anleitung; Details `handoffs/L2.md` im Apple-Repo | Claude-Agent | 10 | integriert; Core 209 Tests, UI-Test gegen Wegwerf-Backend; echte Regionsereignisse und Hintergrund nur auf dem Gerät prüfbar (Testplan im Handoff) | A12, F2 |

## S1a (18.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| S1a | Teil von S1: Datenbankausfall als 503 `database_unavailable` mit `Retry-After` (Klassifizierung in `APIErrorMiddleware`), Vertrag v0.20.0, ADR-0024; Details `docs/handoffs/S1a.md` | Claude-Agent | 2 | Branch `S1a`, Lead-Prüfung offen; 331 Tests SQLite und MariaDB ohne Fehler | V1 |

## S1b (19.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| S1b | Rest von S1: Q1-Befunde (`system/info` nur Administratoren, SMTP-Diagnose ohne Serverantwort, OIDC-Transportfehler, `X-Real-IP`-Doku/Warnung), `summary` je Operation mit Vertragstest, Anmeldung einmal pro Anfrage (Request-Speicher, lesende Dienste ohne zweite Prüfung), Lizenzkette BoringSSL; Vertrag v0.23.0; Details `docs/handoffs/S1b.md` | Claude-Agent | 4 | Branch `worktree-agent-aecf20448f928398e`, Lead-Prüfung offen; 353 Tests SQLite und MariaDB ohne Fehler; PWA-Anpassung offen | S1a |
| B6 | Anhangzahl `Absence.attachmentCount`, Filter `hasAttachment`, `?disposition=inline` für sichere Vorschautypen; Vertrag v0.24.0; Details `docs/handoffs/B6.md` | Claude-Agent | 2 | Branch `worktree-agent-a0c3a2218a5ea8324`, Lead-Prüfung offen; 354 Tests SQLite und MariaDB ohne Fehler; PWA-Anpassung offen | S1b |
| B7 | Vorlage für den Urlaubsantrag je Konto (PDF und Zuordnung, Speicherregeln, Export, Löschung); Vertrag v0.25.0; Details `docs/handoffs/B7.md` | Claude-Agent | 2 | Branch `worktree-agent-a5d512514485f6486`, Lead-Prüfung offen | B6, P6 |
| W1 | (A) Abgang beendet auch manuell gestartete Timer; (B) Auslöse-Links `GET /t/<token>/start\|stop\|toggle` mit Verwaltung `/me/trigger-links`; Vertrag v0.26.0, ADR-0027; Details `docs/handoffs/W1.md` | Claude-Agent | 3 | Branch `worktree-agent-a96dfb882f965b00e`, Lead-Prüfung offen; PWA-Verwaltungsansicht offen | Backlog |

## L3 (19.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| L3 | Lizenz-Compliance: OpenSSL-Altlizenz in CNIOBoringSSL eingegrenzt (Upstream-`main` bereits Apache-2.0), Entwurf `LICENSE-EXCEPTION.md` (AGPL §7, Vorschlag), `scripts/third-party-notices.sh`, `THIRD-PARTY-NOTICES` im Image und als Release-Asset, XKCP und Betriebssystempakete inventarisiert, Inventar und Release-Checkliste erneuert; Details `docs/handoffs/L3.md` | Claude-Agent | 4 | Branch `worktree-agent-a2e7ef0107420bdfe`, Lead-Prüfung offen; Entscheidung des Rechteinhabers zur Ausnahme offen | S1b |

## Q1 – Codex-Sicherheitsreview Backend (18.10.2026)

Codex (Modell `gpt-6-sol`, Aufwand medium, nur lesend, Codex-Auftrag Q1) hat Anmeldewege, Kontentrennung, Mail-Diagnose, `system/info`, Fehlerklassifizierung und Proxy-Header geprüft. Kein kontenübergreifender Zugriff gefunden. Befunde, die in S1 einfließen:

1. (mittel, plausibel) `X-Real-IP` wird bei vertrauenswürdigem Peer ungeprüft übernommen: Der Proxy muss den Header überschreiben; in `docs/installation/proxy.md` und bei `TRUSTED_PROXY_HEADER` dokumentieren.
2. (niedrig, bestätigt) `/system/info` zeigt normalen Konten Hostname, Datenbanktreiber, Migrationsstand und Laufzeit: Betriebsfelder nur für Administratoren, Versionsfelder für alle (ADR-0023 anpassen).
3. (niedrig, plausibel) SMTP-Diagnose gibt nach der Anmeldung rohen Serverantworttext von `MAIL FROM` zurück: Text weglassen oder Zugangsdaten schwärzen.
4. (niedrig, plausibel) `InfrastructureError` klassifiziert allgemeine NIO-Fehler als Datenbankausfall: an der Datenbankgrenze klassifizieren.
