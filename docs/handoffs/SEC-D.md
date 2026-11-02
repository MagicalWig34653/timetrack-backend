# Handoff SEC-D (Härtung optional, 01.11.2026)

Branch `sec-d`, Befunde aus `docs/reviews/2026-11-01-security-review.md`. Keine API-Änderung (OpenAPI/Vertrag unverändert), keine Migration.

| Befund | Entscheidung | Umsetzung |
|---|---|---|
| H-01 | bestätigt (Code), behoben | `XLSXPackage.isSafeXML`: nur UTF-8/ASCII, UTF-16/32 (BOM oder Nullbytes) und deklarierte Fremdkodierungen werden als `unsupported_type` abgelehnt. Test `testXMLInOtherEncodingsIsRefused`. Der Test lief nicht gegen den alten Code. |
| SEC-09 | umgesetzt, optional | `STORAGE_S3_ALLOWED_HOSTS`, `STORAGE_LOCAL_ROOT` (beim Speichern und Nutzen). Standard ohne Einschränkung. Weiterleitungen des S3-Clients nicht abgeschaltet. Test `scenarioStorageAllowLists`. Doku `docs/BETRIEB.md`. |
| SEC-10 | umgesetzt | `link_token` mit `STORAGE_SECRET_KEY` verschlüsselt (`enc1:`); Altwerte lesbar; ohne Schlüssel wie bisher. Test `testG1LinkTokenIsEncryptedAtRestWhenKeyConfigured`. |
| SEC-14 | teilweise/dokumentiert | Kein SHA-Pinning, keine `revision:`-Pins (Begründung `docs/CI.md`). `npm audit fix` mit npm 10.9.9 ändert die Lock-Datei nicht; Rest braucht Redocly-Major, daher offen. |
| SEC-16 | umgesetzt | Log `unhandled error: <Typ> on <Methode Routenvorlage>`. Test `testUnknownErrorIsLoggedWithTypeAndRouteTemplateOnly`. |
| SEC-17 | bewusst nicht geändert | Eindeutige Rückmeldung beim Teilen gewollt; Restrisiko dokumentiert. |

Tests: Linux `swift:6.3-noble`, SQLite, vollständig 478 Tests, 42 übersprungen; ein Fehler im neuen SEC-16-Test (Logzeile des Frameworks enthielt den Pfad, Test nun auf die eigene Zeile gefiltert und einzeln grün).
