# ADR-0025: Urlaubsplanung (Urlaubsvorschläge)

Status: Umsetzungsentscheidung von Paket V2 (Backend; Nutzerwunsch: Empfehlungen, wann Urlaub genommen werden sollte); Lead-Prüfung offen. Alles, was nicht aus dem Wunsch folgt, sind Annahmen des Pakets.

## Kontext

Das Urlaubskonto (ADR-0005) kennt Anspruch, Buchungen und Feiertage der Region, aber keine Hilfe bei der Frage „wann lohnt sich Urlaub?“. Schulferien gibt es bewusst nur als selbst eingetragene Zeiträume (KONZEPT: keine eingebauten Termine). Planung bleibt Planung: der Endpunkt bucht nichts und ändert nichts.

## Entscheidungen

1. **Endpunkt** `GET /api/v1/vacation/suggestions?from&to&maxVacationDays&minDaysOff&limit` (Vertrag v0.22.0, additiv, kein Schemawechsel). Modul `planning` über das Präfix `/vacation`, Sitzung wie die übrigen Lesezugriffe, ausschließlich Daten des eigenen Kontos. Standard: `from` heute (Zeitzone des jüngsten Arbeitsmodells, sonst Europe/Berlin), `to` Ende des nächsten Kalenderjahres, `maxVacationDays` 10 (1 bis 60), `minDaysOff` 4 (1 bis 60), `limit` 20 (1 bis 100). Ungültige Werte 400 `invalid`; mehr als 18 Kalendermonate zwischen `from` und `to` 400 `range_too_large`; Jahre außerhalb 1990 bis 2100 sind ungültig.
2. **Reiner Algorithmus** (`VacationSuggestionEngine`, eigene Datei, ohne Datenbank, Uhr und Netzwerk; der Dienst `VacationSuggestionService` lädt nur Eingaben). Kostentage sind Arbeitstage des gültigen Arbeitsmodells (4-Tage-Woche inklusive; Tage ohne Modell gelten Montag bis Freitag), die weder Feiertag (Region der Urlaubseinstellungen plus eigene Feiertage) noch bereits Urlaub sind. Ein Fenster ist durch seinen ersten und letzten Kostentag bestimmt und reicht über alle freien Tage drumherum (Wochenenden, Feiertage, freie Modelltage, bereits gebuchter Urlaub). Dadurch ist es für seine Kosten maximal. Fenster brauchen mindestens einen Kostentag, höchstens `maxVacationDays` Kostentage und mindestens `minDaysOff` Kalendertage. Ein Feiertag auf einem freien Tag (Wochenende) spart nichts und wird nur genannt.
3. **Rangfolge und Überlappung**: `efficiency` = `totalDaysOff` / `vacationDaysNeeded` (exakter Vergleich per Kreuzmultiplikation, ausgegeben auf 2 Stellen gerundet), dann mehr freie Tage, dann früherer Beginn. Gierige Auswahl ohne Überlappung (sich berührende Fenster sind erlaubt), bis `limit`.
4. **Art (`kind`)**: überlappt das Fenster eigene Schulferien: `school_holiday_extension`; sonst mit Feiertag und höchstens 2 Urlaubstagen `bridge`, mit Feiertag und mehr Tagen `holiday_cluster`, ohne Feiertag `long_break`. Schulferien verändern nicht, was frei ist; sie geben dem Fenster nur Art und Anzeige (`schoolHolidays[]`).
5. **Konflikte werden markiert, nie ausgeblendet** (`conflicts[] {date, type}`, sortiert je Tag): `absence` (aktive Krankheit/Sonstiges), `school_day` (Plantag Modus `school`), `plan` (Plantag mit geplanter Arbeit, Modus ungleich `off`/`school`), `already_vacation` (aktiver Urlaub, jeder Status außer rejected/cancelled; halbe Tage zählen als ganzer, vereinfachend). Bereits gebuchte Urlaubstage sind nie Vorschlag, liegen aber in angrenzenden Fenstern kostenlos.
6. **Budget**: Aus `VacationService.balance(year:)` (gleiche Logik wie `GET /vacation/balance`), in Tagen (halbe Tage möglich). `budget` gilt für das Jahr von `from`: `entitlementDays` = Anspruch + Übertrag + Korrekturen (bzw. Stichtagsbestand) = verfügbar + gebucht, `takenDays` = approved/taken, `plannedDays` = planned/requested, `remainingDays` = verfügbar nach geplantem Urlaub. `fitsBudget` prüft die Urlaubstage je Kalenderjahr gegen den Rest dieses Jahres, **jeder Vorschlag einzeln** (nicht kumulativ über die Liste). `remainingAfter` = Rest des Jahres von `start` minus die Urlaubstage dieses Jahres. Ohne gespeicherte Urlaubseinstellungen gelten die Standardwerte des Kontostands (30 Tage); mit Anspruch 0 passt kein Vorschlag, wird aber weiter gezeigt.
7. **`id`**: erste 16 Hexzeichen von SHA-256 über `start|end|vacationDates` (stabil für gleiche Fenster, auch bei anderem Abfragezeitraum).

## Offen

- Kumulative Budgetprüfung über mehrere ausgewählte Vorschläge (Client-seitig oder später).
- Halbe Urlaubstage in Vorschlägen; Rechtsprofile und Schulferien der Berufsschule als Datenquelle.
- MCP-Werkzeug für Vorschläge (bisher nur REST).
