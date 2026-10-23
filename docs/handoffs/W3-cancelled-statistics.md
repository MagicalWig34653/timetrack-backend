# Handoff W3 (Backend): stornierte Abschnitte und Statistikreihe

Stand: 23.10.2026. Vertrag **v0.28.0** (additiv, keine Migration). Alle Endpunkte: Basis `/api/v1`, Sitzung; schreibende zusätzlich CSRF.

## Befund

Stornieren ist ein Soft-Delete (`voidedAt`, `voidReason`, Revision). Bisher gab es nur `GET /time/segments?includeVoided=true` (an Zeitraum gebunden, keine Seiten, kein Storno-Grund), keine Wiederherstellung und kein endgültiges Löschen. Für das Zeitkonto gab es `GET /time/account` (nur der Stand), `GET /time/days` (max. 93 Tage) und `GET /time/weeks/{isoWeek}`; keine Reihe über längere Zeiträume.

## (a) Stornierte Abschnitte

| Aufruf | Zweck |
| --- | --- |
| `GET /time/segments/cancelled?from&to&limit&offset` | Liste, neuester Beginn zuerst. `limit` 1..200 (Standard 50), `offset` >= 0, `from`/`to` (ISO-Instant, Beginn in [from, to)). Antwort `{ items: [{ segment, cancelledAt, cancelReason }], total, limit, offset }` |
| `POST /time/segments/{id}/restore` | Stornierung aufheben. Body optional `{ "reason": "…" }` (<= 190 Zeichen, Standard „Restored“), optional `If-Match: <version>`. 200 mit `Segment` (`voided` false, `version` +1, Revision „Restored: …“) |
| `DELETE /time/segments/{id}?permanent=true` | Ein **stornierter** Abschnitt endgültig. 200 mit `PurgeSummary`. Ohne `permanent` unverändert Stornieren (204, `reason` Pflicht) |
| `DELETE /time/segments/cancelled?from&to&ids&all&dryRun` | Sammellöschung. Auswahl per `from`/`to`, `ids` (kommagetrennt, max. 500) und/oder `all=true`; ohne Auswahl 400 `purge_scope_required`. `dryRun=true` zählt nur (Vorschau). 200 mit `PurgeSummary` |

`PurgeSummary`: `{ dryRun, segments, revisions, suggestions, timerEvents, automationEvents }`.

Fehler: 404 unbekannt oder fremdes Konto; 409 `segment_not_cancelled` (Abschnitt ist nicht storniert; bei `ids` mit einem nicht stornierten Abschnitt scheitert die ganze Anfrage, nichts wird gelöscht); Wiederherstellen zusätzlich 409 `segment_overlap` (Überschneidung mit nicht stornierten Abschnitten), 409 `timer_already_running` (stornierter laufender Timer, anderer läuft), 412 `stale_version`; 400 bei ungültigen Parametern.

Empfohlener Ablauf in Clients: Liste laden, vor dem Löschen `dryRun=true` aufrufen und die Anzahlen anzeigen („N Abschnitte und N Korrekturen werden unwiderruflich gelöscht“), nach Bestätigung ohne `dryRun`. Wiederherstellen-Knopf mit Fehlerbehandlung `segment_overlap` (deutsche Meldung kommt vom Server).

### Entscheidungen
- **Kein Grabstein.** Endgültiges Löschen entfernt den Abschnitt und sein gesamtes Korrekturprotokoll (`segment_revisions`), Ende-Vorschläge, die darauf zeigen, und gespeicherte Timer-Ergebnisse (`timer_events`). Automations-Ereignisse behalten Zeile und Idempotenzschlüssel, verlieren nur `segmentId`. Einzige Spur ist die `PurgeSummary`. Begründung: Datensparsamkeit und Löschrecht; ein Grabstein würde Zeiten weiter dokumentieren.
- Segmente haben keine Anhänge (Anhänge gehören zu Abwesenheiten); es ist nichts zu entfernen.
- Export und Kontolöschung: bereits gelöschte Abschnitte erscheinen nicht mehr; keine Änderung nötig.
- Stornierte Abschnitte zählen nie zur Bewertung; Wiederherstellen ändert die Bewertung erst nach erfolgreicher Prüfung.
- **MCP:** `list_cancelled_segments` (time:read, max. 100 je Seite) und `restore_segment` (time:write, verlangt `expectedVersion`). Endgültiges Löschen ist **nicht** über MCP/KI verfügbar (Test über die feste Werkzeugliste).

