# ADR-0031: Mehrere Planblöcke pro Tag (P13)

Status: akzeptiert für P13 (24.10.2026). Baut auf ADR-0021 auf.

## Kontext

Ein Zeitfenster pro Plantag kann geteilte Schichten und eine Kombination aus Berufsschule und Arbeit nicht ausdrücken. PWA und native Apps benötigen dieselbe Repräsentation. Planung bucht weiterhin keine Ist-Zeit.

## Entscheidung

- Ein Plantag bleibt ein Datensatz pro Konto und Datum. `blocks` ist eine geordnete JSON-Liste mit höchstens 32 Intervallen. Jeder Block enthält `start`, `end` (lokal `HH:mm`, am selben Datum, Beginn vor Ende), `kind` (`work`, `school`, `travel`, `office`, `home`, `customer`) und optional `placeId` und `note`. Gleiche Grenze zweier Blöcke ist erlaubt; Überschneidungen und ungeordnete Eingaben sind ungültig. Orte müssen dem Konto gehören und aktiv sein.
- `mode` bleibt für alte Clients und die Tagesdarstellung erforderlich. Bei `mode=off` darf die Blockliste nur leer sein. Ein `PUT` ersetzt den ganzen Plantag; wenn `blocks` mitgeschickt wird, hat die Liste Vorrang vor den alten Zeitfeldern. Die Antwort enthält stets `blocks` und leitet `plannedStart` vom ersten Beginn, `plannedEnd` vom letzten Ende, `plannedBreakMinutes` aus den Lücken und `plannedSeconds` aus der Summe der Blockdauern ab. Ohne Blöcke bleiben die Zeiten null; ein Altfall mit Pause größer als dem Zeitfenster behält seine bisherige Dauer 0.
- Ein älterer Client kann weiter `plannedStart`, `plannedEnd` und `plannedBreakMinutes` schreiben. Die Pause wird als mittige Lücke zwischen zwei gleichartigen Blöcken dargestellt. Bei einer Pause von 0 entsteht ein Block. Ist die alte Pause mindestens so lang wie das Zeitfenster, ist kein positiver Block möglich; der Altwert bleibt mit `plannedSeconds=0` erhalten, bis der Tag ersetzt wird.
- Migration `p13.add_plan_blocks` legt die JSON-Spalte an und wandelt vorhandene Zeitpläne um. Zeitpläne ohne Pause ergeben einen Block, mit darstellbarer Pause zwei Blöcke. Sie verändert Ist-Zeiten nicht. Rücknahme entfernt ausschließlich die neue Spalte; die alten Felder bleiben erhalten.
- Wochenansichten berechnen die Plansumme aus den Blöcken. Die Zeitwoche zeigt zusätzlich `planBlocks` und `planActualDifferenceSeconds`. `planHints` bewertet die im Plan sichtbaren Lücken und Arbeitsstrecken nach den Schwellen des Erwachsenenprofils (`planned_break_short`, `planned_work_stretch_long`, `planned_break_part_short`); dies sind unverbindliche Planungshinweise. Die bisherige rechtliche Bewertung tatsächlicher Zeitabschnitte bleibt getrennt. Planfreigaben geben pro Block nur Beginn, Ende und Art weiter. Export des eigenen Kontos und MCP enthalten die vollständigen Blöcke unter den bestehenden Kontorechten.
- Fehler (HTTP 400): `plan_time_invalid`, `plan_blocks_invalid`, `plan_blocks_overlap`, `plan_kind_invalid`, `plan_note_invalid`. Unbekannte oder fremde Orte bleiben 404.

## Folgen

Bestehende Clients können weiterhin lesen und schreiben. Sie sehen bei geteilten Schichten nur den äußeren Rahmen und die aufsummierten Lücken. Ein alter `PUT` ersetzt die feinere Blockaufteilung vollständig; Clients sollen vor dem Schreiben ab API 0.34.0 `blocks` verwenden. Das ICS-Abo (N2) bleibt bei Ganztagsterminen und nennt Blöcke gemischter Tage in der Beschreibung (ohne Ort und Notiz); native Kalenderkonflikte bleiben Arbeit der geplanten EventKit-Brücke.
