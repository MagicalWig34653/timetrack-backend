# ADR-0029: Betriebstage (24.12. und 31.12.) je Konto (N4)

Status: umgesetzt im Branch `n4-company-days`; Lead-Prüfung offen.

## Entscheidung

24.12. und 31.12. sind keine gesetzlichen Feiertage, werden aber in vielen Betrieben ganz oder halb frei gegeben. Jedes Konto kann dafür in den Urlaubseinstellungen (dort liegt auch die Region) eine Liste fester Monat/Tag-Regeln führen: `companyDays: [{month, day, treatment, name}]`.

- `treatment`: `none` (Standard, bisheriges Verhalten), `half` oder `full`.
- Vorgeschlagen sind 24.12. (Heiligabend) und 31.12. (Silvester); `GET /vacation/settings` listet sie immer, auch unbehandelt. Zusätzlich sind bis zu 12 Regeln insgesamt mit eigenem Datum und Namen erlaubt (kein 29.02., je Datum eine Regel, Name höchstens 80 Zeichen; ohne Namen „Betriebsfreier Tag“). Jahresbezogene Einzeldaten (z. B. Brückentag nur 2027) bleiben Sache der vorhandenen eigenen Kalendertage (`POST /calendar/custom-days`, wirken wie `full`).
- `PUT /vacation/settings` ohne `companyDays` lässt die Regeln unverändert (ältere Clients löschen nichts); mit dem Feld ersetzt es die Liste.
- Ein gesetzlicher Feiertag am selben Datum hat Vorrang; die Betriebstagsregel entfällt dann für dieses Jahr.

## Wirkung

| | `none` | `half` | `full` |
| --- | --- | --- | --- |
| Soll (Arbeitstag des Modells) | unverändert | 50 % (`targetOverrideSeconds` = Tagessoll / 2) | 0 |
| Markierung `mark` | work | work (Anzeige über `holidayName`/`companyDayTreatment`) | holiday (`markSource` holiday) |
| Urlaubsverbrauch | 2 halbe Tage | höchstens 1 halber Tag (auch bei vollem Urlaubstag) | 0 (wie Feiertag) |
| Wochenende / Tag ohne Arbeitsmodell | – | nur Name sichtbar, kein Soll, kein Verbrauch | nur Name sichtbar, `mark` off |

Begründung für `half`: Der Betrieb gibt die halbe Schicht frei, ein Urlaubstag deckt nur die andere Hälfte. Weniger als einen halben Tag abzuziehen wäre ein Geschenk, mehr eine Doppelbelastung; ein halber Urlaubstag ist die am wenigsten überraschende Regel (deckt sich mit der Praxis „Heiligabend = halber Urlaubstag“). Urlaub (auch mit Halbtagsmarke) an einem `half`-Tag lässt kein Rest-Soll übrig. Ein ausdrücklich gesetztes `targetOverrideSeconds` des Nutzers und jede ausdrückliche Tagesmarkierung haben weiter Vorrang.

Zeitkonto, Statistik, Wochen- und Planwochen-Soll, Kontoexport und Auswertungen verwenden dieselbe Tagesauswertung (`PreparedEvaluation`), sie folgen der Regel ohne eigenen Sonderfall. `half`-Tage sind in Vorschlägen für Urlaubsplanung keine Feiertage (sie kosten Urlaub), `full`-Tage schon.

## Technischer Vertrag (additiv, Vertrag 0.32.0)

- Keine neuen Enum-Werte. `CalendarDayKind` bleibt `holiday|school_holiday`; Betriebstage erscheinen in `GET /calendar/holidays` als `kind: holiday`, `source: builtin` mit dem neuen Feld `companyTreatment` (`half|full`, sonst null). Alte Clients zeigen einen Feiertag; bei `half` ist das ungenau, aber harmlos.
- `TimeWeekDay.holidayName` nennt den Betriebstag (Heiligabend/Silvester), neues `TimeWeekDay.companyDayTreatment` (`half|full|null`).
- ICS-Abo: Betriebstage in der Kategorie `Betriebsfrei`, `half` mit Titelzusatz „(halber Tag)“.
- Migration `n4.add_company_days` (optionale JSON-Spalte `vacation_settings.company_days`, `NULL` = keine Regeln). Der Kontoexport enthält `companyDays`.
- MCP: `list_holidays` und alle bestehenden Lese-Werkzeuge liefern die Felder über dieselben Dienste.

## Offen

Regeln gelten für alle Jahre gleich; Betriebsurlaub einzelner Jahre über eigene Kalendertage. Keine Rechtsberatung: ob ein Betriebstag tarifvertraglich oder arbeitsvertraglich anzurechnen ist, entscheidet die Person.
