# Handoff SCOPE-F10: OAuth-Scope-Vorbelegung und Blockwoche mit mehr als fünf Schultagen

Branch `scope-f10`, Vertrag **0.44.0**. Nutzerentscheidungen 02.11.2026 (Todolino).

## 1. OAuth-Scope-Vorbelegung (SEC-12, ADR-0009 Nachtrag)

- Ohne `scope`-Parameter sind nur `time:read`, `schedule:read`, `reports:read`, `documents:read` vorbelegt (`McpScopes.readOnly`). Mit `scope` ist alles unverändert.
- `OAuthRequestRecord` hat zwei nullbare Spalten (Migration `oauth.add_request_scope_sets`): `requested_scopes` (angefragt, leer ohne Parameter) und `available_scopes` (wählbar: ohne Parameter alle sieben, sonst die angefragten). NULL (Alt-Anfragen) verhält sich wie vorher.
- `GET /oauth/requests/{id}` liefert `scopes` (Vorbelegung), `requestedScopes`, `availableScopes`. `decide` gewährt nur Scopes aus `availableScopes`, ohne `scopes` im Body die Vorbelegung. Refresh-Rotation, bestehende Grants und Tokens unverändert.
- Tests: `scenarioOAuthAuthorizeValidation` (Datensatz), `scenarioOAuthConsent` (Flow ohne scope: nur lesend; Erweitern um `time:write`; mit scope: nichts darüber hinaus, 400). Der Testhelfer `oaFlow` erlaubt ohne scope ausdrücklich alle Scopes, damit andere Tests (volle Rechte) stabil bleiben.
- Doku: `docs/MCP.md`, ADR-0009 Nachtrag, Vertragstext.

## 2. F10: Blockwoche mit mehr als fünf Schultagen (ADR-0028 Nachtrag)

- Die ersten fünf Schultage (Montag bis Sonntag) bekommen 8 h Gutschrift; jeder weitere Schultag keine Gutschrift, Soll unverändert, kein Rückfall auf die Einzeltagsregel (`isCreditedBlockWeekDay`, `PreparedEvaluation.baseEvaluation`).
- Schultag = Schulsegment und Tagesmarkierung `none`. Feiertage, Urlaub, Krank, Freistellung und ausdrückliche Gutschrift-Markierung zählen nicht mit; der nächste Schultag rückt nach. Die Blockwochen-Erkennung (mindestens fünf Tage mit Schulsegment, 25 Stunden) ist unverändert.
- Auswirkungen: Zeitkonto, Wochen-/Monatssumme, Statistik und Export lesen dieselbe Tagesauswertung (`creditSeconds`/`targetSeconds`) und folgen ohne weitere Änderung; keine Vertragsfelder neu. Bereits gebuchte Wochen mit sechs oder mehr Schultagen werden rückwirkend neu bewertet (Gutschrift sinkt).
- Tests (`MinorLegalProfileTests`): 5 Tage (unverändert), 6 Tage, 7 Tage, Soll des Zusatztags, Feiertag, Urlaub; der Charakterisierungstest ist ersetzt.

## Client-Auswirkungen (nicht geändert)

- PWA-Zustimmungsseite: `scopes` zeigt jetzt nur die Vorbelegung; ein alter Client sieht daher ohne scope nur lesende Rechte und kann keine Schreibrechte ergänzen. Für die Ergänzung muss die Seite `availableScopes` anzeigen (nicht vorbelegte abgewählt), `requestedScopes` zur Kennzeichnung nutzen und gewählte Scopes in `decision.scopes` senden.
- Apple: keine Zustimmungsseite; Blockwochen-Anzeige folgt den Tageswerten.
