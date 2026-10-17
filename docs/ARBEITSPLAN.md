# Arbeitsplan und Agent-Übergabe

Stand: 15.10.2026. Etappen 1–4c integriert, 4d (Modulschalter) offen; Zuweisung gemäß ADR-0003.
Gewichte unten sind ein Startvorschlag, vor Zuweisung nach technischem Durchstich anpassen.
Abnahmebedingungen: `UMSETZUNG.md`. Vorgehen: `ENTWICKLUNGSABLAUF.md`.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| P0 | Voraussetzungen, Git, API-Vertrag (`contracts/openapi.yaml`, ADR-0003), Zuweisung | Claude-Lead | – | integriert | keine |
| C1 | Swift-Konfiguration, MariaDB/SQLite, Migrationen, Modelle, /ready, DB-Testbasis | Codex | 5 | integriert (`f643f0d`) | P0 |
| C2 | Einladung/Konten, Sitzung/CSRF, WebAuthn, Recovery, Admin-API, statische PWA, Integrationstests | Codex | 8 | integriert (`c65c612`) | C1 |
| C3 | SMTP-Sender (STARTTLS/implicit, AUTH) für E-Mail-Recovery | Codex | 3 | integriert (`2d57c11`), nur gegen Fake-Server getestet | C2 |
| C4 | Lizenzinventar Swift + npm (`docs/LIZENZEN.md`) | Codex | 1 | integriert (`2d57c11`) | – |
| L1 | Svelte-Oberfläche Auth/Passkeys/Recovery/Einladungen (Repo timetrack-pwa) | Claude-Agent | 8 | integriert (PWA `1cd79e0`) | P0 |
| L2 | Dockerfile, Compose dev, MariaDB-Dev, Skripte | Claude-Agent | 3 | integriert (`d78bb0a`) | P0 |
| L3a | Image-Builds arm64/amd64, Container-Läufe | Claude-Agent | 2 | integriert (`77578c3`); arm64 belegt, amd64 emuliert belegt (SQLite) | L2, C2 |
| L3b | Browser-E2E (Playwright, virtueller Passkey) gegen echtes Backend | Claude-Agent | 3 | integriert (PWA `97b9b93`), 15/15 vom Lead nachgelaufen | C2, L1 |
| C5 | Etappe 2: reine Zeit-Engine `TimeEngine` (ADR-0004) mit Tests | Codex | 5 | integriert (`f5e4936`); 49 Tests, 0 Fehler (Lead nachgelaufen), 18 neue Engine-Tests | ADR-0004 |
| C6 | Etappe 2: Persistenz, Migrationen, REST, Automation (Geräte-Token) | Codex | 8 | integriert; 61 Tests, 0 Fehler inkl. MariaDB 12.3.3 (Lead nachgelaufen) | C5 |
| L4 | Etappe 2: PWA Zeiterfassung/Modelle/Orte/Vorschläge gegen Mock | Claude-Agent | 8 | integriert (PWA-Repo `main`); 101 Unit- + 6 Mock-E2E-Tests vom Lead nachgelaufen; nur gegen Mock | Vertrag v0.2.0 |
| L5 | Etappe 2: Shortcuts-Anleitung, Echt-Integration, E2E | Claude-Agent | 4 | integriert (PWA `b8b1b71`); 29 E2E gegen echtes Backend vom Lead nachgelaufen | C6, L4 |
| C7 | Review-Fixes: Automation-Besuchsgrenze, Modellwechsel-Zuordnung (Codex-Review-Befunde) | Codex | 2 | integriert; 64 Tests, 0 Fehler inkl. MariaDB; 3 Regressionstests | C6 |
| P3 | Etappe 3: Vertrag v0.3.0 + Paketschnitt (ADR-0005) | Claude-Lead | – | integriert (Vertrag v0.3.0, ADR-0005 Fachregeln) | Nutzerantworten 14.10. erfasst |
| C8 | Etappe 3a: Feiertage (DE, 16 Länder), Urlaubs-/Abwesenheits-Engine, Tageseffekte (pure) | Codex | 5 | integriert; 78 Tests, 0 Fehler inkl. MariaDB (Lead nachgelaufen); Codex arbeitet jetzt im Hauptordner (Worktrees für Codex nicht beschreibbar) | P3 |
| C9 | Etappe 3a: Persistenz/REST Urlaub, Abwesenheiten, Kalender, Planung, Freigaben | Claude-Agent (Ersatz für Codex) | 8 | integriert (`4ca5765`/Merge); 81 Tests, 0 Fehler inkl. MariaDB (Lead nachgelaufen); Claude-Umsetzung wegen Codex-Limit (bis 20.10.), Nutzerentscheidung 14.10. | C8 |
| L6 | Etappe 3a: PWA Urlaub/Kalender/Planung/Freigaben gegen Mock | Claude-Agent | 8 | integriert (PWA `14f46db`); 158 Unit, 13 Mock-E2E, 29 E2E vom Lead nachgelaufen | P3 |
| L7 | Etappe 3a: Echt-Integration + E2E | Claude-Agent | 3 | offen | C9, L6 |
| C10 | Review-Fixes C9 (Überlauf-Absturz, Modellende, Buß- und Bettag, Kleinigkeiten) | Claude-Agent | 2 | integriert; 86 Tests inkl. MariaDB, 49 E2E vom Lead nachgelaufen | C9 |
| L7b | Etappe 3a: Echt-Integration E2E (20 neue Specs) | Claude-Agent | 3 | integriert (PWA `5e242a3`); 49 E2E zweimal vom Lead nachgelaufen | C9, L7a |
| C11 | Etappe 3b: Export XLSX/PDF/CSV (eigene Writer, ADR-0006) | Claude-Agent (Codex-Limit) | 5 | integriert (`028f8ff`); 96→111 Tests inkl. MariaDB (Lead) | Vertrag v0.4.0 |
| C12 | Etappe 3b: Import CSV/XLSX mit Vorschau, Commit, Rollback | Claude-Agent (Codex-Limit) | 8 | integriert (`4f71fb6`); 111 Tests inkl. MariaDB (Lead) | Vertrag v0.4.0 |
| C13 | Etappe 3b: Dateispeicher DB/S3/lokal, Admin-Regeln, Anhänge | Claude-Agent (Codex-Limit) | 8 | integriert (`e7ec0f9`/Merge); 127 Tests inkl. MariaDB vom Lead nachgelaufen; S3 nur gegen In-Process-Fake geprüft (S3Mock-Lauf offen) | Vertrag v0.4.0 |
| L9 | Etappe 3b: PWA Export/Import/Speicher/Anhänge gegen Mock | Claude-Agent | 8 | integriert (PWA-Repo `main`); 262 Unit, 23 Mock-E2E, 49 E2E vom Lead nachgelaufen; nur gegen Mock | Vertrag v0.4.0 |

