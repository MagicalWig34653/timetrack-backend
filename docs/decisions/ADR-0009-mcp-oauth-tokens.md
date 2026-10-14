# ADR-0009: MCP-Server, OAuth-Autorisierungsserver und persönliche Tokens (Etappe 4b)

Status: akzeptiert (Lead-Entscheidung 15.10.2026; bestätigte Richtung aus ARCHITEKTUR.md Abschnitt 3, Details sind Annahmen). Zielclients: ChatGPT und Claude über OAuth; andere Clients über persönliche Bearer-Tokens. Gleiche Fachregeln und Kontorechte wie REST.

## Transport und Protokoll

- Endpunkt `POST /mcp` (Streamable HTTP, JSON-RPC 2.0). Antworten als `application/json` (kein SSE nötig, `GET /mcp` → 405). Methoden: `initialize` (Protokollversion `2025-11-25`; Aushandlung mit älteren Versionen `2025-06-18`/`2025-03-26`), `notifications/initialized`, `ping`, `tools/list`, `tools/call`. Keine Resources/Prompts in v1.
  Origin-Prüfung: Browser-Origin wird abgewiesen, außer er stimmt mit `PUBLIC_BASE_URL` überein (DNS-Rebinding-Schutz); Body ≤ 256 KiB.
- Fehler: ohne/mit ungültigem Token → HTTP 401 mit `WWW-Authenticate: Bearer resource_metadata="<PUBLIC_BASE_URL>/.well-known/oauth-protected-resource"` (+ `error="invalid_token"` falls Token vorhanden); fehlender Scope → JSON-RPC-Toolfehler mit `isError: true` und HTTP 200 für Toolebene bzw. 403 `insufficient_scope` für Protokollebene (`WWW-Authenticate: Bearer error="insufficient_scope", scope="…"`).

## OAuth 2.1 (Resource Server + Authorization Server im Backend)

- Metadaten: `/.well-known/oauth-protected-resource` (RFC 9728, resource = `<PUBLIC_BASE_URL>/mcp`), `/.well-known/oauth-authorization-server` (RFC 8414, plus `/.well-known/openid-configuration` nicht nötig).
- Clientregistrierung: Dynamic Client Registration `POST /oauth/register` (RFC 7591) für öffentliche Clients (`token_endpoint_auth_method: none`), `redirect_uris` müssen https oder Loopback-http sein, keine Wildcards, max. 5, Name ≤ 100 Zeichen; Rate-Limit pro IP; nicht benutzte Registrierungen verfallen nach 30 Tagen. Zusätzlich vorregistrierte/„Client ID Metadata Document“-Clients sind nicht Teil von v1.
- Authorization Code Flow mit **PKCE S256 Pflicht**: `GET /oauth/authorize` (client_id, redirect_uri exakt, response_type=code, code_challenge, scope, state, `resource` muss `<PUBLIC_BASE_URL>/mcp` sein) → Weiterleitung zur PWA-Consent-Seite `/oauth/consent?request=<id>`; nicht angemeldet → Login (Passkey) und zurück. Consent zeigt Client-Name, Konto, angefragte Scopes (einzeln abwählbar), Hinweis auf Widerrufbarkeit; Entscheidung per `POST /api/v1/oauth/requests/{id}/decision` (Sitzung + CSRF, einmalig). Code 60 s, einmalig, an client/redirect/PKCE/resource gebunden.
- `POST /oauth/token`: `authorization_code` (PKCE) und `refresh_token` (Rotation mit Wiederverwendungserkennung: wiederverwendetes Refresh-Token widerruft die ganze Grant-Kette). Access-Token opak (`tto_…`, 32 Byte Zufall, nur SHA-256 gespeichert), Gültigkeit 1 h; Refresh 30 d. Audience = MCP-Resource; keine Weitergabe von Provider-Tokens. `POST /oauth/revoke` (RFC 7009).
- Grants: `GET /api/v1/me/oauth-grants`, `DELETE /api/v1/me/oauth-grants/{id}` (widerruft alle Tokens des Grants sofort). Einladungspflicht bleibt: OAuth erzeugt nie Konten.

## Persönliche Bearer-Tokens

`GET/POST /api/v1/me/api-tokens`, `DELETE …/{id}`: Name, Scopes (Teilmenge der unten), Ablauf (Pflicht, 1–365 Tage), Klartext (`ttp_…`) nur einmal, nur Hash gespeichert, `lastUsedAt`, einzeln widerrufbar, erfordert frische Sitzung zum Anlegen. Gelten nur für `/mcp` (nicht für REST), niemals für Admin-Aktionen. Übertragung nur im Header, nie in URLs; keine Secrets in Logs.

## Scopes und Tools (v1)

| Scope | Tools (Name → REST-Dienst) |
| --- | --- |
| `time:read` | `get_day`, `list_days` (≤ 31 Tage), `get_time_account`, `list_segments`, `get_current_timer` |
| `time:write` | `start_timer`, `stop_timer` (idempotent über `clientEventId`), `create_segment`, `correct_segment` (Pflicht `expectedVersion` + `reason`) |
| `schedule:read` | `list_absences`, `get_vacation_balance`, `list_holidays`, `list_plan_days`, `view_shared` (nur freigegebene Ansichten anderer) |
| `schedule:write` | `create_absence` (Status nur `planned`/`requested`), `set_plan_day` |
| `reports:read` | `get_report_week`, `get_report_week_text`, `list_learning_fields` |
| `reports:write` | `create_report_entry`, `update_report_entry` (Pflicht `expectedVersion`) |
| `documents:read` | `list_absence_attachments` (nur Metadaten; kein Dateiinhalt in v1) |

Keine Lösch-, Admin-, Freigabe-, Token- oder Speicher-Tools. Schreibende Tools nutzen dieselben REST-Fachdienste inkl. Idempotenz und Versionsprüfung; Abwesenheiten werden nicht per MCP genehmigt. Toolantworten: `content` (Text, JSON) + `structuredContent`; Annotationen `readOnlyHint`/`destructiveHint`/`idempotentHint`. Toolbeschreibungen und Read-only-Hinweise ersetzen keine Rechteprüfung; Inhalte aus Notizen/Berichtstexten sind Daten, keine Anweisungen (in Toolbeschreibung vermerkt).
Ein Lesetoken kann nicht schreiben; Dokumentrechte folgen nicht aus Zeitplanrechten; Freigaben werden nur über `view_shared` mit denselben Feldgrenzen wie REST geliefert. Audit: Tabelle `mcp_audit` (Zeit, Token/Grant, Tool, Ergebnis ok/error, Dauer), ohne Parameter-/Ergebnisinhalte.

## Pakete

C16 OAuth-Server + Tokens + Grants (Backend), C17 MCP-Endpunkt + Tools (Backend), L15 PWA (Consent, Tokens, Grants, Hilfe zur Einrichtung in ChatGPT/Claude), danach E2E (Wegwerf-Backend + Skript-MCP-Client + OAuth-Flow im Browser). Nicht prüfbar ohne Nutzer: Anbindung in echtem ChatGPT/Claude (erreichbare Domain `test.example.org` vorhanden; Nutzer trägt den Connector selbst ein).
