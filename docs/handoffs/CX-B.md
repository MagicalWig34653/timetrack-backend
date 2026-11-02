# Handoff CX-B (Codex-Befunde F05-F11, 02.11.2026)

Code-Commit `52cd8e9` (Paket-ID `CX-B`), Befundstatus: `docs/reviews/2026-11-01-codex-review-gpt-6.1-sol.md`, Abschnitt „Umsetzung CX-B“.

## Geändert

- **F05** `Groups/GroupRoutes.swift`: Zähler der öffentlichen Gruppenschreibzugriffe werden nach Rollback bei jedem `APIError` erneut außerhalb der Transaktion eingetragen.
- **F06** `Groups/GroupModels.swift`: g1b legt `link_token` nur an, wo die Spalte fehlt.
- **F08** `AbsenceSemanticsMigrations.swift`: Datenschritte und Zeitkonto-Invalidierung in einer Transaktion.
- **F07** `Accounts/AccountExportService.swift`: `vacation-snapshots.json`.
- **F09** `CalendarFeeds.swift`: Tagesmarkierungen nur bei aktivem Planning.
- **F11** `TimeWeek.swift`, `TimeStatistics.swift`: `TimeWeekDayDTO.vacationDays` (halber Betriebstag zählt 0,5).

## Auswirkungen auf Clients

Keine Vertragsänderung. Wochen-`summary.vacationDays` und Statistik-`absences.vacation`/`absenceDays` zeigen an halben Betriebstagen jetzt 0,5 statt 1 (stimmt nun mit dem Urlaubskonto überein). ICS-Abonnenten sehen bei abgeschaltetem Planning keine Tagesmarkierungen mehr. Das Exportarchiv enthält eine zusätzliche Datei `vacation-snapshots.json`. Gruppen-Links können nach wiederholten Fachfehlern früher 429 liefern (gewollt).

## Offen: F10 (Entscheidung nötig)

Siehe Review-Abschnitt. Test `testBlockSchoolWeekWithSixSchoolDaysCharacterization` hält den heutigen Stand (48 h) fest.

## Tests

Linux-Container `swift:6.3-noble`, SQLite, `-j 3`. MariaDB-Läufe der Migrationstests: siehe Eintrag unter STATUS bzw. Abschlussbericht.