Umfang gesamt 36 Punkte: Codex 17 (47 %: C1 5, C2 8, C3 3, C4 1), Claude 19 (53 %: L1 8, L2 3, L3a 2, L3b 3, Lead-Verträge/Integration nicht gezählt).
Alle Pakete integriert; Belege je Paket in `docs/handoffs/` (Backend) bzw. PWA-Repo. Der Codex-Anteil besteht aus
eigenständig implementierten Features und Tests, nicht aus Reviews. Reviews (getrennt): Claude hat C1–C4 gelesen und
Tests selbst ausgeführt; Codex hat bisher keine Claude-Pakete geprüft – **offen** (Vorschlag: `/codex:adversarial-review` für L1/L3b und Dockerfile).
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

## Punktebilanz und Abweichung vom 50-%-Ziel (Stand 15.10.2026, Lead-Nachrechnung)

Summe der Paketpunkte (Schätzwerte, Umsetzung ohne Reviews/Koordination), Stand nach C22, ohne L19:

| Seite | Pakete | Punkte |
| --- | --- | --- |
| Codex | C1 5, C2 8, C3 3, C4 1, C5 5, C6 8, C7 2, C8 5, C19 8, C20 8, C21 10, C22 8 | **71** |
| Claude-Agents | L1 8, L2 3, L3a 2, L3b 3, L4 8, L5 4, L6 8, L7a 2, L7b 3, C9 8, C10 2, C11 5, C12 8, C13 8, L9 8, L10 3, C14 8, L11 5, L12 5, C15 6, L13 6, L14 4, C16 8, C17 8, L15 5, X1 4, C18 8, L16 8, L17 6, D1 3, L18 8 | **175** |

**Codex-Anteil gesamt: 71 von 246 Punkten ≈ 29 % – unter dem Richtwert 40–60 %.** Ursache: Das Codex-Kontingent war vom 14.10. (nach C8) bis 15.10. erschöpft; C9–C18 (Backend-Fachpakete) setzten auf Nutzerentscheidung Claude-Agents um. Eine frühere Aussage „Codex 59 von 96“ in der Sitzungszusammenfassung vom 15.10. war falsch (Teilsumme ohne die Claude-Pakete ab C9 und ohne Oberflächenpakete).
Codex-Reviews (R1: Adversarial-Review von C9–C18, 12 Befunde, behoben in C19) zählen **nicht** als Umsetzung, ergänzen aber die gegenseitige Prüfung. Gegenmaßnahme: Backend-Fachpakete gehen ab jetzt vorrangig an Codex (C19–C22 ausnahmslos Codex); Oberflächen-, E2E-, Doku- und Umgebungspakete bleiben bei Claude-Agents, weil Codex nur im Backend-Hauptordner schreiben darf. Nachgelagerte Pakete sollen den Anteil Richtung 40 % führen; ein Ausgleich auf 50 % ist ohne Rückbau fertiger Arbeit nicht möglich und wird nicht künstlich hergestellt.

