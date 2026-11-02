# Übergabe CSP-HOTFIX: PWA startet nach SEC-B nicht (Safari)

Branch `csp-hotfix`, keine Vertragsänderung (OpenAPI unverändert, Header-Verhalten steht nicht im Vertrag), keine Migration.

## Symptom (Betreiber)

Nach dem Container-Update mit SEC-B zeigt die PWA in Safari nur noch den Wiederherstellungshinweis der Hülle (`tt-recovery`). Konsole: (1) „Refused to execute a script because its hash … (line 0)“, (2) „Refused to load blob:https://<host>/<uuid> … script-src“, (3) „Unhandled Promise Rejection: TypeError: Importing a module script failed“ (SvelteKit-Start-`import()`), (4) Preload-Warnungen der `/_app/immutable`-Chunks. Aktive Erweiterung: AdGuard Extra.

## Untersuchung (belegt)

- **Hashes (Hypothese a):** `index.html` des Produktionsbuilds (PWA main 6bc548f) hat drei Inline-Skripte (`tt-recovery`, Theme, SvelteKit-Start). Die vom Backend gesendeten Hashes stimmen mit unabhängig (Python, Byte-Suche) berechneten SHA-256-Werten über die ausgelieferten Bytes überein; keine CRLF, keine Kodierungsänderung, Cache je Pfad/Änderungszeit korrekt, 304 und Range tragen dieselben Header. Das Backend komprimiert nicht. Dasselbe gilt für die PWA aus dem veröffentlichten Image (`ghcr.io/…/timetrack-backend:main`, `/srv/pwa`, per `docker cp` entnommen; Build-Schritte ändern `index.html` nicht).
- **`'self'` und dynamische Importe (b):** Playwright WebKit 27.2 und Chromium laden die Seite mit `script-src 'self' <3 Hashes>` fehlerfrei, auch über HTTPS (Proxy mit Selbstzertifikat, gzip) und mit aktivem, kontrollierendem Service Worker, Neuladen eingeschlossen: keine CSP-Verstöße, App startet.
- **`blob:` (c):** Die PWA erzeugt Blob-URLs nur für Downloads, Bild-/PDF-Vorschau (`img-src`/`frame-src`/`object-src` enthalten `blob:`); es gibt keinen `new Worker(blob)` und kein Blob-Skript (Grep in `src/`). Die Meldungen (1) und (2) (je 2x, „line 0“, Inline-Skript plus Blob-Skript) passen zu einer Erweiterung, die Skripte injiziert, nicht zur PWA. `blob:` in `script-src` wurde deshalb nicht ergänzt.
- **Service Worker (d):** `service-worker.js` erhält `default-src 'self'`; Precache und Offline-Fallback laufen im Browsertest.
- **Proxy-CSP (e):** Die Beispielkonfigurationen setzen keine CSP. Setzt der Betreiber-Proxy oder ein davorliegender Dienst eine eigene CSP oder fügt Inline-Skripte ein, gilt die Schnittmenge; das kann der Betreiber prüfen (BETRIEB Abschnitt 6, „Notbremse“).
- **Ursache:** nicht reproduziert. Nicht prüfbar waren echtes Safari (Automatisierung ohne Freigabe nicht möglich), die Erweiterung und der Betreiber-Proxy. Verdacht in dieser Reihenfolge: Proxy-/CDN-Header oder -Injektion, Erweiterung, Safari-spezifisches Verhalten. Die Notbremse trennt diese Fälle.

## Änderungen

- `PWA_CSP_MODE` (`enforce` Standard, `report-only`, `off`; ungültiger Wert = Startfehler, Startwarnung außerhalb `enforce`). `report-only` sendet dieselbe Richtlinie als `Content-Security-Policy-Report-Only`; in beiden Lockerungsmodi bleiben `frame-ancestors 'none'` (Hülle zusätzlich `base-uri 'none'`) erzwungen, Assets und Service Worker bekommen nur `frame-ancestors 'none'`. API-Richtlinie unverändert. Durchgereicht in `deploy/swarm/stack.yaml` und `deploy/compose/compose.yaml`.
- Tests (`SecurityHeadersTests.swift`, `testCspHotfix_*`): Hashes gegen die ausgelieferten Bytes der echten Produktions-`index.html` (Fixture `Tests/TimetrackKitTests/Fixtures/pwa-production-index.html`, mehrere Pfade, `Accept-Encoding: gzip, br`, drei Inline-Skripte, unabhängige Hash-Berechnung), CRLF und mehrere Skripte, Moduswahl, Notbremse je Modus. Bei einem neuen PWA-Build Fixture aus `build/index.html` aktualisieren (Test bleibt auch ohne Aktualisierung gültig, prüft aber dann den alten Build).
- Doku: `docs/BETRIEB.md` (Notbremse, Proxy-Schnittmenge), `EINRICHTUNG.md`, `docs/installation/konfiguration.md`, Security-Review (Nachtrag SEC-05), `docs/STATUS.md`.

## Sofortmaßnahme für den Betreiber (ohne neues Image)

`docker service update --env-add PWA_CSP_MODE=report-only timetrack_backend`, danach in Safari hart neu laden (notfalls Website-Daten der Domain löschen). Hilft das nicht, zuerst `curl -sI` über den Proxy mit der Backend-Antwort vergleichen (CSP-Zeilen identisch?), Erweiterungen testweise abschalten, dann `off`. Zurück: `--env-add PWA_CSP_MODE=enforce`. Ein `docker stack deploy` ohne gesetzte Variable stellt `enforce` wieder her.

## Offen

Echtes Safari mit Web Inspector: Konsole nach `report-only` auswerten (zeigt, ob und welche Richtlinie verletzt wird). Nicht automatisiert geprüft: eingeloggte Seiten in WebKit (virtueller Passkey nur in Chromium), echte Dateivorschau.
