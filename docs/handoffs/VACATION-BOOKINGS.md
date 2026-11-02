# Handoff VB1: Buchungen an Urlaubstagen

Branch `vacation-bookings`, ADR-0034 (Vorschlag, keine bestätigte Nutzerentscheidung). Nutzerwunsch 02.11.2026: Buchungen während Urlaub zulassen, wie Überstunde behandeln.

## Befund im Backend (Schritt 1)

Keine Sperre. Geprüft: `POST/PATCH/DELETE /time/segments`, `POST /time/timer/start|stop` (Test an einem Urlaubstag), Auslöse-Links und Automatik (nutzen dieselben Segment-/Timer-Dienste, keine Tagesprüfung), MCP, Import. Es gibt keinen Fehlercode für „Tag gesperrt“. Die Auswertung (`TimeEngine.evaluate`) zählt Buchungen an Tagen mit Markierung `vacation` voll als `evaluatedWorkSeconds` (Soll 0, halber Urlaubstag: halbes Soll), Rundung und feste Pausen wie sonst. Das gilt auch für Krank, Freistellung und Feiertag: dort ebenfalls keine Sperre (nicht geändert).

Beantragter/geplanter Urlaub (`requested`, `planned`) markiert den Tag gar nicht (nur gebucht = `approved`/`taken`); der Tag ist normaler Arbeitstag mit vollem Soll.

## Was geändert wurde

Nur Tests und Doku: `Tests/TimetrackKitTests/VacationBookingTests.swift` (Saldo vor/nach, ganzer und halber Tag, Urlaubskonto `bookedHalfDays` unverändert, Woche, Statistik, Löschen der Buchung, Krank/Freistellung/beantragt/ausdrückliche Markierung, Timer), ein Export-Test, ADR-0034, KONZEPT, UMSETZUNG, STATUS. Keine Vertragsänderung, keine Version, keine Migration.

## Anpassungsbedarf in den Clients (Schritt 4, nichts davon ist hier geändert)

PWA und Apple-Apps: Die Sperre, die der Nutzer erlebt hat, liegt dort (Backend lehnt nichts ab). Im PWA-/Apple-Code suchen nach Prüfungen auf `mark == "vacation"` / Urlaubstag in: Timer-Start (Heute, Widget, Live Activity, Watch, Shortcuts/App Intents), „Abschnitt hinzufügen“ in Tages- und Wochenansicht, Kontextmenü/Planer-Gesten, Drag zum Anlegen von Zeiten, Auslöse-Links-Anzeige. Zu tun:

1. Sperren, deaktivierte Schaltflächen und Fehler-/Hinweistexte („An Urlaubstagen kann nicht gebucht werden“ o. ä.) entfernen.
2. Optionaler Hinweis statt Sperre, nutzerseitig Deutsch: „Buchung an Urlaubstag: Die gebuchte Zeit zählt als Überstunde.“ Ableitbar aus `mark = vacation` und `workSeconds > 0` (oder `segmentsCount > 0`) in Tag/Woche.
3. Anzeige: Tageszeile mit Urlaubsmarkierung und Buchung zeigt Urlaub und Ist-Zeit; Differenz `balanceSeconds` ist positiv (Ganztag) bzw. Ist minus halbes Soll (Halbtag). Prüfen, dass die Anzeige das Ist nicht bei Urlaub ausblendet (Wochen-, Monats-, Statistikansicht, Widget „heute“).
4. Plan/Ist: ab Vertrag 0.42.0 (ADR-0035) ist `planActualDifferenceSeconds` auch an blockierten Tagen gesetzt, wenn ein Plan besteht.

## Offene Entscheidungen

1. Bleibt der Urlaubstag bei einer Buchung Urlaub (Vorschlag, Verbrauch bleibt) oder soll der Client „Urlaub zurückgeben?“ anbieten?
2. Ausdrückliche Gutschrift (`PUT /time/days/{date}` mit `creditSeconds`) an Urlaubs-/Krank-/Freistellungs-/Feiertag ersetzt die Arbeitszeit; Buchungen zählen dort nicht und werden nicht gerundet. Ungeändert; soll sie bei Urlaub additiv wirken?
3. Soll dieselbe Regel für Krank und Freistellung ausdrücklich gelten (Backend verhält sich schon so)?
