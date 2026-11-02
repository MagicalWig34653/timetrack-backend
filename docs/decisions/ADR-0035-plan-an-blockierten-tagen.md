# ADR-0035: Planblöcke an Urlaubs-, Krank-, Freistellungs- und Feiertagen (PLAN-OFFDAY)

Status: **Vorschlag**, umgesetzt im Branch `plan-offday` (Vertrag 0.42.0). Nutzerentscheidung vom 02.11.2026: Im Wochenplaner sollen Planblöcke auch an Urlaubs-, Krank-, Freistellungs- und Feiertagen angelegt werden können. Die Wertung der Zeit unten (insbesondere Punkt 2 bis 4) ist ein Vorschlag analog ADR-0034, keine bestätigte Nutzerentscheidung.

## Befund

- Das Backend hat das Speichern nie gesperrt: `PUT /plan/days/{date}` und `PUT /plan/weeks/{isoWeek}` nehmen Pläne an blockierten Tagen an (ADR-0021, Punkt 4); der Plan blieb sichtbar. Die Sperre liegt in den Oberflächen (PWA `blockedBy`/WeekGrid, Apple `PlanWeekDay.blockedBy`).
- Gewertet wurde der Plan dort mit 0: `PlanWeekDay.plannedSeconds` und `TimeWeekDay.plannedSeconds` waren 0, `planActualDifferenceSeconds` war `null`. Damit blieb ein geplanter Arbeitsblock an einem Urlaubstag in Summen und Plan/Ist unsichtbar.
- Plan bucht nie Ist-Zeit. Zeitkonto, Zeitkonto-Vorschau (`/time/account`), Statistik, Auswertung (`TimeEngine`), Export (Zeitnachweis) und Berichtsheft lesen keine Plandaten und sind nicht betroffen. Plandaten lesen nur: Plan- und Zeitwoche, Planfreigabe, ICS-Abo (Option `plan`), Kontoexport (`plan-days`), MCP (`list_plan_days`, `set_plan_day`, `view_shared`) und der Urlaubsvorschlag (zählt Tage mit Plan als geplante Arbeitstage).

## Regel (Vorschlag)

1. **Planen ist erlaubt** an Feiertagen und an Tagen mit Urlaub, Krank oder Freistellung (ganz oder halb, beantragt oder gebucht). Keine neuen Fehlercodes, keine Serversperre.
2. **Der Tag behält seine Markierung.** Urlaub bleibt Urlaub (Verbrauch `bookedHalfDays`, Zählung in Woche/Statistik, Kalender, ICS), Krank bleibt Krank usw. `blockedBy` bleibt als reine Information erhalten und bedeutet „Tag ist ein Nichtarbeitstag", nicht „Planen verboten".
3. **Planzeit zählt mit ihrer Dauer als geplante Mehrzeit.** Das Soll bleibt 0 (halber Urlaubstag: Resttag-Soll, ein halber Urlaubstag war nie `blockedBy`). `plannedSeconds` ist die Plandauer; `PlanWeek.totals.plannedSeconds` und `differenceSeconds` (= geplant − Soll) enthalten sie, die Differenz ist dort also die volle Plandauer. `TimeWeek.summary.plannedSeconds` summiert sie ebenfalls.
4. **Plan/Ist:** `planActualDifferenceSeconds` = bewertete Ist-Arbeitszeit + Gutschrift − Plandauer, auch an diesen Tagen (nicht für künftige Tage und ohne Plandauer weiterhin `null`). Ohne Buchung ist die Abweichung also minus Plandauer, mit einer Buchung (ADR-0034) steht sie als Ist daneben. Der Saldo (`balanceSeconds`) ist unverändert: der Plan bucht nichts, geplante Mehrzeit wird erst durch tatsächlich gebuchte Zeit Überstunde.
5. **Freigaben:** unverändert. Blöcke erscheinen mit `start`, `end`, `kind`; Ort und Notiz bleiben unsichtbar, auch an Urlaubstagen. Die Freigabe sagt nichts über die Wertung. Empfänger sehen keine Abwesenheit, außer der Eigentümer gibt den Umfang `vacation` frei.
6. **ICS, Kontoexport, MCP:** unverändert (Pläne wurden dort schon immer ausgegeben, ohne Wertung). Der ICS-Planeintrag erscheint an Urlaubstagen zusätzlich zum Urlaubstermin.
7. **Urlaubsvorschlag:** unverändert; ein Plantag mit Arbeitsmodus zählt weiter als geplanter Arbeitstag. Offen: ob ein Plan an einem Urlaubstag den Vorschlag stören soll.

## Folgen und offene Punkte

- Vertrag 0.42.0: nur Beschreibungen und Wertung, keine neuen Felder, keine Migration.
- Clients müssen die Sperre entfernen (Handoff `docs/handoffs/PLAN-OFFDAY.md`).
- Offen: Hinweis im Client „Plan an Urlaubstag zählt als Mehrzeit"; ob die geplante Mehrzeit in einer späteren Zeitkonto-Vorschau („wenn alles wie geplant läuft") ausgewiesen werden soll (heute nicht, Plan bucht nie).
- Nachtrag zu ADR-0021 Punkt 4, ADR-0031 und ADR-0034 (Plan/Ist an blockierten Tagen): ersetzt durch diese Regel.