## Etappe 1b/3c: Testumgebungen und OIDC (14.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| L10 | Testumgebungen Mailpit, Adobe S3Mock, Dex, Bind-Adressen (`docs/TESTUMGEBUNGEN.md`) | Claude-Agent | 3 | integriert (`19d5f03`); Mail-Recovery Ende-zu-Ende mit Mailpit belegt; S3Mock-/Dex-Grundfunktion belegt; Backend gegen S3Mock/Dex noch nicht | C3 |
| C14 | Optionales OIDC (ADR-0007, Vertrag v0.5.0): Backend | Claude-Agent (Codex-Limit) | 8 | integriert (Merge `fa29acb`); 158 Tests inkl. MariaDB vom Lead nachgelaufen; Lauf gegen echtes Dex (Agent) | Vertrag v0.5.0, L10 |
| L11 | OIDC-Oberfläche (Login, Einladung, Identitäten) gegen Mock | Claude-Agent | 5 | integriert (PWA `b03aa6c`); 297 Unit, 29 Mock-E2E, 49 E2E vom Lead nachgelaufen; nur gegen Mock | Vertrag v0.5.0 |
| L12 | Echt-Integration Export/Import/Speicher/Anhänge inkl. Adobe S3Mock | Claude-Agent | 5 | integriert (PWA `72974f3`); 74 E2E (49+25) vom Lead nachgelaufen, S3Mock-Test lief | C11–C13 |

## Etappe 4a: Berichtsheft (15.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| C15 | Berichtsheft-Backend (ADR-0008, Vertrag v0.6.0) | Claude-Agent (Codex-Limit) | 6 | integriert (Merge); 163 Tests inkl. MariaDB, Linux-Image baut (Lead) | C13 |
| L13 | Berichtsheft-Oberfläche gegen Mock | Claude-Agent | 6 | integriert (PWA `0cab9aa`); 346 Unit, 39 Mock-E2E (Lead) | Vertrag v0.6.0 |
| L14 | Berichtsheft Echt-Integration + E2E | Claude-Agent | 4 | integriert (PWA-`main`, Merge `bae5a91`); 347 Unit, 93 E2E vom Lead nachgelaufen | C15, L13 |
| C16 | Etappe 4b: OAuth-Server, persönliche Tokens, Grants (ADR-0009, Vertrag v0.7.0) | Claude-Agent (Codex-Limit) | 8 | integriert (Merge `f17e43e`); mit C17 verdrahtet; 169 Tests inkl. MariaDB (Lead) | Vertrag v0.7.0 |
| C17 | Etappe 4b: MCP-Endpunkt `/mcp` + Tools (gegen abgestimmte Authenticator-Schnittstelle) | Claude-Agent (Codex-Limit) | 8 | integriert (Merge); 166 Tests inkl. MariaDB (frische DB, 2 Läufe) vom Lead; `/mcp` liefert 401, bis C16 verdrahtet ist | Vertrag v0.7.0 |
| L15 | Etappe 4b: PWA Consent, API-Tokens, Verbindungen, MCP-Hilfe gegen Mock | Claude-Agent | 5 | integriert (PWA `46019ba`); 384 Unit, 48 Mock-E2E vom Lead; nur gegen Mock | Vertrag v0.7.0 |
| X1 | Verdrahtung C16↔C17 (Adapter), Gesamt-E2E MCP mit Skript-Client, OAuth-Flow im Browser | Lead + Claude-Agent | 4 | integriert (PWA `4fe690b`); 120 E2E (93+27) vom Lead nachgelaufen | C16, C17, L15 |

## Etappe 4c: Hinweise, Web Push, PWA-Installierbarkeit (15.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| C18 | Hinweise, Erinnerungs-Scheduler, Web-Push-Sender (ADR-0010, Vertrag v0.8.0) | Claude-Agent (Codex-Limit) | 8 | integriert (Merge); 177 Tests inkl. MariaDB (Lead nachgelaufen); Web-Push-Verschlüsselung gegen RFC-8291-Vektor, Zustellung nur gegen Fake-Dienst | Vertrag v0.8.0 |
| L16 | PWA: Manifest/Icons, Service Worker, Offline-Hinweis, Hinweiszentrum, Push-Einstellungen | Claude-Agent | 8 | integriert (PWA-Merge `feff194`); Details im PWA-Repo | Vertrag v0.8.0 |
| X2 | E2E mit Fake-Push-Dienst, Gesamtabgleich | Claude-Agent | 3 | offen | C18, L16 |

