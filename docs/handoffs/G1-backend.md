# G1-backend – Gruppenmodul (öffentliche Umfragen, Bestellrunden, Kataloge)

Stand: 30.10.2026, Branch `g1-polls` (Basis main 5006d0d), nicht gemergt. Vertrag 0.37.0, ADR-0033 (alle Entscheidungen dort).

## Endpunkte

Besitzer (Sitzung, schreibend mit CSRF, Modul `groups`, nicht über Bearer/MCP), Basis `/api/v1/groups`:

| Methode, Pfad | Zweck |
| --- | --- |
| `GET/POST /polls`, `GET/PATCH/DELETE /polls/{id}` | Umfragen auflisten, anlegen (201, `token`/`path` nur hier), ansehen (mit allen Stimmen), ändern (title, description, deadline, hideResults), löschen |
| `POST /polls/{id}/close`, `/reopen`, `/final` (`{optionId}` oder null), `/rotate-token` | Beenden, Öffnen, Endergebnis wählen (beendet), Link erneuern (neues `token`/`path` nur in der Antwort) |
| `DELETE /polls/{id}/votes/{voteId}` | Stimme entfernen |
| `GET/POST /orders`, `GET/PATCH/DELETE /orders/{id}` | Bestellrunden |
| `POST /orders/{id}/close`, `/reopen`, `/rotate-token`; `DELETE /orders/{id}/entries/{entryId}`; `GET /orders/{id}/export?format=csv\|txt`; `GET /orders/suggestions` | wie oben; Export; häufige frühere Gerichte |
| `GET/POST /catalogs`, `GET/PUT/DELETE /catalogs/{id}` | Kataloge (Name, Gerichte mit optionalem Preis in Cent) |

Öffentlich (kein Login, Token im Pfad), Basis `/api/v1/public/groups/{token}`:

| Methode, Pfad | Zweck |
| --- | --- |
| `GET /` | `{type: "poll"\|"order", poll?, order?}` |
| `POST /votes` → 201 `{vote, editSecret}`; `PUT/DELETE /votes/{voteId}` mit Header `X-Edit-Secret` | abstimmen, ändern, zurückziehen |
| `POST /entries` → 201 `{entry, editSecret}`; `PUT/DELETE /entries/{entryId}` mit `X-Edit-Secret`; `POST /entries/{entryId}/take` → 201 | Eintrag anlegen/ändern/löschen; Gericht eines anderen übernehmen (`{name, quantity?, note?}`) |
| `GET /export?format=csv\|txt` | Bestellliste herunterladen |

Fehlercodes (stabil): 404 `not_found` (auch für ungültige/erneuerte Links, deaktivierte Besitzer, falschen Typ), 404 `module_disabled`, 403 `edit_secret_invalid`, 409 `group_closed`, `group_full`, `name_taken`, `too_many_polls|orders|catalogs`, 400 `answers_invalid`, `deadline_in_past`, `bad_request`, 429 `too_many_requests` (mit `Retry-After`). Deutsche Meldungen in `GroupMessages`.

## Schemas (Kurzform, Details im Vertrag)

- Umfrage: `kind` text|date, `choiceMode` single|multi, `options[]` (`id`, `label` bzw. `date` + optional `startTime`/`endTime` lokal HH:mm, `timeZone`), `closed` (manuell oder Frist), `finalOptionId`, `resultsVisible`, `voteCount`, `votes[]` (`name`, `answers[{optionId, answer yes|maybe|no}]`, Optionen ohne Eintrag = no), `tally[{optionId, yes, maybe, no}]`. Bei `hideResults` und offener Umfrage fehlen `votes`/`tally` öffentlich.
- Bestellrunde: `entries[]` (`name`, `item`, `note`, `quantity`, `priceCents`), `aggregated[]` (gleiche Gerichte, `quantity`, `names`), `totalCents`, `unpricedQuantity`, `suggestions[]` (Katalog-Gerichte), `closed`.
- Öffentliche Ansicht enthält keine `id`/`catalogId`/Besitzerdaten.

## Was die PWA braucht (Paket G1-PWA, nicht umgesetzt)

