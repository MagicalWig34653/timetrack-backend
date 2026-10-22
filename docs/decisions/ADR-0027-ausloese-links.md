# ADR-0027: Abgang beendet fremd gestartete Timer; Auslöse-Links

Status: Umsetzungsentscheidung von Paket W1 (Backend); Lead-Prüfung offen. Teil B beruht auf einer ausdrücklichen Nutzeranforderung (Standorterfassung ohne iOS-App aus beliebigen HTTP-fähigen Automationswerkzeugen).

## Kontext

(A) Ein `departure`-Ereignis beendete bisher nur Timer, die ein `arrival` gestartet hatte; bei manuell gestartetem Timer kam „ignored/needs_review“. (B) Nicht jedes Automationswerkzeug kann einen POST mit Bearer-Token und JSON senden; ein einfacher GET genügt vielen Werkzeugen.

## Entscheidungen

### A: Abgang beendet jeden laufenden Timer

1. `departure` ohne offenen Besuch (keine Ankunft) beendet einen laufenden Abschnitt, egal wie er gestartet wurde (manuell, Timer-Endpunkt, Import ausgenommen, da nie laufend). Ortsmodus `direct`: Ende = Ereigniszeit (rückdatiert, Ergebnis `booked`); `suggest`: Ende-Vorschlag (`suggested`, ein offener Vorschlag je Abschnitt); `off`/archiviert: nur `recorded`.
2. Ein laufender Abschnitt mit **anderem** Ort bleibt unberührt (`ignored`); ohne Ort wird er beendet. Ereigniszeit vor oder gleich dem Beginn: `needs_review`.
3. Vorbeifahrt (Ankunft ohne Bestätigung, dann Abgang) bucht und beendet nichts; Abgang ohne laufenden Timer und ohne Ankunft ist ein harmloses `ignored` (bisher `needs_review`). Die Reihenfolgeprüfung (`needs_review` bei älterem Ereignis) bleibt davor.
4. REST und MCP teilen die Regeln über `AutomationService`; MCP hat keinen Automationsereignis-Tool, der Weg ist nur `POST /automation/events`. Ein globaler Schalter ist das Modul `automation`.

### B: Auslöse-Links (`GET /t/{token}/{start|stop|toggle}`)

1. **Token**: 32 Zufallsbytes (256 Bit, Base64url, 43 Zeichen), nur der SHA-256-Hash liegt in `trigger_links` (eindeutig), Klartext nur in der Antwort des Anlegens. Vergleich zusätzlich mit konstantem Zeitaufwand (`Secrets.equal`).
2. **Je Link**: Bezeichnung (≤ 80), erlaubte Aktionen (nicht leer), optionaler Ort (Bindung), Abschnittsart, optionales Ablaufdatum (1–730 Tage), widerrufbar, `lastUsedAt`/`lastAction`. Höchstens 20 aktive Links je Konto. Verwaltung per Sitzung + CSRF unter `/me/trigger-links` (Modul `automation`), **bewusst ohne MCP**: Zugangsdaten werden auch bei Geräte-Tokens nicht über MCP vergeben, und eine KI soll keine unauthentifizierten Zugänge erzeugen.
3. **Kein Orakel**: unbekannt, falsche Länge, widerrufen, abgelaufen, Konto deaktiviert, Modul aus und nicht erlaubte Aktion antworten gleich mit 404. Fehlversuche zählen je Client (30 je 5 Minuten, danach 429 schon vor der Suche); gültige Links 60 Anfragen je 5 Minuten (429 mit `Retry-After`).
4. **Idempotenz** (GET kann wiederholt oder vorab geladen werden): Start bei laufendem Timer `already_running`, Stopp ohne Timer `already_stopped`; ein zweites `toggle` desselben Links innerhalb von 10 s ändert nichts. HEAD und Anfragen mit `Purpose`/`Sec-Purpose: prefetch|prerender` lösen nichts aus (204).
5. **Fachlogik wiederverwendet**: Stopp = `AutomationService.stopRunning` (wie A), Start legt den Abschnitt mit Quelle `automation` an (damit die Prüfung „fehlendes Ende am Folgetag“ greift). Ortsmodus des Ortes (Bindung oder `?place=`) wird beachtet: `off` → `ignored`, `suggest` → Vorschlag, `direct` → Buchung; ohne Ort immer direkt. Überlappung mit vorhandenem Abschnitt: 409 `segment_overlap`.
6. **Rückdatierung** `?at=`: höchstens 2 Stunden zurück, höchstens 60 s in der Zukunft (auf jetzt begrenzt); sonst 400.
7. **Antworten**: knappes JSON (`result`, `action`, `segmentId`, `suggestionId`, `at`) oder mit `?format=text` nur das Ergebniswort; immer `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex`.
8. **Protokolle**: die Anwendung protokolliert keine Anfragepfade; der Konsolen-Log-Handler schwärzt zusätzlich jedes `/t/<token>` (Zweitsicherung). Zugriffsprotokolle des vorgelagerten Reverse Proxys liegen außerhalb des Projekts und müssen den Pfad `/t/` schwärzen oder weglassen (Hinweis in `docs/installation/proxy.md`).
9. **Daten**: Tabelle `trigger_links` (Migration `w1.create_trigger_links`), Kontoexport `trigger-links.json` ohne Token, Kontosperre/-löschung widerruft bzw. entfernt die Links.

## Abwägung

Ein Token in der URL ist schwächer als ein Header-Token: es landet in Verlauf, Lesezeichen, Synchronisation, Zugriffsprotokollen von Proxys und Zielgeräten und in Screenshots; jeder Besitzer der URL kann Zeiten beginnen und beenden (nicht lesen, nicht ändern, nicht löschen). Gegenmaßnahmen: ein Link je Zweck mit eng gewählten Aktionen, optionaler Ort und Ablauf, sofortiger Widerruf, Ratenbegrenzung, Anzeige „zuletzt benutzt“. Wer einen Header setzen kann, sollte weiterhin das Gerätetoken mit `POST /automation/events` verwenden.

## Alternativen

Token als Query-Parameter (landet häufiger in Protokollen als ein Pfad; verworfen), Link mit Signatur und Ablauf je Aufruf (nicht ohne Client-Logik möglich), Anzeige der letzten Zeichen des Tokens (verworfen, kein Nutzen gegen Verwechslung, nur Leckfläche; die Bezeichnung genügt).

## Folgen

Vertrag 0.26.0. PWA braucht eine Verwaltungsansicht (`docs/handoffs/W1.md`). Betreiber-Hinweis zu Proxy-Protokollen in `docs/installation/proxy.md`. Betroffen: `docs/ARCHITEKTUR.md` (Abschnitt 5), `docs/KONZEPT.md`.
