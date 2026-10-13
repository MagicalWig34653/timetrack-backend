# Arbeitsplan und Agent-Übergabe

Stand: 13.10.2026. Grundgerüste gemäß `REPOSITORIES.md` eingerichtet. Kein Agent besitzt aktuell einen Schreibbereich. Fachliche Implementierung folgt unter Claude-Leitung.
Gewichte unten sind ein Startvorschlag, vor Zuweisung nach technischem Durchstich anpassen.
Abnahmebedingungen: `UMSETZUNG.md`. Vorgehen: `ENTWICKLUNGSABLAUF.md`.

| ID | Paket | Geplante Verantwortung | Punkte | Status | Abhängigkeiten |
| --- | --- | --- | --- | --- | --- |
| P0 | Voraussetzungen, Git, API-Verträge und tatsächliche Agent-Zuweisung | Claude-Lead | – | teilweise: Grundgerüste und Health-Vertrag vorhanden; Fachverträge/Zuweisung offen | keine |
| C1 | Swift-Service, MariaDB/SQLite, erste Migrationen und DB-Tests | Codex | 5 | offen | P0 |
| C2 | Einladung/Konten, WebAuthn-Verifikation und Recovery-Dienste mit Tests | Codex | 8 | offen | C1, API-Vertrag |
| L1 | Svelte-Grundlage und Passkey-/Recovery-/Einladungsoberfläche | Claude-Agent | 8 | offen | P0, API-Vertrag; Integration nach C2 |
| L2 | Compose, reproduzierbarer Build und Browserintegration mit Tests | Claude-Agent | 5 | offen | P0; Integration nach C1/L1/C2 |

Vorgeschlagener Implementierungsumfang: Codex 13/26 Punkte, Claude 13/26 Punkte.
Tatsächlich abgeschlossen: 0 Punkte; ein realer Codex-Anteil ist noch nicht messbar.
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