1. **SPA-Route `/g/{token}` ohne Anmeldung** (Layout ohne Login-Weiterleitung, kein Navigations-Chrome der App). Das Backend liefert dafür die SPA-Hülle (`PWAStaticMiddleware` schließt nur `/api`, `/health`, `/ready`, `/.well-known`, `/oauth/authorize`, `/mcp`, `/t`, `/ics` aus; `/g/…` fällt bewusst auf die Hülle zurück und trägt `X-Robots-Tag: noindex, nofollow` und `Referrer-Policy: no-referrer`). In der Hülle selbst sollte zusätzlich `<meta name="robots" content="noindex">` stehen (nur Header ist durch Caches/Service Worker nicht immer erhalten).
2. **Service Worker**: `/api/v1/public/groups/**` und `/g/**` dürfen nicht aus dem Cache bedient werden (Network-only; Antworten sind `no-store`, aber ein SW-Precache/„stale-while-revalidate“ würde sie dennoch halten). Die SPA-Hülle für `/g/*` darf wie jede andere Route aus dem App-Shell-Cache kommen, die Daten nicht. `/g/…` nicht in Sitemaps/Precache-Listen aufnehmen.
3. **Bearbeitungsschlüssel**: `editSecret` aus der Antwort je Token in `localStorage` ablegen (z. B. Schlüssel `tt-groups:<token>` → `{name, votes: {voteId: secret}, entries: {entryId: secret}}`), als `X-Edit-Secret` senden; bei 403 `edit_secret_invalid` lokalen Eintrag verwerfen. Gemerkten Anzeigenamen vorbelegen. Ohne Schlüssel keine Bearbeiten-Schaltflächen anzeigen.
4. **Besitzerbereich** (angemeldet, Modul `groups` in den Modulschaltern ergänzen: `GET /modules` liefert nun sechs Schlüssel): Listen, Anlegen (Umfrage Text/Termin, Bestellrunde, Katalog-Verwaltung), Detail mit Stimmen/Einträgen, Beenden/Öffnen/Endergebnis/Link erneuern/Löschen; Link nur direkt nach Anlegen/Erneuern anzeigen (kopieren, `<origin>` + `path`), danach Hinweis „Link erneuern, falls verloren“.
5. Frist- und Zeitzonenanzeige: Terminoptionen sind lokale Datum/Uhrzeit in `timeZone`; `deadline` ist ein Zeitpunkt (ISO 8601, UTC).
6. Texte (deutsch): Fehlermeldungen kommen im `error.message` mit; 429 mit Wartehinweis.
7. Teilen: Web Share/Kopieren des Links; kein Tracking, keine externen Ressourcen auf der öffentlichen Seite.

Apple-Apps: nicht betroffen (keine Besitzer- oder Teilnehmeroberfläche gefordert).

## Betrieb

- `GROUPS_RETENTION_DAYS` (Standard 90, 1–3650): Löschfrist nach Beenden/Frist, Aufräumjob (Schritte `group_polls`, `group_orders`, Lease `maintenance`). Offene Elemente ohne Frist bleiben.
- `MODULES_DISABLED=groups` schaltet die gesamte Oberfläche (Besitzer- und öffentliche API) ab.
- Reverse Proxy: Pfade `/g/` und `/api/v1/public/groups/` aus Zugriffsprotokollen schwärzen (siehe `docs/installation/proxy.md`). Optional strengere Ratenbegrenzung am Proxy.
- Neue Tabellen (Migration `g1.create_groups`): `group_polls`, `group_poll_options`, `group_poll_votes`, `group_poll_answers`, `group_orders`, `group_order_entries`, `group_catalogs`, `group_catalog_items`.

## Tests

`Tests/TimetrackKitTests/GroupTests.swift` (19 Tests: Token/Hash/Datenschutz, falsche und typfremde Token, Abstimmungsregeln, Eingabegrenzen, 500-Stimmen- und 200-Einträge-Grenze, Beenden/Frist/verdeckte Ergebnisse/Endoption, Besitzeraktionen/Link erneuern/Löschkaskade, Besitzer-Autorisierung/CSRF/Fremdkonto, Bestellungen/Aggregation/Übernehmen, Export CSV+Text mit Formelinjektion, Kataloge/Vorschläge, Ratenbegrenzung je IP/Link/Fehlversuch/Schlüsselraten, Modulschalter inkl. Betreiber-Sperre und deaktivierter Besitzer, Aufbewahrung, Kontoexport und -löschung, SPA-Route/Header, Log-Schwärzung); angepasst: `ModuleTests`, `ContractShapeTests` (öffentliche und Besitzerformen gegen den Vertrag). Zahlen: vollständiger Lauf SQLite 472 Tests, 42 übersprungen, 0 Fehler; die 19 G1-Tests auf MariaDB 12.3.3: 0 Fehler.

## Nicht geprüft / offene Risiken

- **MariaDB**: nur die 19 G1-Tests liefen auf MariaDB 12.3.3 (Wegwerf-Container, `G1_ON_MARIADB=1 MARIADB_TEST_HOST=… swift test --filter testG1`); der übrige Bestand (Module-, Vertrags-, Kontolöschungstests) nur auf SQLite. Die Migration nutzt nur Fluent-Standardtypen und `TEXT`, keine DB-spezifischen Konstrukte.
- Echte Reverse-Proxy-Konstellation (Client-Adresse aus `X-Forwarded-For`) für die IP-Ratenbegrenzung ungeprüft (nutzt `clientRateLimitKey`, ADR-0018). Hinter einem Proxy ohne konfigurierte `TRUSTED_PROXIES` teilen sich alle Besucher einen Zähler (dann treffen 40 Schreibzugriffe je 5 Minuten gemeinsam).
- Durchsatz: Schreibzugriffe laufen unter der globalen `auth_lock` (ADR-0017); Lasttest nicht gemacht.
- Kein Captcha; Spam durch Link-Besitzer bis zu den Grenzen möglich.
- Zeitzonen von Terminoptionen werden nur als Bezeichner validiert, nicht ausgewertet; Zeitüberschneidungen werden nicht geprüft.
- Beendete Elemente werden nur vom Aufräumjob gelöscht (Intervall `MAINTENANCE_INTERVAL_MINUTES`, Standard 60 min); der Lauf selbst ist getestet, der periodische Scheduler nicht für diese Schritte gesondert.
