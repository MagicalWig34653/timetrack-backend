# Übergabe SEC-B: Proxy und Header (SEC-01, SEC-05, SEC-13)

Branch `sec-b`, keine Vertragsänderung (OpenAPI bleibt 0.41.0), keine Migration.

## Was geändert wurde

- **SEC-01 (Proxy-Vertrauen):** Pflichtcharakter von Port-Firewall und `TRUSTED_PROXY_CIDRS` ausdrücklich dokumentiert (`deploy/swarm/stack.yaml`, `docs/BETRIEB.md` Abschnitt 6 mit neuem Prüfschritt 4 „gefälschter `X-Forwarded-For` von fremdem Rechner“, `docs/DEPLOYMENT.md`, `docs/installation/{swarm,proxy,compose,konfiguration}.md`, `EINRICHTUNG.md`, Compose-README). Neue Startwarnungen (`TrustedProxies.startupWarnings`): leere Liste bei https-`PUBLIC_BASE_URL` (alle Clients teilen eine Adresssperre), Netze mit öffentlichen Adressen, sehr weite private Netze (IPv4 weiter als /16, IPv6 weiter als /48, mit Routing-Mesh-Hinweis). `/0` wurde schon vorher abgelehnt.
- **SEC-13 (Compose):** `BIND_ADDR` hat jetzt den Standard `127.0.0.1` (`deploy/compose/compose.yaml`, `.env.example`, Doku). Secret-Dateien bleiben bewusst 0644 im 0700-Verzeichnis.
- **SEC-05 (Sicherheitsheader):** `SecurityHeadersMiddleware` (äußerste Middleware, `Sources/TimetrackKit/SecurityHeaders.swift`) setzt, wenn die Route sie nicht selbst setzt: `X-Content-Type-Options`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, `Permissions-Policy`, eine CSP (API: `default-src 'none'; frame-ancestors 'none'`; sonstiges HTML wie OAuth-/Token-Seiten: `frame-ancestors 'none'; base-uri 'none'`) und HSTS (nur bei https-`PUBLIC_BASE_URL`; `HSTS_MAX_AGE_SECONDS`, Standard 15552000, 0 = aus, ohne `includeSubDomains`). Vorhandene Header (Dateivorschau-CSP-Sandbox, `no-store` der Token-URLs) werden nie überschrieben.
  - **PWA-CSP:** `PWAContentSecurityPolicy` berechnet beim Ausliefern von `*.html` aus dem gebauten HTML die SHA-256-Hashes aller Inline-Skripte (und Inline-Handler, dann `'unsafe-hashes'`); Cache je Pfad und Änderungszeit. Ein neuer PWA-Build braucht keine Konfiguration. `style-src` behält `'unsafe-inline'` (Svelte-`style=`-Attribute). Übrige statische Dateien erhalten `default-src 'self'` (wichtig: die CSP von `service-worker.js` gilt für den Worker selbst; `default-src 'none'` hatte beim ersten Browsertest die Precache-Fetches des Service Workers blockiert, behoben und per Test abgesichert).

## Browser-Prüfung der CSP (echt, nicht nur Unit-Tests)

Gebautes Backend (Linux-Container, SQLite) mit `PWA_STATIC_DIR` auf den Produktions-Build der PWA (`npm run build`, nicht der Mock-Build) und Playwright (Chromium, virtueller Passkey): Registrierung per Einladung, Seiten `/login`, `/setup/recovery`, `/`, `/week`, `/settings`, `/settings/profile`, `/places`, `/reports`, `/admin`, Manifest, Service-Worker-Registrierung (aktiv), Offline-Navigation über den Service Worker mit `offline.html` samt Inline-`onclick`, `blob:`-Bild, `blob:`-PDF im iframe und Download: **keine CSP-Verstöße** in Konsole und Worker. Kontrolle: ein absichtlich eingefügtes Inline-Skript wird gemeldet. Nicht geprüft: die echte Dateivorschau über die Oberfläche (Anhang hochladen); der `blob:`-iframe wurde nachgestellt.

## Tests

`Tests/TimetrackKitTests/SecurityHeadersTests.swift` (Erweiterung von `AuthTests`): `testSec05_*` (Hash-Richtlinie, PWA-Hülle und Assets, API und Fehlerantworten, HSTS und Erhalt vorhandener Header) und `testSec01_StartupWarningsForProxyNetworks`.

## Betreiber-Aktionen

- Swarm: `TRUSTED_PROXY_CIDRS` setzen **und** den veröffentlichten Port per Knoten-Firewall nur dem Proxy öffnen; danach Prüfschritt 4 (BETRIEB Abschnitt 6) ausführen. Beim Start auf Warnungen zu `TRUSTED_PROXY_CIDRS` achten. Rollout per `docker stack deploy` bzw. `update.sh`.
- Compose: Standard-Bind ist jetzt `127.0.0.1`. Läuft der Proxy auf einem anderen Server, `BIND_ADDR` in `.env` ausdrücklich setzen und per Firewall beschränken (bestehende `.env` mit `BIND_ADDR=0.0.0.0` bleibt unverändert wirksam).
- HSTS sendet nun das Backend selbst; setzt der Proxy den Header ebenfalls, ist das harmlos (`HSTS_MAX_AGE_SECONDS=0` schaltet die Backend-Variante ab).

## Auswirkungen auf Clients

Keine Vertragsänderung. PWA: externe Ressourcen (andere Hosts) und neue Inline-Skripte außerhalb von `index.html`/`offline.html` werden von der CSP blockiert; neue Inline-Skripte in der Hülle werden automatisch per Hash erlaubt. `Referrer-Policy: no-referrer` gilt jetzt global. Apple-Apps sind nicht betroffen (keine Webansicht-Abhängigkeit von diesen Headern bekannt).
