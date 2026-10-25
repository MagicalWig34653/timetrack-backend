# X3 – Backend-Lücken für Clients

Stand: 24.10.2026, Branch `worktree-agent-ad51edf6202fb6b47`. Vertrag `0.29.0`.

## Aufrufe für Clients

Alle Pfade beginnen mit `/api/v1`. Lesende Aufrufe benötigen die Sitzung; Schreibaufrufe benötigen Sitzung und CSRF-Header. `If-Match` ist die zuletzt gelesene numerische Segmentversion (z. B. `"3"`).

| Aktion | Aufruf | Antwort |
| --- | --- | --- |
| Prüfmarkierung quittieren | `PATCH /time/segments/{id}`, Body `{"needsReview":false,"reason":"Geprüft"}`, Header `If-Match: "3"` | `200` Segment mit `needsReview:false`, erhöhter `version` und `revisions`; veraltete Version `412` |
| Ende korrigieren | `PATCH /time/segments/{id}`, Body `{"endedAt":"2026-10-12T16:00:00Z","reason":"Ende korrigiert"}`, Header `If-Match: "3"` | `200` Segment; neu gesetztes oder geändertes Ende löscht `needsReview` automatisch |
| Ende-Vorschlag annehmen | `POST /time/suggestions/{id}/accept`, optional Body `{"endedAt":"2026-10-12T16:00:00Z"}` | `200` Segment mit `needsReview:false` und Revision |
| Ende-Vorschlag ablehnen | `POST /time/suggestions/{id}/reject` | `204`; zugehörige Prüfmarkierung ist entfernt und eine Revision angelegt |
| Anpassungen laden | `GET /time/account/adjustments?limit=50&offset=0` | `200` `{ "items": [{"id":"…","kind":"opening","date":"2026-10-12","seconds":3600,"reason":"Anfangsstand","createdAt":"…"}], "total":1,"limit":50,"offset":0 }`; neueste zuerst; `limit` 1–100, `offset` 0–100000 |
| Anpassung löschen | `DELETE /time/account/adjustments/{id}` | `200` vollständiges `TimeAccount` mit neu berechnetem Saldo; fremde/unbekannte ID `404` |

`kind` ist `opening` oder `correction`; `seconds` ist vorzeichenbehaftet. Die Anlage bleibt `POST /time/account/adjustments` und antwortet weiterhin mit dem Zeitkonto. Ein gelöschter Anfangsstand kann erneut angelegt werden. `needsReview:true` bei der Korrektur ergibt `400`. Das rohe Segmentende bleibt bei Korrekturen unverändert.

MCP `list_time_adjustments` (`time:read`) liefert dieselbe Seite mit `limit` und `offset`; `correct_segment` versteht `needsReview:false`. Für Löschungen gibt es kein MCP-Werkzeug. Die Audit-Spur einer Löschung enthält nur die Anpassungs-ID. Der Kontoexport enthält nur aktive Anpassungen einschließlich ID und `createdAt`; die Kontolöschung entfernt sie.

## Umsetzung und Prüfung

Migration `x3.add_adjustment_created_at` ergänzt den Erstellungszeitpunkt. Bestehende Zeilen erhalten den Zeitpunkt des Migrationslaufs; bei gleichem Zeitpunkt ordnet die ID die Seiten stabil. Segmententscheidungen und die Löschung laufen innerhalb der bestehenden Konto-Transaktion. Der OpenAPI-JSON-Spiegel wurde mit `scripts/contract-json.sh` erzeugt. Sieben gezielte Tests sind grün; der vollständige Lauf ist durch die Sandbox-Sperre für lokale Socket-Bindungen rot (Details und nächster Schritt in `docs/STATUS.md`). Die Migration wurde auf keiner produktiven Datenbank ausgeführt.

Geänderte Bereiche: `Sources/TimetrackKit/Time*`, `Configure.swift`, `SystemInfo.swift`, `MCP/MCPTools.swift`, `Accounts/AccountExportService.swift`; Tests in `TimeHTTPTests.swift`, `MCPTests.swift`, `AccountAdminTests.swift`; Vertrag, Changelog und Projekt-Dokumentation. Git-Änderungen sind in diesem Worktree noch nicht committet; Lead-Integration steht aus. Laufende Jobs: keine. Nächster Schritt: seriellen Gesamtlauf in einer Umgebung mit erlaubten lokalen Sockets durchführen, danach bei verfügbarer MariaDB-Testdatenbank die Datenbankvariante prüfen und integrieren.
