# N4 – Betriebstage 24.12./31.12. (Backend)

Stand: 26.10.2026, Branch `n4-company-days` (von `main` f3a4e82). Vertrag `0.32.0`, Migration `n4.add_company_days`, Entscheidung ADR-0029.

## Umgesetzt

Konfigurierbare Betriebstage je Konto in den Urlaubseinstellungen: `companyDays: [{month, day, treatment none|half|full, name}]`, Standard `none` (unverändertes Verhalten). Zentrale Quelle ist `HolidayCalendar.calendar(year:region:companyDays:)`; alle Stellen, die bisher `HolidayCalendar.holidays` nutzten (Tagesauswertung, Urlaubsverbrauch und -saldo, Kalenderliste, ICS, Vorschläge, Import), verwenden sie. Details und Begründung (`half` = höchstens ein halber Urlaubstag, kein Rest-Soll) in ADR-0029.

## API-Felder für PWA und Apple-Apps

| Ort | Feld |
| --- | --- |
| `GET/PUT /vacation/settings` | `companyDays` (Liste; GET enthält immer 24.12. und 31.12., PUT ohne Feld ändert nichts, mit Feld ersetzt es; 400 bei 29.02., doppeltem Datum, ungültigem Datum, mehr als 12 Regeln, unbekannter Behandlung, Name über 80 Zeichen). Eigene Daten (z. B. 12.06.) möglich |
| `GET /time/weeks/{w}` Tage | `holidayName` (Heiligabend/Silvester oder eigener Name) und neu `companyDayTreatment` (`half`, `full` oder null). `full`: `mark` holiday, Soll 0 (am Wochenende `off`, Name sichtbar). `half`: `mark` bleibt `work`, `targetSeconds` halbiert. Anzeige also nicht nur über `mark`, sondern über `holidayName`/`companyDayTreatment` |
| `GET /calendar/holidays` | neu `companyTreatment` (`half|full|null`); `kind` bleibt `holiday`, `source` `builtin`. Ältere Clients sehen einen Feiertag |
| `GET /plan/weeks/{w}` | `targetSeconds` folgt der Regel; `half` ist nicht `blockedBy` |
| `GET /absences`, `/vacation/balance` | `countedHalfDays` und Saldo folgen der Regel (half: höchstens 1, full: 0) |
| ICS | Kategorie `Betriebsfrei`, Titel „Heiligabend (halber Tag)“ bzw. „Silvester“ |

Keine neuen Enum-Werte: ältere Clients bleiben funktionsfähig. Die PWA/Apple-Apps brauchen eine Einstellung (z. B. unter Urlaub/Region) mit Auswahl Keine/Halber Tag/Ganzer Tag je Datum und die Anzeige von `holidayName` in der Wochen-/Kalenderansicht.

## Prüfung

Gezielt: 19 Tests grün (7 Engine in `CompanyDayEngineTests`, 5 HTTP in `Tests/TimetrackKitTests/CompanyDayTests.swift`: Einstellungen/Validierung, Wochenansicht und Ziele, Feiertagsliste, Planwoche, Wochenende, Urlaubszählung und Saldo je Behandlung, Statistik, ICS; plus die 7 bestehenden Kalenderabo-Tests). `scripts/contract-json.sh` ausgeführt. Vollständiger `swift test --build-system native --no-parallel` (SQLite): 422 Tests, 42 übersprungen, 0 Fehler (12 neue Tests).

## Nicht geprüft / offen

MariaDB-Lauf; MCP-Werkzeug `list_holidays` nur über denselben Dienst abgedeckt (kein eigener MCP-Test); Zeitkonto-Saldo über heutiges Datum hinaus nur indirekt (Wochenübersicht/Statistik); Praxistest ICS im Kalenderprogramm; Oberflächen. Regeln gelten für alle Jahre gleich, jahresbezogene Einzeltage über eigene Kalendertage.