## C19 – Review-Härtung (15.10.2026)

Codex, alleiniger Schreiber auf `c19-review-fixes` im Backend-Hauptverzeichnis. Umfang: alle zwölf Befunde
in `reviews/2026-10-15-codex-review.md`, Zahlen-/Datums-Sweep, Regressionstests und angehängte Migrationen.
Vertrag v0.8.0 unverändert. Entscheidungen: `decisions/ADR-0011-c19-review-haertung.md`.
Stand: integriert (Merge `94bfb1e`), 193 Tests inkl. MariaDB vom Lead nachgelaufen; Zwischenstände der Sandbox stehen im Handoff C19.
Details: `handoffs/C19.md`.
| C19 | Codex-Review-Fixes (12 Befunde C9–C18, Sweep nach Absturzmustern) | **Codex** | 8 | integriert (Merge); 193 Tests inkl. MariaDB vom Lead nachgelaufen | Review 15.10. |
| R1 | Codex-Adversarial-Reviews C9–C18 (3 Blöcke) | Codex (Review, nicht als Umsetzung gezählt) | – | abgeschlossen; Befunde in `docs/reviews/2026-10-15-codex-review.md` | – |

## Etappe 4d: Modulschalter und Dokumentationsabgleich (15.10.2026)

Nutzerentscheidung 15.10.: Module abschaltbar durch Betreiber **und** je Konto (ADR-0012, Vertrag v0.9.0).

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| C20 | Modulschalter Backend: Guard, Server-/Konto-Einstellungen, Admin-API, Hinweis-/MCP-/Automationsanbindung, Tests | Codex | 8 | offen | ADR-0012 |
| L17 | PWA: Module ausblenden, Einstellungen (Konto), Admin-Seite, Erklärtexte; PWA-Doku (README/STATUS) aktualisieren | Claude-Agent | 6 | offen | Vertrag v0.9.0 |
| D1 | Dokumentationsabgleich Backend-Repo (README, KONZEPT, ARCHITEKTUR, UMSETZUNG, EINRICHTUNG, REPOSITORIES, deploy, LIZENZEN, ADR-Index) | Claude-Agent | 3 | offen | – |

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

## Backlog Backend (Stand 15.10.2026, nicht begonnen)

1. **Kontenverwaltung** (umgesetzt und integriert: B1): Admin-Liste der Konten, Deaktivieren/Reaktivieren, Rollenwechsel, Sitzungen widerrufen, Konto löschen; Selbstauskunft/Selbstlöschung und Export der eigenen Daten (ZIP aus JSON/CSV + Dateien).
2. **Backup/Restore** (B3 integriert, `BETRIEB.md`): dokumentiertes und getestetes Verfahren (DB + Dateien + `STORAGE_SECRET_KEY`), Restore-Test auf MariaDB und SQLite; ARCHITEKTUR verlangt gemeinsames Restore.
3. **Betrieb** (B3: Stack-Vorlage, Migrationsjob, `check-all.sh`, Entrypoint umgesetzt; Trusted-Proxy-Header: B4 umgesetzt, Lead-Prüfung offen; Metriken offen): produktionsnahes Compose/Swarm-Stack (bisher nur Dev-Compose), expliziter Migrationsschritt, Healthchecks/Logging/Metriken, vertrauenswürdige Proxy-Header für Client-IP (Rate-Limits), amd64-Nachweis für den aktuellen Stand, CI-Skript `scripts/check-all.sh`.
4. **Aufräumjobs** (umgesetzt und integriert: B2, ADR-0017): abgelaufene Sitzungen/Challenges/OAuth-/OIDC-States/Codes/Tokens, `rate_limit_events`, `mcp_audit`-Retention, hängende Import-Jobs, Speicher-Cleanup periodisch (bisher nur nach DELETE).
5. **Vertragstreue** (B5 umgesetzt, Lead-Prüfung offen): Routenabgleich und Antwortformen-Tests gegen `contracts/openapi.yaml` (Swift, Standardlauf), Redocly-Lint und Typgenerierung (`openapi-typescript`) geprüft; offen: Lint-Regel `operation-summary` (100 Operationen ohne `summary`), Request-Schemas und Fehlerstatus je Endpunkt nicht abgeglichen, Typgenerierung für Swift-Clients nicht ausprobiert (kein Generator verfügbar).
6. **Restpunkte Review/Tests** (B2 umgesetzt, Lead-Prüfung offen: Lernfeld-409, `pushsubscriptionchange`, `PUSH_ALLOWED_HOSTS`-Vorschlag, `auth_lock`-Bewertung samt MariaDB-Isolationsfix; Import mit 20 000 Zeilen/Blobs nahe 64 MiB weiter offen): gleichzeitiges Anlegen desselben Lernfelds liefert 500 statt 409; `pushsubscriptionchange`; weitere Push-Dienste (`PUSH_ALLOWED_HOSTS`); Import mit 20 000 Zeilen und Blobs nahe 64 MiB auf MariaDB messen; globale `auth_lock`-Serialisierung bewerten.
7. **Fachlich/Produkt**: IHK-Ausgabeformat, Rechtsprofile (Jugendliche), Onboarding (Ausbildungsstichtag, Pausenfenster), Profilpflege (Anzeigename, E-Mail), Selbstständigenfunktionen (Kunden/Projekte/Sätze), Kalenderbrücke und KI-Worker-Schnittstellen (Job-Queue) für Etappe 5/6.

