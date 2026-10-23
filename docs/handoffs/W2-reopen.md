# Handoff W2 (Backend): beendeten Abschnitt wieder öffnen („Timer fortsetzen“)

Stand: 23.10.2026. Vertrag **v0.27.0** (additiv, keine Migration). Kein neuer Endpunkt: bestehendes `PATCH /api/v1/time/segments/{id}`.

## Was Clients senden

`PATCH /api/v1/time/segments/{id}` (Sitzung + CSRF), Header `If-Match: <aktuelle version>`, Body:

```json
{ "endedAt": null, "reason": "Timer fortgesetzt" }
```

- `endedAt` muss **ausdrücklich `null`** sein (Schlüssel vorhanden). Fehlt der Schlüssel, bleibt das Ende unverändert. Weitere Felder (`startedAt`, `kind`, `placeId`, `note`) sind optional und ändern sich nur, wenn gesendet.
- `reason` ist wie bei jeder Korrektur Pflicht (1–200 Zeichen), z. B. fester Text „Timer fortgesetzt“.
- Antwort 200 mit dem `Segment`: `endedAt: null`, `version` +1, `revisions` +1; `source`, `kind`, `placeId`, `note`, `rawStartedAt`, `rawEndedAt` unverändert (Rohende bleibt als ursprüngliche Aufnahme). `GET /time/timer` liefert danach dieses Segment; Stoppen wie gewohnt über `POST /time/timer/stop`.
- MCP: `correct_segment` mit `endedAt: null` (gleiche Regeln und Fehler).

## Fehler

| Status | Code | Bedeutung |
| --- | --- | --- |
| 409 | `timer_already_running` | Ein anderer Abschnitt des Kontos läuft schon (zuerst stoppen). |
| 409 | `segment_overlap` | Ein anderer nicht stornierter Abschnitt beginnt am oder nach dem bisherigen Ende; nur der zeitlich letzte Abschnitt ist fortsetzbar. |
| 412 | `stale_version` | If-Match veraltet; neu laden. |
| 404 | `not_found` | Fremdes Konto oder unbekannte Id. |
| 409 | `conflict` | Abschnitt ist storniert. |

Prüfreihenfolge: Version, storniert, laufender Abschnitt, späterer Abschnitt. Client-Hinweis: „Fortsetzen“ nur anbieten, wenn kein Timer läuft und der Abschnitt der letzte des Kontos ist; bei 409 Liste neu laden.

## Revision/Audit

Die Revision (`segment_revisions`, Export des Kontos) speichert Vorher-/Nachher-Snapshot (`endedAt` Wert → null) und den Grund mit Präfix `Reopened: ` (z. B. `Reopened: Timer fortgesetzt`). Rundung/Bewertung unverändert: ein offenes Segment wird wie ein laufender Timer bewertet.

## Hinweis zur Lücke zwischen altem und neuem Ende

Fortgesetzt wird der gleiche Abschnitt; die Zeit zwischen altem Ende und Fortsetzung zählt als Arbeitszeit des Abschnitts (keine automatische Pause). Wer eine Pause erfassen will, startet stattdessen einen neuen Abschnitt.

## Tests

`TimeHTTPTests.testReopenFinishedSegmentWithGuards`: Erfolg (Rohende, Quelle/Art/Notiz, Revision `Reopened: …`), späterer Abschnitt, laufender Timer, fremdes Konto, fehlendes `endedAt` ändert nichts.
