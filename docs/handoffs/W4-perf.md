# W4-perf – Wochen-, Konto- und Statistikabfragen unabhängig von der Historienlänge

Stand: 28.10.2026, Branch `w4-week-perf` (Basis main 9c21fe0), nicht gemergt. Kein API-Verhalten und kein Vertrag geändert (Antworten inhaltsgleich, Vertrag unverändert).

## Befund
`GET /time/weeks/{w}`, `GET /time/account` und `GET /time/statistics` luden über `days.snapshot()` die gesamte Segment- und Abwesenheitshistorie und werteten jeden Tag ab Kontostart aus; Latenz wuchs mit dem Alter des Kontos. `GET /time/days` war bereits fensterbasiert.

## Änderung
- `BalanceCheckpoints.swift`: Kontostand-Zwischenstände. Je Konto und Monatsende wird die Summe der amtlichen Tagesdeltas (ab Kontostart) gecacht (Prozess-Cache, 512 Einträge). Anfragen laden nur das Fenster ab dem Folgetag des letzten Monatsendes vor dem Ankertag plus das angezeigte Fenster und rechnen Eröffnung, Korrekturen (live, immer aus der DB), Rundung, Feiertags-/Betriebstags-/Rechtsprofilregeln unverändert mit derselben Engine. Fallbacks auf die volle Historie: keine Arbeitsmodelle, laufender Abschnitt vor dem Zwischenstand (hängt von `now` ab).
- `TimeChangeMarks.swift` + Migration `w4.create_time_change_marks`: Tabelle `time_change_marks` (Konto, Monat, Revision). Fluent-Middleware erhöht beim Anlegen/Ändern/Löschen von Segmenten, Tagesvorgaben, Abwesenheiten (Monat des Datums minus 7 Tage Sicherheitsrand), Arbeitsmodellen, Urlaubseinstellungen und eigenen Kalendertagen (letztere drei: alle Monate) die Marke in derselben Transaktion. Ein Zwischenstand gilt nur, solange die Summe der Revisionen aller Marken bis zu seinem Monat unverändert ist; die Invalidierung liegt damit in der DB und wirkt über mehrere Replikas. `AccountEraser` löscht die Marken mit.
- `TimeWeek`, `TimeStatistics`, `AccountService.balance`: ein Snapshot je Anfrage, Arbeitsmodelle werden nur einmal geladen (`snapshot(models:)`). Wochen-/Statistik-Logik als `compose(...)` / `series(inputs:)` über `BalanceInputs` herausgezogen (dient auch als Orakel der Tests).
- Keine neuen Indizes nötig: `idx_work_segments_account_started` (X1) deckt die Fensterabfragen ab.

## Messung (SQLite in-memory, 1466 Segmente, 35 Abwesenheiten, 26 Anpassungen, 59 Tagesvorgaben, ca. 3 Jahre; Median von 5, `WeekPerfBenchmarkTests`)
| Aufruf | vorher | nachher (letzter Lauf) |
|---|---|---|
| Woche aktuell | 10 Stmts, 146,6 ms | 11 Stmts, 8,3 ms |
| Woche alt (2024-W20) | 10 Stmts, 100,2 ms | 11 Stmts, 9,1 ms |
| Kontostand | 9 Stmts, 121,8 ms | 10 Stmts, 7,3 ms |
| Statistik 12 Monate (Monat) | 9 Stmts, 116,0 ms | 10 Stmts, 43,3 ms (365 Tage werden ohnehin ausgewertet) |
| Tage (7), unverändert | 8 Stmts, 3,4 ms | 8 Stmts, 3,5 ms |
Hinweis: "vorher" und "nachher" wurden an verschiedenen Zeitpunkten gemessen (Rechnerlast unterschiedlich; ein früherer Nachher-Lauf unter Last gab 28,5/27,8/20,2/89,7 ms). Verlässlich sind die Größenordnung und die Unabhängigkeit von der Historie. Die eine zusätzliche Anweisung ist die Marken-Abfrage. Die erste Anfrage nach einer Änderung baut den Zwischenstand neu (einmalig voller Preis wie vorher; die volle Historie dient dann zugleich als Snapshot, ohne zweiten Ladevorgang). Kaltes Konto-Statement-Budget: 10 (Testgrenze 12 unverändert). Die Zeit hängt nun von Fenstergröße statt Historie ab.

## Tests
`WeekPerfEquivalenceTests`: (1) 5 zufällige Historien (Seeds, mit/ohne Eröffnungsstand, Modellwechsel, Rechtsprofil Erwachsene/Jugendliche, laufender Abschnitt, vergessener Timer in der Vergangenheit), Wochen (Monatsgrenzen, Zufallswochen), Kontostände (as-of beliebig, Zukunft), Statistik (Tag/Woche/Monat, roh/bewertet), Tage; je mit zwei anderen "heute"-Zeitpunkten und Cache-Wiederverwendung: 625 Vergleiche, byte-gleiches JSON gegen die Auswertung der Gesamthistorie. (2) Schreibzugriffe (Segment neu/verschoben/storniert, Anpassung, Tagesvorgabe, Abwesenheit, Kalendertag, Arbeitsmodell) invalidieren. (3) Statement-Budget und Cache-Wiederverwendung. Hilfen: `WeekPerfSupport.swift`; Benchmark `WeekPerfBenchmarkTests`.

## Korrektur nach Lead-Review
Der erste Commit riss 47 Tests: Sammel-`create` (Import, 50er-Blöcke) führt die Middleware nebenläufig aus; zwei Marken-Inserts desselben Monats kollidierten auf dem Unique-Schlüssel (500 `not_ready`). `touch` fällt jetzt bei Kollision auf das Erhöhen der vorhandenen Marke zurück. Das Budget-Problem (17 > 12) kam von einem zusätzlichen Fenster-Snapshot im Cache-Miss; Kontostart, Planungsmodul und Marke werden nun vor dem Laden bestimmt, bei Miss wird nur die volle Historie geladen. Voller Lauf: 445 Tests, 42 übersprungen (MariaDB/Bench), 0 Fehler.

## Offen / ungeprüft
- MariaDB nicht ausgeführt (nur SQLite). Middleware nutzt nur Fluent-Standardabfragen; Migration `unique(account_id, month)` ist portabel, aber ungetestet auf MariaDB.
- Schreibpfade ohne Fluent-Modell-Middleware (Massen-`delete()`/`update()` auf diese Tabellen, Roh-SQL, DB-Restore) markieren nicht; im Code gibt es heute keine außer dem Löschen stornierter Segmente (für die Auswertung irrelevant). Bei Rolling-Updates könnte eine alte Instanz ohne Marken schreiben (Migration läuft vor dem Backend, Risiko gering).
- Jeder Schreibzugriff kostet 1-2 Zusatzanweisungen für die Marke (Importe großer Dateien entsprechend mehr).
- Prozess-Cache ist je Replikat; Gültigkeit hängt an der DB-Marke.
