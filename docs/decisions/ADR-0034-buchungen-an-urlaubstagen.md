# ADR-0034: Buchungen an Urlaubstagen zählen als Überstunden (VB1)

Status: **Vorschlag**, umgesetzt im Branch `vacation-bookings` (nur Tests und Doku, keine Vertragsänderung). Nutzerwunsch vom 02.11.2026: „Buchungen sollen auch während Urlaub zugelassen werden. Das wird dann einfach wie eine Überstunde behandelt.“ Die Ausgestaltung unten (insbesondere Punkt 2) ist ein Vorschlag, keine bestätigte Nutzerentscheidung.

## Befund

Das Backend lehnt Buchungen an Urlaubstagen nirgends ab. Weder `POST /time/segments`, `PATCH`, `POST /time/timer/start|stop`, Auslöse-Links, Automatik, MCP noch Import prüfen die Tagesmarkierung; Fehlercodes für „Tag gesperrt“ gibt es nicht. Die Tagesauswertung (ADR-0004, `TimeEngine.evaluate`) rechnet an Urlaubstagen (Markierung `vacation`, aus einer gebuchten Abwesenheit oder ausdrücklich gesetzt) das Soll auf 0 (halber Urlaubstag: halbes Tagessoll, `targetOverrideSeconds`) und lässt die tatsächliche Arbeitszeit unverändert in `evaluatedWorkSeconds` einfließen (mit der üblichen Rundung am ersten Beginn/letzten Ende und festen Pausen); die Gutschrift ist 0. Die Tagesdifferenz `Ist + Gutschrift − Soll` ist damit genau die gebuchte Zeit (bzw. gebuchte Zeit minus Resttag-Soll). Zeitkonto, Woche, Statistik (Über-/Unterzeit), Export und ICS (`tracked`) nutzen dieselbe Auswertung (`PreparedEvaluation`) und zeigen das ohne Sonderfall. Der Nutzerwunsch ist damit im Backend bereits erfüllt; gesperrt war nur in Oberflächen (siehe Handoff `docs/handoffs/VACATION-BOOKINGS.md`).

## Regel (Vorschlag)

1. **Buchen ist erlaubt** an Urlaubstagen, ganz oder halb, beantragt oder genehmigt. Keine neuen Fehlercodes, keine Hinweispflicht des Servers.
2. **Der Urlaubstag bleibt Urlaub.** Abwesenheit, Tagesmarkierung `vacation`, Urlaubskonto-Verbrauch (`bookedHalfDays`), Kalender-/ICS-Eintrag und die Zählung „Urlaubstage“ in Woche und Statistik bleiben unverändert. Begründung: Die Buchung ist ein zusätzlicher Ist-Wert, kein Widerruf des Urlaubs; der Nutzer hat den Wunsch als „wie eine Überstunde“ formuliert, nicht als „Urlaub stornieren“. Eine automatische Rückgabe des Urlaubstags wäre eine stille Datenänderung und würde dem Arbeitgeber-Antrag widersprechen. Wer den Tag zurückgeben will, ändert die Abwesenheit (bestehender Weg). Alternative (offen): Vorschlag „Urlaub zurückgeben?“ als Client-Hinweis.
3. **Saldo:** Gebuchte Zeit zählt vollständig als Überstunde. Ganzer Urlaubstag: Soll 0, Differenz = bewertete Zeit. Halber Urlaubstag: Differenz = bewertete Zeit − halbes Tagessoll (die erste Hälfte der Buchung füllt den Resttag, der Rest ist Überstunde; die Gesamtsumme gegenüber „ohne Buchung“ ist die volle gebuchte Zeit). Der laufende Tag zählt wie überall erst ab morgen (ADR-0032).
4. **Rundung, Pausen:** unverändert. Gerundet werden nur der erste Beginn und das letzte Ende (15 Minuten zugunsten des Arbeitnehmers), innere Grenzen und tatsächliche Pausen bleiben; feste Pausen des Arbeitsmodells und Pausenhinweise gelten wie an Arbeitstagen und nur anhand tatsächlicher Zeiten.
5. **Hinweis statt Sperre (nur Client):** Ein Hinweis „Buchung an Urlaubstag“ lässt sich aus vorhandenen Feldern ableiten (`mark = vacation` und `workSeconds > 0` bzw. `segmentsCount > 0` in `GET /time/days/{date}` und `GET /time/weeks/{isoWeek}`). Dafür ist keine Vertragsänderung nötig; ein Serverfeld wurde bewusst nicht ergänzt.

## Grenzen und offene Punkte

- **Krank und Freistellung:** gleiche Auswertung, ebenfalls keine Sperre im Backend (Tests belegen es); nicht geändert, da nicht gefordert.
- **Ausdrückliche Gutschrift:** Ist an einem Urlaubstag (oder Krank/Freistellung/Feiertag) per `PUT /time/days/{date}` eine Gutschrift (`creditSeconds`) gesetzt, ersetzt diese die Arbeitszeit (`replacesWork`); Buchungen zählen dort nicht und werden nicht gerundet. Das wurde nicht geändert (bewusste Gutschrift, Importe nutzen sie). Entscheidung offen: soll bei Urlaub die Gutschrift zusätzlich statt ersetzend gelten?
- **Plan/Ist:** An blockierten Tagen (Feiertag, Urlaub, Krank, Freistellung; halber Urlaubstag blockiert nicht) bleibt `planActualDifferenceSeconds = null` (Plan zählt 0, ADR-0021). Eine Buchung erscheint dort als `workSeconds`/`balanceSeconds`, nicht als Abweichung vom Plan.
- **Zeitnachweis-Export (Arbeitszeit-Tabelle):** Die Zeile trägt weiter die Bemerkung „Urlaub“, zeigt aber die gebuchten Zeiten und die volle gebuchte Zeit als Differenz; die Soll-Formel passt dort nicht zum Tagessoll 0, daher erscheint die vorhandene Warnung „Soll abweichend“ in der Bemerkung. Das ist gewollt sichtbar.
- **Feiertage:** gleiche Auswertung; Buchungen an Feiertagen zählen ebenfalls vollständig (Soll 0), ohne Änderung.

## Tests

`VacationBookingTests` (ganzer und halber Urlaubstag mit Saldo vor/nach, Urlaubskonto unverändert, Woche, Statistik, Löschen der Buchung stellt den Saldo wieder her; Krank/Freistellung/beantragter Urlaub/ausdrückliche Markierung; Timer start/stop an einem Urlaubstag) und `WorktimeExportTests.testVacationDayWithBookingsShowsBookedTimeAsBalance`.
