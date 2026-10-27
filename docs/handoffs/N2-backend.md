# N2 – Feiertage und ICS-Kalenderabo (Backend)

Stand: 26.10.2026, Branch `n2-holidays-ics` (von `main` 1a17088). Vertrag `0.31.0`, Migration `n2.create_calendar_feeds`.

## Befund Feiertage

Die eingebauten Tabellen in `HolidayCalendar` sind vollständig: Neujahr, Karfreitag, Ostermontag, 1. Mai, Himmelfahrt, Pfingstmontag, 3. Oktober, 1./2. Weihnachtstag plus alle länderspezifischen Tage (Heilige Drei Könige, Frauentag, Fronleichnam, Mariä Himmelfahrt Saarland, Weltkindertag, Reformationstag, Allerheiligen, Buß- und Bettag; Brandenburg Oster- und Pfingstsonntag) für alle 16 Länder, Jahre 1990 bis 2100. Es fehlt kein Tag in den Daten. Der Eindruck „fehlender“ Feiertage kam aus der Anzeige:

1. Ein Feiertag wirkt nur an einem Arbeitstag des Arbeitsmodells (`mark = holiday`). 25./26.12. auf einem Wochenende oder Tage vor dem ersten Arbeitsmodell blieben `off`/`work`, ohne den Namen irgendwo zu nennen. Fix: `TimeWeekDay.holidayName` (immer vorhanden, null ohne Feiertag) unabhängig vom Arbeitsmodell.
2. Ohne Modul `planning` liefert der Server keine Feiertage (`holidayName` null).
3. Die Region kommt aus den Urlaubseinstellungen (Standard `DE-ST`); ein falsches Bundesland zeigt Feiertage eines anderen Landes. Clients sollten die Region sichtbar machen oder bei der Einrichtung abfragen.

24.12. und 31.12. sind keine gesetzlichen Feiertage; `CalendarDayKind` kennt nur `holiday` und `school_holiday`. Ein Halbtags-Typ würde bestehende Clients brechen und die Abzugslogik berühren, deshalb bewusst nicht aufgenommen. Betriebsfreie Tage trägt die Person über `POST /calendar/custom-days` als eigenen Feiertag ein (dort wirken sie wie gesetzliche). Offene Entscheidung für den Lead: optionaler Typ `company_day`/`half_day`, falls gewünscht.

Tests: `HolidayCoverageTests` (je Region 2026 und 2027 gegen unabhängige Datumstabelle; 1.1./25./26.12. für alle Region/Jahr-Kombinationen 1990 bis 2100; 24./31.12. nie enthalten) und `testWeekOverviewNamesHolidaysOnWeekendsAndOutsideModels`.

## ICS-Abo

Neu: `Sources/TimetrackKit/CalendarFeeds.swift`. Verwaltung (Sitzung, CSRF, nicht MCP, keine Modulbindung):

| Aufruf | Antwort |
| --- | --- |
| `GET /api/v1/me/calendar-feeds` | Liste aktiver Abos ohne Token |
| `POST /api/v1/me/calendar-feeds` Body `{"label":"iPhone","include":["absences","holidays"],"expiresInDays":365}` | `201` mit `token` und `path` (`/ics/<token>.ics`) nur hier; `include` Standard `absences`+`holidays`, erlaubt `absences`, `holidays`, `plan`, `tracked`; `expiresInDays` optional; über 10 aktive Abos `409 too_many_calendar_feeds` |
| `DELETE /api/v1/me/calendar-feeds/{id}` | `204`, idempotent; fremde ID `404` |

Abruf `GET /ics/{token}.ics` ohne Anmeldung: `text/calendar; charset=utf-8`, CRLF, Zeilenfaltung bei 75 Oktetten, stabile UIDs (`absence-<id>@host`, `holiday-<datum>-<schlüssel>@host`, `plan-<datum>@host`, `tracked-<datum>@host`, Host aus `PUBLIC_BASE_URL`), `DTSTAMP`, ganztägig `VALUE=DATE` mit exklusivem `DTEND`, `STATUS` (CONFIRMED/TENTATIVE), `TRANSP`, `CATEGORIES`, `REFRESH-INTERVAL`/`X-PUBLISHED-TTL` eine Stunde. Fenster -60 bis +400 Tage ab heute (Zeitzone des jüngsten Arbeitsmodells, sonst Europe/Berlin). Titel mit Status: `Urlaub (genehmigt|geplant|beantragt|genommen)`, `Krank (...)`, `Freistellung (...)`, `Abwesenheit (...)`; abgelehnt/storniert entfallen. Notizen, Orte, Dokumentzustand werden nie ausgegeben. Header: `ETag` (Hash des Inhalts, `If-None-Match` gibt 304), `Last-Modified`, `Cache-Control: private, max-age=900, must-revalidate`, `Referrer-Policy: no-referrer`, `X-Robots-Tag`, `nosniff`. Fehler: 404 (`no-store`, ununterscheidbar bei unbekannt/widerrufen/abgelaufen/falsches Suffix/deaktiviertes Konto), 429 mit `Retry-After`. Ratenbegrenzung 60 je 5 min je Abo, 30 Fehlversuche je 5 min je Client. Das Logschwärzen (`TriggerTokenScrubber`) erfasst `/ics/<token>`. Ohne Modul `planning` entfallen Abwesenheiten, Feiertage, Plan; `tracked` bleibt.

Kontoexport `calendar-feeds.json` ohne Token; Kontodeaktivierung/-löschung widerruft bzw. entfernt die Abos (`AccountEraser`).

## Prüfung

Vollständiger `swift test --no-parallel` (SQLite): 410 Tests, 42 übersprungen, 0 Fehler. 12 neue Tests (2 Feiertage, 2 ICS-Writer, 8 HTTP-Tests: Verwaltung/Hash, Inhalt und Kontentrennung, Plan/Tracked/Modul, Caching/304, 404-Orakel, Ratenlimits, MCP/Export/Löschung, Wochenansicht). Offen: Praxistest mit Apple Kalender/Google/Outlook (Abo-URL `webcal://` bzw. `https://`), MariaDB-Lauf, PWA-/Apple-Oberfläche für die Verwaltung und für `holidayName`. Hinweis Google Kalender aktualisiert Abos nur alle paar Stunden bis Tage, unabhängig von `REFRESH-INTERVAL`.