## (b) Statistik

`GET /time/statistics?from=YYYY-MM-DD&to=YYYY-MM-DD&granularity=day|week|month&basis=evaluated|raw` (Standard `week`, `evaluated`; höchstens 1100 Tage, sonst 400 `range_too_large`). Nur lesend, Modul-unabhängig, immer nur das eigene Konto.

Antwort: `{ from, to, granularity, basis, timezone, accountStart, openingBalanceSeconds, buckets[], totals }`.

Je Bucket (`label` = `2026-10-12`, `2026-W42` oder `2026-10`; Randbuckets nur mit Tagen innerhalb von from..to, `from`/`to` zeigen den tatsächlichen Umfang):
- `targetSeconds` (Soll), `targetToDateSeconds` (Soll bis heute), `actualSeconds` (Ist nach `basis`, ohne Gutschrift), `creditSeconds`, `deltaSeconds` (Differenz = Ist + Gutschrift - Soll, nur Tage bis heute), `overtimeSeconds`, `undertimeSeconds` (Summen der positiven bzw. negativen Tagesdifferenzen).
- `balanceSeconds` + `balanceAsOf`: kumulierter Zeitkontostand am Ende des Buckets (höchstens heute), identisch zu `GET /time/account?asOf=…`; `null` vor Kontobeginn. `openingBalanceSeconds` ist die Basislinie am Vortag von `from`.
- `kindSeconds` `{ work, school, travel }` (Segmentdauer je Art), `absences` `{ vacation, sick, excused, holiday, school }` (Tage, Urlaub halbtagsgenau), `absenceDays` (Urlaub + krank + entschuldigt), `breakSeconds` (tatsächliche Lücken, keine erfundenen Pausen), `breakDeductionSeconds` (feste Pausen), `workDays`, `evaluatedWorkSeconds`, `rawWorkSeconds`, `roundingSeconds`, `provisional`.
- `basis=raw` lässt nur die Rundung von erstem Beginn/letztem Ende weg (`actualSeconds` = bewertet minus `roundingSeconds`); der Kontostand bleibt der offizielle bewertete. Regeln und Rechtsprofile unverändert.

Konsistenz (getestet): eine Woche stimmt mit `GET /time/weeks/{isoWeek}` überein (Soll, Ist, Saldo, Kontostand), der letzte Kontostand mit `GET /time/account`.

Laufzeit: eine Auswertung des gesamten Verlaufs wie bei der Wochenansicht (einmalige Ladung, kein N+1).

## PWA / Apple: was aufzurufen ist
- Papierkorb/Storno-Ansicht: `GET /time/segments/cancelled` (Blättern per `offset`), Aktionen `POST …/restore`, `DELETE …?permanent=true`, Sammellöschung mit Vorschau (`dryRun=true`).
- Diagramme: `GET /time/statistics` mit passender Körnung (Tag: <= 93 Tage; Woche: Quartal/Jahr; Monat: Jahre); Zeitkonto-Linie aus `balanceSeconds`, Balken aus `actualSeconds` vs. `targetSeconds`, Arten aus `kindSeconds`.
- Neue Fehlercodes: `segment_not_cancelled`, `purge_scope_required`.

## Dateien
`TimeCancelled.swift`, `TimeStatistics.swift`, `TimeRoutes.swift`, `MCP/MCPTools.swift`, `TimeEvaluationServices.swift` (`accountStart` geteilt), `TimeWeek.swift` (`dto` intern), `contracts/openapi.yaml`, Tests `CancelledSegmentTests.swift`, `MCPTests.swift`.