## B5 – Vertragstreue und Testrobustheit (16.10.2026)

Claude-Agent im Worktree `timetrack-backend-wt/b5`, Branch `b5-conformance`. Schreibt Tests, Skripte, Doku; am Vertrag nur reine Dokumentationsfehler (YAML-Quoting).

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| B5 | Contract-Tests (Routenabgleich, Antwortformen mit eigenem JSON-Schema-Validator), `scripts/contract-json.sh`, Redocly-Lint, deterministische C19-Push-Tests (Ursache: tagesabhängige `report_gap`-Erinnerung), Handoff `handoffs/B5.md` | Claude-Agent | 4 | integriert; Lead: nach Merge mit P1 (Vertrag 0.13.0, JSON-Kopie neu erzeugt) 302 Tests auf SQLite, 0 Fehler; MariaDB 295/0 und Linux-Build laut Agent; Push-Tests 20/20 stabil; Antwortformen ca. 55 Endpunkte ohne Abweichung, Anfrageschemas/MCP/OAuth/Dateien ungeprüft; Redocly: 100 Operationen ohne `summary` | Backlog 5 |

## Etappe B: Kontenverwaltung und Datenschutz (16.10.2026)

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| B1 | Kontenverwaltung: Admin-API (Liste, deaktivieren, Rolle, Sitzungen, löschen), `GET /me/export`, `DELETE /me`, Kaskade inkl. Dateien, Vertrag v0.11.0, ADR-0016 | Claude-Agent | 8 | integriert (Vertrag v0.11.0); 250 Tests auf SQLite vom Lead nachgelaufen, MariaDB (250) und Linux-Build laut Agent; S3-Löschung, sehr große Exporte und PWA-Oberfläche ungeprüft/offen (Branch `b1-accounts`, nicht gemerged; Handoff `handoffs/B1.md`) | – |

## Etappe 4e: Arbeitszeit-Tabelle als Import-/Exportprofil (15.10.2026)

Nutzerwunsch 15.10.: Das Tabellenformat der Beispiel-Arbeitszeittabelle (Jahresblätter, Wochenblöcke) soll Import **und** Export können (ADR-0013, Vertrag v0.10.0). Entscheidungen: „Freigestellt“ = neuer Typ `excused`; Export mit bewerteten Zeiten (Option tatsächlich).

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| C20 | Modulschalter Backend (ADR-0012) | Codex | 8 | integriert (Merge `38a3f5a`); 202 Tests inkl. MariaDB (Lead) | – |
| L17 | Modulschalter PWA + PWA-Doku + Flaky-Test-Fix | Claude-Agent | 6 | integriert (PWA `1d88e10`); 455 Unit, 58 Mock-E2E, 128 Echt-E2E (Lead; zwei Specs an C19-Verhalten angepasst) | C20 |
| D1 | Dokumentationsabgleich Backend (README, KONZEPT, ARCHITEKTUR, UMSETZUNG, EINRICHTUNG, ADR-Index) | Claude-Agent | 3 | integriert (Merge `1308de8`) | – |
| C21 | `excused` durchgängig + Import-Profil `worktime_workbook` (Erkennung, Parser, Regeln, Absenzen, Rollback) | Codex | 10 | in Arbeit (Hauptordner, Branch `c21-worktime-import`) | ADR-0013 |
| C22 | Export-Profil `worktime-xlsx` (Formelschreiber mit Cache-Werten, Jahresblätter) + Round-trip-Tests | Codex | 8 | offen (nach C21) | C21 |
| L18 | PWA: excused, Import-Assistent-Zweig (Regeltabelle, nicht zugeordnete Bemerkungen), Export-Option; Modul-Echt-E2E | Claude-Agent | 8 | integriert (PWA `0ad2229`); 488 Unit, 63 Mock-E2E, 6 PWA-Build-Specs, 138 Echt-E2E (Lead); Tabellen-Import/Export bisher nur gegen Mock | Vertrag v0.10.0 |
| L19 | Echt-E2E Import/Export Tabelle (synthetische Mappe; lokale Prüfung gegen Nutzerdatei ohne Ablage) | Claude-Agent | 4 | integriert (PWA-`main`); 156 Echt-E2E + 1 `test.fixme` (Lead nachgelaufen, einzeln stabil; bei Systemlast ~280 einzelne Timeouts) | C21, C22, L18 |

