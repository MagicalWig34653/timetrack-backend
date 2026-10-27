# X4 – Korrekturen aus Codex-Review (Jugendprofil, Zeitkonto)

Stand: 25.10.2026, Vertrag `0.30.1` (nur Verhalten, keine Schemaänderung).

## Befunde

1. **Arbeit an vollem Berufsschultag (bestätigt, behoben).** `workAfterFullSchoolDay` prüfte nur Arbeit nach Schulbeginn, `workBeforeSchool` nur Beginn vor 09:00. Arbeit 09:00–09:30 bei Schulbeginn 10:00 löste nichts aus. § 9 JArbSchG verbietet die Beschäftigung an einem Berufsschultag mit mehr als fünf Unterrichtsstunden (je 45 Minuten) insgesamt. Jetzt gilt der Hinweis für jedes Nicht-Schul-Segment am Tag mit angerechnetem vollen Schultag (`statutorySchool`). Die Ausnahme „nur ein voller Schultag je Woche" bleibt: ab dem zweiten vollen Tag gilt der Tag nicht als `statutorySchool`, dort bleibt es bei `workBeforeSchool` (Beginn vor 09:00). Exporttext: „Arbeit an vollem Berufsschultag".
2. **Feiertag in der Wochensumme (bestätigt, behoben).** `PreparedEvaluation.evaluate` zählt für Tage mit Feiertagsmarke ohne Gutschrift jetzt `max(gezählt, Soll des Modells)`. Das betrifft nur die gesetzliche Wochensumme (`weekly_limit`); Zeitkonto (`deltaSeconds`) und die Zählung der Arbeitstage (`five_day_week`) bleiben unverändert. Rechtsannahme: § 4 Abs. 4 JArbSchG rechnet ausgefallene Arbeitszeit an gesetzlichen Feiertagen auf die Woche an; als Betrag wird das Tages-Soll des Arbeitsmodells verwendet. Fachlich zu bestätigen bleibt, ob bei abweichendem Soll (z. B. 8 h Gesetz vs. Modell-Soll) das Modell-Soll genügt.
3. **Kontostart nach Löschen des Eröffnungssaldos (bestätigt, behoben).** `accountStart` nimmt ohne Eröffnungssaldo den früheren von erstem Arbeitsmodell/erstem Abschnitt und frühester Anpassung. Vorher fielen Anpassungen vor dem Modellstart aus dem Saldo, obwohl sie gespeichert und gelistet waren. Tage vor dem ersten Modell haben Soll 0. Segmente vor dem ersten Modell bleiben wie bisher unberücksichtigt.

## Tests

`MinorLegalProfileTests` (`testAnyWorkOnFullSchoolDayIsFlaggedAlsoBeforeSchool`, `testHolidayLossCountsTowardsWeeklyLimit`), `TimeHTTPTests.testDeletingOpeningBalanceKeepsEarlierAdjustmentsInAccount`. Gesamtsuite `swift test --build-system native --no-parallel`: 398 Tests, 0 Fehler. `openapi.contract.json` neu erzeugt.

## Geändert

`TimeEngine.swift`, `PreparedEvaluation.swift`, `TimeEvaluationServices.swift`, `ExportService.swift`, `SystemInfo.swift`, `contracts/openapi.yaml`, `CHANGELOG.md`.
