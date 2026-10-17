# ADR-0021: Wochenplanung und Wochenübersicht

Status: Umsetzungsentscheidung von Paket K1 (Nutzerwunsch 17.10.2026: grob vorplanen, von wann bis wann man arbeitet; Wochenübersicht ähnlich Kalender, gröber, mit Stunden, Bilanz und kleiner Zusammenfassung mit Icons); Lead-Prüfung offen. Alles, was nicht aus dem Wunsch folgt, sind Annahmen des Pakets.

## Kontext

Planung (ADR-0005) kannte je Tag nur Arbeitsform, Ort und Notiz. „Planung, Standortsignal und tatsächliche Zeit sind unterschiedliche Objekte“ (KONZEPT): ein Plan bucht nie Zeit und ändert keine Auswertung.

## Entscheidungen

1. **Geplante Zeiten am Plantag** (Vertrag v0.17.0, additiv): `PlanDayInput`/`PlanDay` erhalten optional `plannedStart`/`plannedEnd` (lokale Uhrzeit `HH:mm` in der Zeitzone des Arbeitsmodells; es wird nicht umgerechnet), `plannedBreakMinutes` (0 bis 600) und schreibgeschützt `plannedSeconds` = Ende − Beginn − Pause, nie negativ, serverseitig berechnet. Beide Zeiten oder keine; Beginn < Ende am selben Tag. **Keine Nachtschicht über Mitternacht** (Ende > Beginn zwingend); wer so arbeitet, plant zwei Tage oder lässt Zeiten weg. Pause nur zusammen mit Zeiten. Modus `off` ignoriert Zeiten (werden verworfen). Alte Clients (nur `mode`/`placeId`/`note`) funktionieren unverändert; `PUT` ersetzt weiterhin den ganzen Tageseintrag, ein Client muss vorhandene Zeiten also mitsenden (die PWA tut das im Kalenderformular).
2. **Feste Pausen des Arbeitsmodells werden nicht abgezogen.** Der Plan ist grob; die geplante Pause steht ausdrücklich am Plantag. Die tatsächliche Bewertung (ADR-0004) bleibt davon unberührt.
3. **Speicherung**: drei additive, nullbare Spalten an `plan_days` (Migration `k1.add_plan_day_times`, je Spalte eine Anweisung wegen SQLite; Revert löscht sie einzeln). Vorhandene Zeilen bleiben gültig. Konto-Export (`plan-days`) enthält die neuen Felder.
4. **Wochenendpunkte** (Modul `planning` über das Präfix `/plan`, Kern bei `/time`):
   - `GET /plan/weeks/{isoWeek}` (`2026-W44`, Montag bis Sonntag, ISO 8601): sieben Tage mit `plan`, `targetSeconds` aus der vorbereiteten Tagesbewertung (X1) **ohne Ist-Zeiten**, `plannedSeconds` (effektiv: 0 bei blockiertem Tag), `blockedBy` und Summen `{targetSeconds, plannedSeconds, differenceSeconds}`.
   - `blockedBy` = `holiday`, `vacation`, `sick` oder `excused`, wenn Feiertag/Abwesenheit/Tagesmarke den Plan überstimmen (Vorrang wie in der Tagesbewertung). Ein halber Urlaubstag blockiert nicht. Ein gespeicherter Plan an einem blockierten Tag bleibt erhalten und sichtbar (`plan`), zählt aber nicht.
   - `PUT /plan/weeks/{isoWeek}` `{replace?, days: [≤ 7 Einträge mit date + PlanDayInput]}`: alles oder nichts in einer Transaktion; jeder Eintrag ersetzt den Tag; `replace=true` löscht zusätzlich nicht genannte Pläne der Woche. Daten außerhalb der Woche oder doppelt: `week_day_invalid`. Das Speichern an einem blockierten Tag ist erlaubt (kein Datenverlust beim Kopieren).
   - `GET /time/weeks/{isoWeek}` (Wochenübersicht in einem Aufruf): je Tag `mark` (`work|school|vacation|sick|holiday|excused|off`), Soll, Plan, `workSeconds` (= `evaluatedWorkSeconds`), `creditSeconds`, `rawWorkSeconds`, `breakSeconds` (tatsächliche Lücken zwischen Abschnitten, keine erfundenen Pausen), `breakDeductionSeconds`, `travelSeconds`, `schoolSeconds`, `balanceSeconds` (= `deltaSeconds`), erster Beginn/letztes Ende (bewertet), Abwesenheiten, `provisional`, `isToday`, `isFuture`. Wochensumme einschließlich `averageStart/End` (lokal, gerundet), `longestDay`, Tageszählern (Urlaub: halbe Tage 0,5; Wochenendabwesenheit zählt nicht) und Zeitkonto vor/nach der Woche.
5. **Semantik der Salden**: Tage nach heute haben `balanceSeconds: null`; die Wochen-`balanceSeconds` summiert nur Tage bis heute, `targetToDateSeconds` liefert das passende Soll. Zeitkonto: wie `GET /time/account` mit `asOf` = Vortag der Woche bzw. Sonntag, durch „heute“ gedeckelt (laufende Woche: Stand heute, `accountBalanceAsOf`). Eine Woche ohne Arbeitsmodell liefert Nullwerte statt Fehler.
6. **Rechenaufwand**: konstante Anweisungszahl je Woche (18 bei Plan- und Zeitwoche zusammen, unabhängig von Verlaufslänge, im Test belegt). Die Wochenübersicht lädt den vollständigen Verlauf einmal für beide Kontostände.
7. **Freigaben**: Der Umfang `plan` enthält zusätzlich geplante Zeiten und `plannedSeconds` (nur wenn gesetzt, sonst bleibt der Eintrag `{date, mode}`); Notiz und Ort bleiben unsichtbar.
8. **Fehlercodes** (400, deutsch über die bestehende Abbildung): `plan_time_invalid`, `plan_break_invalid`, `invalid_week`, `week_day_invalid`.
9. **PWA**: Navigationspunkt „Woche“ (Alltag, nach Zeit) mit den Reitern „Übersicht“ (`/week`, Kern) und „Planen“ (`/plan`, Modul planning). Vorschlag für Zeiten aus dem Durchschnitt der letzten vier abgeschlossenen Wochen, sonst 08:00 plus Soll. Ältere Server ohne die Endpunkte: Hinweistext statt Absturz.

## Offen

- Native Apps übernehmen beide Funktionen in einem späteren Paket (Vertrag in `docs/handoffs/K1.md`).
- Kein Abgleich Plan ↔ Ist als Benachrichtigung; keine Teamfreigabe der Zeiten über die Planfreigabe hinaus.
