# ADR-0004 – Ergänzung: eindeutige Zuordnung bei Modellwechseln

Status: akzeptiert für C7 gemäß Reparaturauftrag vom 14.10.2026. ADR-0004 bleibt unverändert.

## Problem

Die bisherige unabhängige Verschiebung und Gültigkeitsprüfung pro Modell konnte Segmente
bei einer späteren Tagesgrenze aus beiden Modellen ausschließen. Zeitzonenwechsel können
zusätzlich überlappende oder fehlende lokale Kalenderdaten am selben Instant erzeugen.

## Entscheidung

Modellbesitz wird vor der Arbeitstagsberechnung anhand des effektiven Segmentbeginns bestimmt:

1. Versionen werden nach `validFrom` geordnet; die vorhandene Überlappungsprüfung gilt weiter.
2. Der Beginn einer Version ist Mitternacht an `validFrom` in ihrer eigenen Zeitzone.
   Bei direkt anschließenden Versionen endet der Vorgänger genau an diesem Instant,
   unabhängig von seiner Zeitzone. Intervalle sind am Beginn inklusive, am Ende exklusiv.
   Erfüllen mehrere Versionen die Instant-Bedingung, gewinnt die neueste Version nach `validFrom`.
3. Innerhalb des besitzenden Modells gilt weiterhin die lokale Tagesgrenze. Der daraus
   berechnete Tag wird auf das inklusive Intervall `validFrom ... validTo` begrenzt
   (ohne `validTo` nur untere Grenze). Damit liegt jeder zugeordnete Tag im besitzenden Modell.
4. Die gesamte Segmentdauer bleibt auf diesem einen Tag; effektive und rohe Instants bleiben
   unverändert. Die Bewertung darf anschließend keine zweite, unabhängige Tagesfilterung vornehmen.
5. Absichtlich modellfreie Zeiträume bleiben modellfrei: tatsächliche Zeit ohne Soll, Rundung
   oder automatische Schulauffüllung gemäß C6. Sie werden nicht als Modellwechsel interpretiert.

Beispiel: Berlin, A bis 12.10. mit Grenze 00:00, B ab 13.10. mit Grenze 04:00.
13.10. um 02:00 gehört B; der zunächst berechnete 12.10. wird auf 13.10. begrenzt.
Beim Wechsel von Tokio nach New York verbleiben Instants vor New Yorks neuer lokaler
Mitternacht beim Vorgänger; dessen gegebenenfalls zu spätes lokales Datum wird auf `validTo` begrenzt.
In Gegenrichtung endet der Vorgänger früher. Es entsteht keine doppelte Zuordnung.

## Alternativen und Folgen

Eine unabhängige Prüfung beider lokalen Kalenderdaten mit Vorrang der neueren Version löst
Überlappungen, aber keine zeitlichen Lücken. Deshalb wird eine gemeinsame Wechselgrenze verwendet.
Eine Aufteilung von Segmenten widerspräche ADR-0004 und bleibt ausgeschlossen.

Die Zuordnung wird von REST-Tagesbewertung, REST-Konto und der modellübergreifenden
Engine-Kontoberechnung gemeinsam verwendet. Die einzelne öffentliche Engine-Tagesbewertung
behält ihre bisherige lokale Filterung; der Adapter übergibt intern bereits zugewiesene Segmente.
Rundung, Pausen und Gutschriften bleiben Modellregeln; Erhaltung der Roharbeitszeit bedeutet
keine Gleichheit mit der bewerteten Zeit bei aktivierten Abzügen/Gutschriften.
Keine Migration oder Vertragsänderung; historische Bewertungen betroffener Wechsel werden korrigiert.
Bereits fälschlich geschlossene Automationssegmente werden nicht automatisch rückwirkend geändert.

Nachweise und Integrationsstand: `docs/handoffs/C7.md`.
