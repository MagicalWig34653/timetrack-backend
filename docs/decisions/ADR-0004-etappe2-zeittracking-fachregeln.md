# ADR-0004: Etappe 2 – Zeittracking, Fachregeln und Vertrag

Status: akzeptiert (Lead-Entscheidung 14.10.2026; fachliche Details aus KONZEPT.md Abschnitt 2–3, Ergänzungen sind Annahmen und markiert).

## Begriffe

- **Segment** (`WorkSegment`): ein Zeitabschnitt mit Art `work`, `travel` oder `school`, optional Ort. Rohzeiten (`rawStartedAt/rawEndedAt`)
  sind unveränderlich; `startedAt/endedAt` sind die effektiven (ggf. korrigierten) Zeiten. Jede Korrektur erzeugt eine Revision mit Grund; `version` steigt.
- **Pause**: ist die *tatsächliche Lücke* zwischen Segmenten; es werden keine Pausen erfunden. Zusätzlich kennt das Arbeitsmodell **feste Pausenvorlagen**
  (z. B. 12:00–12:30). Eine Vorlage zieht nur den Anteil ab, der in Arbeitssegmenten liegt (Schnittmenge, nie doppelt mit echten Lücken).
  Pro Tag überspringbar (`skipFixedBreaks`); dann bleibt die Zeit Arbeit.
- **Arbeitstag**: Zuordnung eines Segments zum lokalen Datum seines Beginns in der Modell-Zeitzone, verschoben um `dayBoundaryMinutes` (Standard 0; Annahme:
  Nachtschicht = Segment gehört zum Tag seines Beginns, wird nie an Mitternacht geteilt). Gerundet wird einmal pro Arbeitstag.
- **Bewertung** (`DayEvaluation`) eines Tages, alles in ganzen Sekunden:
  `rawWorkSeconds = Σ (Segmentdauer der zählenden Arten)`; zählende Arten: `work`, `school` (nur über Schulregel), `travel` nur wenn `travelCountsAsWork`.
  `breakDeductionSeconds = Σ Schnittmengen Pausenvorlage ∩ zählende Segmente` (0 bei skip).
  Rundung (wenn aktiv): erster zählender Segmentbeginn auf `roundingMinutes` **abrunden**, letztes zählendes Segmentende **aufrunden**; Differenzen
  `startAdjustSeconds`, `endAdjustSeconds` ≥ 0. Innere Grenzen und Lücken unverändert.
  `evaluatedWorkSeconds = rawWorkSeconds − breakDeductionSeconds + startAdjustSeconds + endAdjustSeconds`.
  Beispiel: 08:07–12:00 und 13:00–16:02 → raw 6:55, +7 min, +13 min → bewertet 7:15; Lücke 12:00–13:00 bleibt.
  Laufendes Segment: Ende = jetzt, `provisional=true`.
- **Schulregel**: Summe der `school`-Segmente eines Tages ≥ `schoolFullDayThresholdSeconds` (Standard 4×45 min = 10800) ⇒ der Tag gilt als erfüllt mit
  `schoolCreditSeconds` (Standard = Tages-Soll, 7:42 = 27720 s) *statt* der Segmentsumme. Darunter: nur die tatsächlichen Segmente zählen, nie automatische Auffüllung;
  der Nutzer ergänzt manuell. Keine Rückkehrpflicht.
- **Tages-Soll**: aus `dailyTargetSeconds[weekday]`, sonst `weeklyTargetSeconds` verteilt auf `workdays` (gleichmäßig; Annahme, 38:30 h/5 = 7:42). Änderungen gelten ab `validFrom`
  (neue Modellversion), Historie bleibt (Modelle sind versioniert und ohne Rückwirkung; Zeiträume überlappen nicht).
- **Tagesmarkierung** (`DayMark`): `holiday`, `vacation`, `sick`, `school_credit`, `none` mit optionalem `creditSeconds`; setzt das Soll des Tages auf 0 bzw. gutgeschriebene Zeit
  (Etappe 3 befüllt Feiertage/Urlaub automatisch; in Etappe 2 nur manuell). Keine doppelte Gutschrift: je Tag höchstens eine Markierung.
- **Zeitkonto**: `balance = openingBalanceSeconds + Σ_{Tage seit accountStart bis Stichtag} (evaluated + credit − target) + Σ adjustments`. Heute ist vorläufig. Zukünftige Tage zählen nicht.
- **Pausenhinweise** (Profil `arbzg-adult-de`, nur Hinweise, keine Rechtsprüfung): anhand *tatsächlicher* Zeiten (nicht gerundet): >6 h Arbeit ohne ≥30 min Gesamtpause,
  >9 h ohne ≥45 min, Teilpausen <15 min zählen nicht, >6 h am Stück ohne Pause. Nur Hinweise (`breakHints`).
- **Timer/Idempotenz**: höchstens ein laufendes Segment je Konto. Start/Stop tragen `clientEventId` (UUID); Wiederholung liefert dasselbe Ergebnis. Ereignis-Reihenfolge unklar ⇒ `needsReview`.
- **Automation** (Shortcuts): Gerätetokens (nur Automation-Scope, einzeln widerrufbar, nur Hash gespeichert) senden Ereignisse `arrival`, `presence_confirmed`, `departure`, `cancel` mit `eventId`.
  Pro Ort `automationMode` = `direct` (bucht bei bestätigtem Aufenthalt, zurückdatiert auf Ankunft), `suggest` (legt Vorschlag an), `off`. Vorbeifahrt (Ankunft ohne Bestätigung innerhalb `confirmAfterSeconds`,
  Standard 300) bucht nie. Ereignis ≠ Planung ≠ Ist-Zeit: Ereignisse bleiben als eigene Objekte erhalten. Fehlendes `departure` beweist nichts: offenes Segment wird nur als Vorschlag zum Ende markiert.
- **Rechte**: alle Objekte gehören einem Konto; fremde IDs → 404. Dieselben Dienste für REST, später MCP und Apps.
- **Zeit**: UTC-Instants im API (ISO-8601), lokale Tage als `YYYY-MM-DD`, Modell-Zeitzone IANA (Standard `Europe/Berlin`), Sommerzeit über Zeitzonenregeln, Dauern in Sekunden.

## Paketaufteilung

C5 (Codex): reine Fachlogik-Engine `TimeEngine` (kein DB/HTTP), vollständig getestet. C6 (Codex): Persistenz, Migrationen, REST, Automation-Dienst. L4 (Claude): PWA-Zeitleiste/Timer/Korrekturen/Konto gegen Mock.
L5 (Claude): Shortcuts-Anleitung, Vorschlags-UI, Gerätetoken-UI. Vertragsänderungen nur durch den Lead.
