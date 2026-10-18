# Handoff V2: Urlaubsplanung (Backend)

Stand: 19.10.2026. Branch `v2-vacation-suggestions` (Worktree `timetrack-backend-wt/v2`), nicht gemergt, Lead-Prüfung offen. Entscheidungen: `docs/decisions/ADR-0025-urlaubsplanung.md`. Vertrag **v0.22.0** (additiv, kein Schemawechsel, keine Migration).

## Neu
- `GET /api/v1/vacation/suggestions?from=YYYY-MM-DD&to=YYYY-MM-DD&maxVacationDays=10&minDaysOff=4&limit=20` (alle Parameter optional; Standard: heute bis Ende nächstes Jahr). Modul `planning`, Sitzung, nur eigene Daten.
- `Sources/TimetrackKit/VacationEngine/VacationSuggestionEngine.swift` (reiner Algorithmus), `Sources/TimetrackKit/VacationSuggestionService.swift` (Laden, Antwort), Route in `PlanningRoutes.swift`.
- Tests: `VacationSuggestionEngineTests.swift` (13 Fälle: Brückentag, 4-Tage-Woche, Feiertag am Wochenende, Regionen, Jahreswechsel, kein Anspruch, Budget erschöpft, Überlappungsfreiheit/Eindeutigkeit/Limit, stabile ID, bereits Urlaub, Konflikte, Schulferien, Leereingaben) und `VacationSuggestionHTTPTests.swift` (Inhalt, Validierung, 401, Kontentrennung; SQLite und MariaDB); Modulschalter in `ModuleTests.swift`.

## Fehler
400 `invalid` (u. a. `to` < `from`, Zahl außerhalb 1..60/1..60/1..100, Datum ungültig), 400 `range_too_large` (mehr als 18 Monate), 404 `module_disabled`, 401.

## Antwortbeispiel für die PWA
`GET /api/v1/vacation/suggestions?from=2026-05-01&to=2026-07-31&limit=2`

```json
{
  "from": "2026-05-01",
  "to": "2026-07-31",
  "budget": { "entitlementDays": 30, "takenDays": 2, "plannedDays": 1, "remainingDays": 27 },
  "suggestions": [
    {
      "id": "6aca3cad71036dfc",
      "kind": "bridge",
      "start": "2026-05-14",
      "end": "2026-05-17",
      "vacationDates": ["2026-05-15"],
      "vacationDaysNeeded": 1,
      "totalDaysOff": 4,
      "efficiency": 4,
      "holidays": [{ "date": "2026-05-14", "name": "Christi Himmelfahrt" }],
      "schoolHolidays": [],
      "conflicts": [{ "date": "2026-05-15", "type": "school_day" }],
      "fitsBudget": true,
      "remainingAfter": 26
    },
    {
      "id": "3a8bfd511a66c0fb",
      "kind": "bridge",
      "start": "2026-05-22",
      "end": "2026-05-25",
      "vacationDates": ["2026-05-22"],
      "vacationDaysNeeded": 1,
      "totalDaysOff": 4,
      "efficiency": 4,
      "holidays": [{ "date": "2026-05-25", "name": "Pfingstmontag" }],
      "schoolHolidays": [],
      "conflicts": [{ "date": "2026-05-22", "type": "absence" }, { "date": "2026-05-22", "type": "plan" }],
      "fitsBudget": true,
      "remainingAfter": 26
    }
  ]
}
```

Hinweise für die Darstellung: `kind` (`bridge`, `holiday_cluster`, `school_holiday_extension`, `long_break`) und `conflicts[].type` (`absence`, `school_day`, `plan`, `already_vacation`) als Symbole/Hinweise; Konflikte nie ausblenden, sondern warnen. `fitsBudget` gilt je Vorschlag einzeln (nicht kumulativ). Zum Übernehmen den Vorschlag als Urlaub anlegen: `POST /absences` (`kind: vacation`, `startDate`=`start`, `endDate`=`end`) (oder nur den Urlaubstagen `vacationDates`, falls nicht zusammenhängend: dann je Block ein Eintrag); der Server verbucht nur Arbeitstage, Feiertage und freie Tage im Zeitraum kosten nichts. Ohne Konflikt-Warnung wird nichts gebucht: der Endpunkt ändert nie Daten. `efficiency` ist auf 2 Stellen gerundet, Budgettage können Halbtage sein (z. B. 12.5).

## Prüfung
- `swift test --build-system native` SQLite: 346 Tests, 40 übersprungen (MariaDB-Varianten), 0 Fehler.
- MariaDB (eigene Datenbank `timetrack_test_v2`, danach gelöscht): 346 Tests, 2 übersprungen, 0 Fehler; `testVacationSuggestionsMariaDB` bestanden.
- `scripts/contract-json.sh` neu erzeugt, Vertragstests und `apiContractVersion` (0.22.0) grün. Nicht gemessen: Linux-Docker-Build.

## Offen
- Kumulative Budgetprüfung, MCP-Werkzeug, halbe Urlaubstage in Vorschlägen (ADR-0025, Abschnitt Offen).
