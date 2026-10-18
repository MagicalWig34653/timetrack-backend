# Handoff S1a (Backend): Datenbankausfall als 503

Stand: 18.10.2026. Branch `S1a`, nicht gepusht, nicht gemergt. Entscheidungen: ADR-0024.

## Was gebaut ist
- `Sources/TimetrackKit/InfrastructureError.swift`: Klassifizierung; `APIErrorMiddleware` (`AuthSupport.swift`) antwortet 503 `database_unavailable` mit `Retry-After` (2, Pool-Zeitlimit 5) und loggt die Klasse einmal auf Warnstufe. Meldung in `ModuleMessages`.
- `TimeErrorMiddleware` reicht unbekannte Fehler bereits weiter, daher gilt die Abbildung auch für Zeit-Routen.
- `/ready` und Healthcheck: geprüft, unverändert (503 bei Datenbankausfall, Healthcheck ruft `/ready`). `docs/installation/probleme.md` ergänzt.
- Vertrag v0.20.0 (`ServiceUnavailable`, an `/ready`-unabhängige Operationen über die gemeinsame Antwort; `system/info` verweist darauf), JSON-Kopie neu erzeugt, `apiContractVersion` angehoben.

## Tests
- `InfrastructureErrorTests` (4): Klassifizierung mit eingespeisten Fehlern, Nicht-Klassifizierung (Syntax, Duplikat, Bug), Retry-After, Middleware über XCTVapor (503 + Header, Pool 5, unbekannter Fehler 500).
- Gesamtlauf SQLite: 331 Tests, 39 übersprungen, 0 Fehler. Gesamtlauf mit MariaDB 12.3.3 (eigene Wegwerf-Datenbank `timetrack_test_s1a`, danach gelöscht): 331 Tests, 2 übersprungen, 0 Fehler.

## Offen
- MCP-Fehler bleiben `internal_error`; PWA-Wiederholung bei 503 fehlt (Folgepaket).
- Nur Replik-Ausfall ist nicht live nachgestellt (Klassifizierung mit eingespeisten Fehlern getestet).
