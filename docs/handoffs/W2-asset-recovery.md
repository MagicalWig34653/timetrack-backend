# W2 (Assets): Weiße Seite durch HTML statt JavaScript

Stand: 18.10.2026. Hinweis: `W2.md` gehört bereits dem älteren Paket „Installationsanleitung“; diese Übergabe heißt deshalb `W2-asset-recovery.md`. Branch `w2-asset-recovery` in Backend und PWA, nicht gepusht und nicht gemergt.

## Ursache

Produktion (Swarm, zwei Backend-Replikas, PWA im Image): Das Dokument (`index.html`, aus Image, Replika oder Service-Worker-Cache) verweist auf gehashte Dateien unter `/_app/immutable/`, die die antwortende Replika nicht hat (Rolling Update mit gemischten Versionen, veraltete Caches). `PWAStaticMiddleware` beantwortete jede fehlende Datei mit der SPA-Hülle (`200 text/html`); der Browser meldet „'text/html' is not a valid JavaScript MIME type for module script“ und zeigt eine weiße Seite.

## Backend

- `Sources/TimetrackKit/PWAStaticMiddleware.swift`: Fehlende Dateien unter `/_app/` und Pfade mit Dateiendung eines statischen Assets (js, css, map, json, webmanifest, Bilder, Schriften u. a.) antworten mit echtem 404 (`text/plain`, `Cache-Control: no-store`, `nosniff`). Nur Pfade ohne Asset-Endung fallen auf `index.html` zurück (Deep Links wie `/invite/example.org` bleiben). Unbekannte `/.well-known/…`-Pfade bleiben 404 und bekommen `no-store`. `service-worker.js`, Manifest, Favicons und `version.json` werden unverändert ausgeliefert, wenn sie existieren.
- Test: `AuthTests.testStaticServingAndTraversal` erweitert. Keine Vertragsänderung (Version bleibt 0.21.0).

## PWA

- `src/app.html`: kleines Inline-Skript `#tt-recovery`. Erkennt `unhandledrejection`, `error` (auch Ladefehler von `<script>`/`<link>` unter `/_app/`) und `vite:preloadError`. Pro 5 Minuten genau eine Selbstheilung (Zeitstempel `tt.recovery` in localStorage, Rückfall sessionStorage): Service Worker abmelden, Caches löschen, neu laden. Beim zweiten Fehler im Zeitfenster (oder ohne nutzbaren Speicher) erscheint eine statische deutsche Meldung mit Knopf „Neu laden“.
- `src/service-worker.ts`: Precache ohne `cache.addAll`; jede Antwort wird geprüft (`isUsableAssetResponse` in `src/lib/pwa/core.ts`), HTML für eine Asset-URL lässt die Installation scheitern (alter Worker bleibt zuständig). `cacheFirst` cached und liefert nie HTML für Asset-URLs (stattdessen 404) und verwirft solche Treffer. Alte Caches werden weiter beim Aktivieren gelöscht.
- `kit.version.pollInterval`: nicht geändert; SvelteKit 3 pollt standardmäßig stündlich, prüft zusätzlich bei Fokus und bei Server-Antworten.
- `scripts/serve-build.mjs` bildet das neue 404-Verhalten nach.
- Tests: `src/lib/pwa/recovery.test.ts` (führt das ausgelieferte Skript aus `app.html` in jsdom aus), `asset-guard.test.ts`, `sw.test.ts` angepasst; `e2e-pwa/asset-recovery.spec.ts` (Erholung nach einmaliger HTML-Antwort, Fallback-Meldung bei dauerhaftem Fehler, 404 statt HTML).

## Betrieb

Siehe `docs/installation/probleme.md` („Weiße Seite / MIME-Type“) und `docs/UPDATE.md`.
