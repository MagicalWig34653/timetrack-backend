# Arbeitsplan und Agent-Übergabe

Stand: 14.10.2026. Etappe 1 gestartet; Zuweisung gemäß ADR-0003.
Gewichte unten sind ein Startvorschlag, vor Zuweisung nach technischem Durchstich anpassen.
Abnahmebedingungen: `UMSETZUNG.md`. Vorgehen: `ENTWICKLUNGSABLAUF.md`.

| ID | Paket | Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| P0 | Voraussetzungen, Git, API-Vertrag (`contracts/openapi.yaml`, ADR-0003), Zuweisung | Claude-Lead | – | integriert 14.10. | keine |
| C1 | Swift-Konfiguration, MariaDB/SQLite, Migrationen, Modelle, /ready, DB-Testbasis | Codex | 5 | **integriert** (`f643f0d`); 7 Tests grün inkl. MariaDB 12.3.3 | P0 |
| C2 | Einladung/Konten, Sitzung/CSRF, WebAuthn, Recovery-Dienste, Admin-API, statische PWA, Integrationstests | Codex | 8 | in Arbeit (Worktree `../timetrack-backend-wt/c2`, Branch `c2-auth-services`) | C1 |
| L1 | Svelte-Oberfläche Auth/Passkeys/Recovery/Einladungen (Repo timetrack-pwa) | Claude-Agent | 8 | **integriert** (PWA `1cd79e0`); 31 Tests gegen Mock | P0 |
| L2 | Dockerfile, Compose dev, MariaDB-Dev, Skripte | Claude-Agent | 3 | **teilweise integriert** (`d78bb0a`): DB-Umgebung verifiziert; Image-Builds blockiert (Colima-Disk voll) | P0 |
| L3 | Image-Builds arm64/amd64, Browser-E2E mit virtuellem Authenticator gegen echtes Backend | Claude-Agent | 4 | offen | C2, L1, L2, freier Colima-Platz |

Geplanter Umfang: Codex 13/28 Punkte (46 %), Claude 15/28 (54 %); L2 auf 3 + L3 4 aufgeteilt.
Abgeschlossen und integriert: Codex 5 (C1), Claude 11 (L1 8 + L2 3). C2 (8) läuft.
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
