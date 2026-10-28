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
| Aufruf | vorher | nachher |
|---|---|---|
| Woche aktuell | 10 Stmts, 146,6 ms | 11 Stmts, 28,5 ms |
| Woche alt (2024-W20) | 10 Stmts, 100,2 ms | 11 Stmts, 27,8 ms |
| Kontostand | 9 Stmts, 121,8 ms | 10 Stmts, 20,2 ms |
| Statistik 12 Monate (Monat) | 9 Stmts, 116,0 ms | 10 Stmts, 89,7 ms (365 Tage werden ohnehin ausgewertet) |
| Tage (7) | 8 Stmts, 3,4 ms | 8 Stmts, 12,1 ms (Rauschen, unverändert; Lauf nach Aufwärmen) |
Die eine zusätzliche Anweisung ist die Marken-Abfrage. Die erste Anfrage nach einer Änderung baut den Zwischenstand neu (einmalig voller Preis wie vorher). Die Zeit hängt nun von Fenstergröße statt Historie ab.

## Tests
`WeekPerfEquivalenceTests`: (1) 5 zufällige Historien (Seeds, mit/ohne Eröffnungsstand, Modellwechsel, Rechtsprofil Erwachsene/Jugendliche, laufender Abschnitt, vergessener Timer in der Vergangenheit), Wochen (Monatsgrenzen, Zufallswochen), Kontostände (as-of beliebig, Zukunft), Statistik (Tag/Woche/Monat, roh/bewertet), Tage; je mit zwei anderen "heute"-Zeitpunkten und Cache-Wiederverwendung: 625 Vergleiche, byte-gleiches JSON gegen die Auswertung der Gesamthistorie. (2) Schreibzugriffe (Segment neu/verschoben/storniert, Anpassung, Tagesvorgabe, Abwesenheit, Kalendertag, Arbeitsmodell) invalidieren. (3) Statement-Budget und Cache-Wiederverwendung. Hilfen: `WeekPerfSupport.swift`; Benchmark `WeekPerfBenchmarkTests`.

## Offen / ungeprüft
- MariaDB nicht ausgeführt (nur SQLite). Middleware nutzt nur Fluent-Standardabfragen; Migration `unique(account_id, month)` ist portabel, aber ungetestet auf MariaDB.
- Schreibpfade ohne Fluent-Modell-Middleware (Massen-`delete()`/`update()` auf diese Tabellen, Roh-SQL, DB-Restore) markieren nicht; im Code gibt es heute keine außer dem Löschen stornierter Segmente (für die Auswertung irrelevant). Bei Rolling-Updates könnte eine alte Instanz ohne Marken schreiben (Migration läuft vor dem Backend, Risiko gering).
- Jeder Schreibzugriff kostet 1-2 Zusatzanweisungen für die Marke (Importe großer Dateien entsprechend mehr).
- Prozess-Cache ist je Replikat; Gültigkeit hängt an der DB-Marke.
