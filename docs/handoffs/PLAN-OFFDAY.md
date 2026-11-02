# Handoff PLAN-OFFDAY: Planblöcke an Urlaubs-, Krank-, Freistellungs- und Feiertagen

Branch `plan-offday`, ADR-0035 (Vorschlag), Vertrag **0.42.0**. Nutzerwunsch 02.11.2026: Im Wochenplaner Planblöcke auch an diesen Tagen anlegen. Die Wertung ist ein Vorschlag analog ADR-0034, keine Nutzerentscheidung.

## Backend (erledigt)

- Das Speichern war nie gesperrt (`PUT /plan/days`, `PUT /plan/weeks`). Geändert ist nur die Wertung: `plannedSeconds` (Plan- und Zeitwoche) ist an blockierten Tagen die Plandauer statt 0; `PlanWeek.totals`, `TimeWeek.summary.plannedSeconds` enthalten sie; `TimeWeekDay.planActualDifferenceSeconds` ist dort gesetzt (nicht künftig, mit Plandauer). Soll bleibt 0, Tagesmarkierung, Urlaubsverbrauch und Saldo unverändert. Code: `PlanningServices.week`, `TimeWeek.dto`. Keine Migration, keine neuen Felder.
- Nicht betroffen (lesen keine Plandaten oder unverändert): Auswertung, Zeitkonto und Vorschau, Statistik, Zeitnachweis-Export, Berichtsheft. Unverändert und ohne Wertung: Planfreigabe (Start/Ende/Art, kein Ort/Notiz), ICS-Abo, Kontoexport, MCP, Urlaubsvorschlag.
- Tests: `scenarioPlanOnBlockedDays` (Urlaub, Krank, Freistellung, Feiertag, Halbtag, Buchung am Urlaubstag, Konto unverändert, Freigabe ohne Leck) und angepasste Erwartungen in `scenarioPlanWeek` (`WeekPlanningTests`).

## Anpassungsbedarf PWA (nicht geändert)

1. `WeekGrid` / `grid-edit.ts`: überall, wo `blockedBy` das Anlegen, Ziehen, Verschieben, Kopieren oder Bearbeiten von Blöcken sperrt (deaktivierte Spalte, schraffierte Fläche, Gesten-Abbruch, Hinweis), die Sperre entfernen. `blockedBy` nur noch als Anzeige (Markierung „Urlaub/Krank/Feiertag/Frei") verwenden.
2. Plansummen, die `blockedBy` auf 0 zwingen oder blockierte Tage auslassen, entfernen; `plannedSeconds` des Servers direkt verwenden.
3. Plan/Ist-Ansicht: `planActualDifferenceSeconds` nicht mehr bei `mark` in Urlaub/Krank/Feiertag/Freistellung ausblenden.
4. Optionaler Hinweis (Deutsch): „Plan an einem Urlaubstag zählt als geplante Mehrzeit." Mock-Server/Fixtures auf 0.42.0 anheben.

## Anpassungsbedarf Apple (nicht geändert)

`PlanWeekDay.blockedBy` / `isBlocked` im Planer (Zeitraster, Gesten, Tageskopf, Summenberechnung) wie oben: keine Sperre, Server-`plannedSeconds` verwenden, Plan/Ist an diesen Tagen anzeigen. Modelle brauchen keine neuen Felder.

## Offene Entscheidungen

1. Gilt die Wertung (geplante Mehrzeit bei Soll 0, Tag bleibt Urlaub) so? Alternativen: Plan zählt nicht (wie bisher, aber editierbar) oder der Tag wird bei Plan zum Arbeitstag.
2. Soll ein Plan an einem Urlaubstag den Urlaubsvorschlag beeinflussen (heute: zählt als geplanter Arbeitstag)?
3. Soll eine Zeitkonto-Vorschau „bei Plan erfüllt" geplante Mehrzeit ausweisen (heute nicht; Plan bucht nie).
