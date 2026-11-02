# Übergabe CX-A: Befunde F01, F02, F03 des Codex-Reviews (02.11.2026)

Branch `cx-a`, Code-Commit `7e64cb7`, Vertrag **0.41.1** (nur strengere Eingabegrenze, keine neuen Felder). Alle drei Befunde wurden vor der Änderung am Code nachvollzogen und sind bestätigt (keine falsch positiven).

## Was geändert wurde

- **F01 (high):** Neue zentrale `Pagination.range(limit:offset:maxLimit:)` (`Sources/TimetrackKit/Pagination.swift`): `limit` 1...Maximum der Liste, `offset` 0...100000, Summe mit `addingReportingOverflow`; Verstoß = 400 `bad_request`. Angewendet auf alle drei Listen mit `offset`: stornierte Segmente (`TimeCancelled.swift`, REST und MCP), Zeitkonto-Anpassungen (`TimeEvaluationServices.swift`, REST und MCP; hatte die Grenze 100000 bereits, nutzt jetzt den gemeinsamen Helfer) und Konten-Admin-Liste (`AccountAdminService.swift`). Benachrichtigungen (`before`-Cursor mit `limit` 1...100), Abwesenheits-/Plan-/Statistikbereiche (`checkedRange`) und Vorschlagsliste (`limit` 1...100) haben keinen `offset` und waren nicht betroffen. MCP-Schemas der beiden Tools führen `maximum: 100000` für `offset`.
- **F02 (high):** `createToken` und `decide` authentifizieren die Sitzung in der `auth_lock`-Transaktion erneut (wie `TimeServices.session`), prüfen `fresh()` bzw. `normal()` auf dem aktuellen Kontext und leiten Konto und Consent-Bindung daraus ab. Widerrufene Sitzung = 401 `unauthorized`, es entsteht kein Token, kein Grant, kein Code, die Anfrage wird nicht verbraucht. Zusätzlich bekommt `revokeGrant` dieselbe Prüfung. Alle übrigen `auth.transaction`-Stellen wurden durchgesehen: Sitzungsabhängige Schreibpfade prüfen bereits erneut (`Profile`, `Recovery`, `WebAuthn`, `Storage`, `OIDC`, `Account-Admin`, Module); Geräte-Token, Kalenderabos, Trigger-Links und Gruppen-Links laufen über `TimeServices.session`. Push-Abos/-Geräte und Benachrichtigungseinstellungen schreiben mit der Konto-ID aus der Middleware, erzeugen aber keine Zugangsdaten (Restrisiko gering, nicht Teil dieses Pakets).
- **F03 (medium):** `McpPrincipal`/`McpAuthPrincipal` tragen den Token-Hash. `McpAuthenticator.revalidate` löst das Credential in der Tool-Transaktion unter dem Lock neu auf (`revalidateMcpPrincipal`: Widerruf, Ablauf, Konto, Modul, aktuelle Scopes; Hash-gleiche Prüfung der Zugangsdaten-ID, ohne `last_used_at` zu schreiben). Das Tool sieht den neu aufgelösten Principal; der Scope des Tools wird dagegen geprüft (`insufficient_scope`), ein erledigtes Credential ergibt `unauthorized`. Ein Principal ohne Hash schlägt geschlossen fehl (nur die Standard-Implementierung für Test-Doubles lässt ihn durch).

## Auswirkungen auf Clients

- **Alle Clients:** `offset` über 100000 (Konten-Admin-Liste, stornierte Segmente) liefert jetzt 400 statt unbegrenzt (vorher Prozessabbruch bei `Int.max`). Normale Seitenabrufe sind unverändert; kein Client-Code nötig.
- **PWA/Apple, Token- und Consent-Aktionen:** Eine während des Vorgangs widerrufene Sitzung führt zu 401; das ist der vorhandene Abmelde-Pfad.
- **MCP-Clients:** Ein während der Tool-Ausführung widerrufenes oder eingeschränktes Token liefert `unauthorized` bzw. `insufficient_scope`; Tool-Schemas führen `offset` mit Maximum.

## Tests

`Tests/TimetrackKitTests/CXAReviewTests.swift`: Helfer-Grenzwerte (`Int.max`, `Int.min`, 100001), REST/MCP/Dienste mit `Int.max`, Seite bei Maximum leer; Sitzung widerrufen vor `createToken`/`decide` (nichts angelegt, Anfrage nicht verbraucht), Kontrolle mit lebender Sitzung; MCP-Tool nach Scope-Einschränkung, Ablauf und Widerruf (Personal-Token und OAuth-Grant), Principal ohne Hash; HTTP-Aufruf mit eingeschränktem Token. Nur SQLite im Lauf des Pakets.