## Etappe 4f: Designsprache (15.10.2026)

Nutzerwunsch 15.10.: Gestaltung eines bereitgestellten UI-Entwurfs festhalten und übernehmen (ADR-0014, `docs/DESIGN.md`).

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| L20 | Diagnose Zeitkonto-Abweichung Tabelle ↔ App (nur Aggregatzahlen, lokal) | Claude-Agent | 3 | abgeschlossen: kein systematischer Fehler, vier Datenfälle (Feiertagszeilen, Teilgutschrift, Modellbeginn, Zeilen nach heute) | C21, C22 |
| L21 | PWA: Designsprache umsetzen (Tokens, Shell, Seitenkopf, Karten, Glas, Akzent, Barrierefreiheit) | Claude-Agent | 10 | integriert (PWA `b86cb77`); 500 Unit, 69 Mock-E2E, 6 PWA-Build-Specs, 156 Echt-E2E vom Lead (Last ~250 verursacht einzelne Timeouts bei Gesamtläufen); Screenshots Heute/Kalender gesichtet | ADR-0014 |
| C23 | Import-Verfeinerung nach Diagnose: Feiertagszeiten verwerfen (`holidayTimes`), Teilgutschriften als Arbeit (`partialCredit`), getrennte Tabellensalden, `firstContentDate` | Codex | 6 | integriert (Merge `b02a2c3`); 231 Tests inkl. MariaDB (Lead) | L20, Nutzerentscheidung 15.10. |
| L22 | PWA-Import-Assistent für C23 (Optionen, Warnungen, Salden, Modellbeginn-Hinweis) im neuen Design | Claude-Agent | 4 | integriert (PWA e734ea5; check 0 Fehler, 522 Unit, 71 Mock-E2E, 6 PWA-Build, 158 Echt-E2E; live auf der Testinstanz) | C23, L21 |

Etappe 5 (Native Apps, Repo timetrack-apple), Start 16.10.2026:

