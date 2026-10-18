# Handoff AC2: sechs weitere Akzentfarben

Stand: 18.10.2026. Branch `AC2` in Backend und PWA, nicht gemergt. Vertrag v0.21.0, ADR-0020 Nachtrag. PWA-Gegenstück: `docs/handoffs/AC2.md` im PWA-Repo.

## Backend

- `Sources/TimetrackKit/Accounts/PreferencesModels.swift`: `accents` um `wine, slate, cocoa, olive, ocean, ink` erweitert (Validierung ist dieselbe Whitelist). `apiContractVersion` 0.21.0.
- `contracts/openapi.yaml` v0.21.0 (`AccentId`), JSON-Kopie mit `scripts/contract-json.sh` neu erzeugt.
- Tests: `PreferencesTests.swift` setzt alle 14 Farb-IDs ab v0.15.0 per PATCH; Export und Sitzungsantwort laufen mit `ink`. SQLite: 331 Tests, 39 übersprungen (MariaDB-Varianten), 0 Fehler. MariaDB (eigene Datenbank `timetrack_test_ac2`, danach gelöscht): 331 Tests, 2 übersprungen, 0 Fehler.

## Verträglichkeit

- Der Server speichert und liefert die ID unverändert; er ersetzt oder übersetzt nichts. Bestehende Konten ändern sich nicht, keine Migration (JSON-Spalte).
- Server vor v0.21.0: lehnt die neuen IDs mit 400 `bad_request` ab. Die PWA erkennt das und speichert die Farbe als `custom` plus Hex (Leuchteffekt bleibt synchron, solange der Server v0.15.0 oder neuer ist).
- Clients ohne Kenntnis der neuen IDs (ältere PWA, Apple-Apps bis zur Umstellung) zeigen sie als Blau (Vertragsregel seit v0.15.0). Die Auswahl wird nicht überschrieben, solange der Nutzer dort nicht selbst eine Farbe wählt.

## Neue Akzent-IDs für die Apple-Apps (AccentChoice/IconAccent)

Alle mit weißer Schrift auf der Fläche. Kontrast mit Weiß per WCAG-Formel berechnet. Anzeigenamen deutsch, Reihenfolge wie in der PWA (nach `bronze`).

| `accent` | Anzeige (de) | Hex | Kontrast Weiß |
| --- | --- | --- | --- |
| `wine` | Wein | #7F1D3F | 9,77 |
| `slate` | Schiefer | #475A8C | 6,75 |
| `cocoa` | Kakao | #5C4033 | 9,39 |
| `olive` | Oliv | #4D6B1F | 6,11 |
| `ocean` | Ozean | #0E7490 | 5,36 |
| `ink` | Tinte | #334155 | 10,35 |

Unterscheidbarkeit: OKLab-Abstand (ΔE, Faktor 100) jeder neuen Farbe zur nächsten der übrigen 20 Voreinstellungen mindestens 5,8 (`ocean` zu `petrol`), die übrigen 5,9 (`olive` zu `forest`) bis 10,5; kleinster Abstand unter den bisherigen 15: 6,0. Das Apple-Repo wurde nicht angefasst.
