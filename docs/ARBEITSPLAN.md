# Arbeitsplan und Agent-Übergabe

Stand: 14.10.2026. Etappe 1 gestartet; Zuweisung gemäß ADR-0003.
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

## Abweichung vom 50-%-Ziel (Nutzerentscheidung 14.10.2026)

Wegen des erschöpften Codex-Kontingents setzt ein Claude-Agent C9 (8 Punkte) um. Stand der integrierten Punkte (Etappe 1–3a, ohne C9/L7b):
Codex 37 (C1 5, C2 8, C3 3, C4 1, C5 5, C6 8, C7 2, C8 5), Claude 38 (L1 8, L2 3, L3a 2, L3b 3, L4 8, L5 4, L6 8, L7a 2 – Schätzwerte).
Mit C9 als Claude-Umsetzung (+8) ergibt sich ein Verhältnis von ca. 45 % Codex zu 55 % Claude; innerhalb des Richtwerts 40–60 %, aber Etappe 3a allein liegt klar darunter (Codex C8 5 von 26).
Gegenseitiges Review: C9 soll nach Rückkehr des Kontingents (ab 20.10.) von Codex per Adversarial-Review geprüft werden; bis dahin prüft ein unabhängiger Claude-Agent.

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
| C16 | Etappe 4b: OAuth-Server, persönliche Tokens, Grants (ADR-0009, Vertrag v0.7.0) | Claude-Agent (Codex-Limit) | 8 | in Arbeit (Worktree `../timetrack-backend-wt/c16`) | Vertrag v0.7.0 |
| C17 | Etappe 4b: MCP-Endpunkt `/mcp` + Tools (gegen abgestimmte Authenticator-Schnittstelle) | Claude-Agent (Codex-Limit) | 8 | integriert (Merge); 166 Tests inkl. MariaDB (frische DB, 2 Läufe) vom Lead; `/mcp` liefert 401, bis C16 verdrahtet ist | Vertrag v0.7.0 |
| L15 | Etappe 4b: PWA Consent, API-Tokens, Verbindungen, MCP-Hilfe gegen Mock | Claude-Agent | 5 | integriert (PWA `46019ba`); 384 Unit, 48 Mock-E2E vom Lead; nur gegen Mock | Vertrag v0.7.0 |
| X1 | Verdrahtung C16↔C17 (Adapter), Gesamt-E2E MCP mit Skript-Client, OAuth-Flow im Browser | Lead + Agent | 4 | offen | C16, C17, L15 |