| Paket | Inhalt | Verantwortlich | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| A1 | Swift-Paket TimetrackCore (API-Client, Auth, Stores) + macOS-App (Heute, Zeit, Einstellungen, Menüleiste) | Claude-Agent | 10 | integriert (Apple `fade61a`); 43 Tests inkl. Integrationslauf gegen Wegwerf-Backend, macOS- und iOS-Build vom Lead nachgelaufen; Oberfläche nie gesichtet (kein Screenshot möglich) | ADR-0015 |
| A2 | Backend: `/.well-known/apple-app-site-association` (`APPLE_APP_IDS`), WebAuthn-Origin für native Apps | Claude-Agent (Branch a2-aasa) | 4 | integriert (v0.10.4); 236 Tests auf SQLite vom Lead nachgelaufen, MariaDB und Linux-Build laut Agent; echter Apple-Passkey und AASA hinter dem Proxy ungeprüft (Handoff `handoffs/A2.md`) | A1 |
| A3 | iOS/iPadOS-App (Heute, Zeit, Urlaub read-only, Einstellungen, App Intents) | Claude-Agent | 8 | integriert (Apple `4ab26a2`); 50 Package-Tests und Mac-/iOS-Build vom Lead nachgelaufen, UI-Smoke-Test auf iPhone- und iPad-Simulator laut Agent; Passkey, Intents, Echtgerät, VoiceOver, Dark Mode/Dynamic Type ungeprüft | A1, A2 |
| A4 | watchOS-App (direkt zum Server, Sitzung per WatchConnectivity vom iPhone) | Claude-Agent | 6 | integriert (Apple `Merge A4`); 59 Package-Tests und Watch-/iOS-/Mac-Build vom Lead nachgelaufen; Simulator-Lauf mit Wegwerf-Backend laut Agent (3 Screenshots); WatchConnectivity nur gegen Mock, nie auf Gerät/Simulator-Paar; Komplikation und Art-Auswahl offen | A3 |
| A5 | watchOS: Art-Auswahl, Komplikation (WidgetKit, App Group, nicht geheimer Snapshot), iPhone-Knopf „Sitzung an Uhr senden", Dynamic-Type-Korrektur iOS | Claude-Agent | 5 | integriert (Apple-Merge A5); 69 Paket-Tests und Watch-/iOS-/Mac-Build vom Lead nachgelaufen; Simulator-Screenshots laut Agent (Picker, Komplikations-Galerie, iPhone XXL dunkel); echte Komplikation auf Zifferblatt, Signierung mit App Group und Echtgerät ungeprüft | A4 |
| A6 | Native Designpass (TimetrackDesign, iOS/iPadOS/macOS/watch, App-Icon als Asset-Set) | Claude-Agent | 10 | integriert (Apple-Merge A6); 69+3 Paket-Tests und iOS-/macOS-/Watch-Build vom Lead nachgelaufen, iPhone-Screens (Heute laufend, Zeit dunkel) gesichtet; macOS nur als Hierarchie-Aufnahme, iPad/Uhr teils ungesehen | A5 |
| A6b | App-Icon im Icon-Composer-Format (`.icon`, Ebenen als SVG, ruhiger Bogen mit Zeiger in #2563EB, Hell/Dunkel/Getönt) plus 3–4 alternative Icon-Varianten, in den iOS-Einstellungen wählbar (`setAlternateIconName`); macOS: nur Standardicon (kein dauerhaftes Wechseln möglich), Uhr: nur Standard | Claude-Agent | 4 | integriert (Apple-Merge A6b); Builds iOS/macOS/watch vom Lead nachgelaufen, Primärvorschau gesichtet (wirkt wie ein Tacho), Varianten und Auswahl-Ansicht nicht gesichtet, Einbau der Auswahl in die Einstellungen nach A6 | A6 |
| A6c | App-Icon neu nach Nutzervorlage (geschlossener Ring, weiße Zeiger, dunkle Fläche) mit Akzent-Varianten Blau/Türkis/Violett/Grün/Orange/Rosa; Auswahlansicht | Claude-Agent | 4 | integriert (Apple-Merge A6c); sieben Varianten gebaut, Variante „Hell“ vom Lead gestrichen (Zeiger im Dunkelmodus kaum sichtbar); Dark/Tinted-Spezialisierungen werden von ictool/actool ignoriert (Systemableitung); Wechsel im Simulator nur für Orange gesehen | A6b |
| A6d | Native Einstellungsseite „Darstellung" (iOS/iPadOS/macOS): **App-Akzentfarbe und App-Symbol getrennt wählbar** (Nutzerentscheidung 16.10.), Erscheinungsbild System/Hell/Dunkel, Auswahlansicht aus A6c einbauen; Akzent lokal je Gerät (Synchronisation über das Konto offen) | Claude-Agent | 3 | integriert (Apple-Merge A6d); 69+11 Paket-Tests (Kontrast ≥4,5:1 über alle Presets) und drei Builds vom Lead nachgelaufen, Darstellungsseite (Orange/dunkel) gesichtet; macOS-Tab, Graphit, ColorPicker, iPad/Uhr ungesehen; Akzent nur lokal, nicht im Konto, Widgets folgen ihm noch nicht | A6, A6c |
| A7 | Widgets: iOS-Homescreen/Sperrbildschirm (interaktiv per App Intents), Live Activity, Steuerzentrale, macOS-Widgets | Claude-Agent | 8 | integriert (Apple-Merge A7); 72+11 Paket-Tests und drei Builds nach dem Merge vom Lead; Widgets/Intents/Live Activity/Control Center nur kompiliert, nur Debug-Galerie in der App gesichtet (Home/Sperrbildschirm/Live-Activity-Attrappen), macOS-Widgets ungesehen; signierter iOS-Build mit App Group und gemeinsamer Keychain-Gruppe laut Agent; Keychain-Lesen aus der Erweiterung auf dem Gerät ungeprüft | A6b |
| A8 | Native Apps: Akzent und Erscheinungsbild aus dem Konto (`/me/preferences`, ADR-0020) laden/speichern mit lokalem Cache; Akzent in den Widget-Snapshot; Abgleich nach „Vertrag für native Clients“ (docs/handoffs/P2.md) | Claude-Agent | 4 | integriert (Apple-Merge A8); 93+14 Paket-Tests und drei Builds vom Lead nachgelaufen, „Heute“ mit Konto-Akzent Orange nach Neuinstallation gesichtet; macOS-UI, Widgets/Komplikation auf dem Gerät, Offline-/Fehlerzustände der Statuszeile, Zwei-Geräte-Konflikt ungeprüft | P2, A7 |
| L23 | PWA: Konten-Verwaltung, Daten & Datenschutz (Export, Selbstlöschung), `pushsubscriptionchange` im Service Worker | Claude-Agent | 8 | integriert (PWA `714aa09`); check 0 Fehler, 551 Unit, 77 Mock-E2E, 6 PWA-Build (Lead), 10 neue Echt-E2E (Lead, gegen frisch gebautes Backend), Agent: 168 Echt-E2E gesamt; `reauth_required`/503 nur Mock | B1, B2 |

Backend-Wartung (Start 16.10.2026):

| Paket | Inhalt | Verantwortlich | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| B2 | Aufräumjob (Lease, CLI `maintenance`), Lernfeld-409, `pushsubscriptionchange`-Endpunkt, `PUSH_ALLOWED_HOSTS`-Vorschlag, `auth_lock`-Messung, MariaDB-READ-COMMITTED-Fix (ADR-0017, Vertrag v0.10.5) | Claude-Agent (Branch b2-cleanup) | 8 | integriert (Vertrag v0.12.0 zusammen mit B1); nach Merge 277 Tests auf SQLite und auf MariaDB vom Lead; S3Mock-Lauf und Mehr-Replikas-Betrieb ungeprüft | ADR-0011 |

## P1 – Profil und geführte Einrichtung (16.10.2026)

Claude-Agent in den Worktrees `timetrack-backend-wt/p1` und `timetrack-pwa-wt/p1`, Branch `p1-profile` (beide Repos), nicht gemergt.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| P1 | Profilbearbeitung (Name, E-Mail per Code), Einrichtungsmerker, Vertrag v0.13.0, ADR-0019; PWA: Profilseite, Einrichtungsassistent, gruppierte Einstellungsnavigation, Mock, Unit-/Mock-/Echt-E2E | Claude-Agent | 8 | integriert (Backend Vertrag v0.13.0; PWA-Merge); Lead: PWA check 0 Fehler, 575 Unit, 81 Mock-E2E, 6 PWA-Build, Echt-E2E profile+stage1 23/23 gegen frisch gebautes Backend; Backend 296 Tests SQLite (bis auf die 2 bekannten lastempfindlichen Push-Tests grün); echte E-Mail-Zustellung ungeprüft; Live-Instanz aktualisiert | B1, C20 |


## P2 – Darstellung je Konto (16.10.2026)

Claude-Agent in den Worktrees `timetrack-backend-wt/p2` und `timetrack-pwa-wt/p2`, Branch `p2-accent` (beide Repos), nicht gemergt. Nutzerentscheidung 16.10.2026: Akzent und Farbschema je Konto, App-Symbol bleibt Gerätewahl; native Apps folgen in einem späteren Paket.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| P2 | `GET/PATCH /me/preferences` (Akzent, eigene Farbe, Farbschema), `account.preferences` in der Sitzung, Export `preferences.json`, Vertrag v0.14.0, ADR-0020; PWA: Darstellungsseite am Konto mit localStorage-Cache und Abgleich, Mock, Unit-/Mock-/Echt-E2E; Vertrag für native Clients in `handoffs/P2.md` | Claude-Agent | 3 | integriert (Vertrag v0.14.0, ADR-0020); Lead: Backend 305 Tests SQLite, 0 Fehler; PWA check 0 Fehler, 587 Unit, 84 Mock-E2E, Echt-E2E 180/180 gegen frisch gebautes Backend; Live-Instanz aktualisiert (alte Build-Dateien in deploy/pwa-static nicht gelöscht, nur überschrieben); native Apps noch nicht angepasst (A8) | P1 |

## W1 – GitHub Actions und Pages (17.10.2026)

Claude-Agent in den Worktrees `timetrack-backend-wt/w1` (Branch `w1-ci-pages`), `timetrack-pwa-wt/w1` und `timetrack-apple-wt/w1` (Branch `w1-ci`), nicht gemergt, nichts gepusht. Parallel schreibt D2 `deploy/swarm/*`, `docs/DEPLOYMENT.md`, `docs/BETRIEB.md`.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| W1 | Workflows (CI, Docker multi-arch, Pages, Release, CodeQL, Dependency Review, Dependabot), Vorlagen, `SECURITY.md`, `CODEOWNERS` in allen drei Repos; Website `site/` (VitePress, Landingpage, Doku aus Repo-Dokumenten, API-Referenz); `docs/CI.md` | Claude-Agent | 5 | umgesetzt, Lead-Prüfung offen; nur statisch (actionlint) und lokal geprüft, auf GitHub nie gelaufen (`docs/CI.md`, `handoffs/W1.md`) | – |
