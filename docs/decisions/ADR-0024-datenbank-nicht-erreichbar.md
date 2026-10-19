# ADR-0024: Datenbank nicht erreichbar ist 503, nicht 500

Status: Umsetzungsentscheidung von Paket S1a (Fehlerbild aus der Produktion, 18.10.2026); Lead-Prüfung offen.

## Kontext

In Swarm (2 Replikate, MariaDB) war auf einem Replikat die Datenbank nicht erreichbar („Opening new connection for pool failed … Connection refused“). Anfragen lieferten HTTP 500 mit Code `not_ready`, weil `APIErrorMiddleware` jeden unbekannten Fehler so abbildet. Ein 500 wirkt wie ein Programmfehler; Clients und Proxys wiederholen ihn nicht.

## Entscheidungen

1. **Klassifizierung** (`InfrastructureError.classify`, `Sources/TimetrackKit/InfrastructureError.swift`): Verbindungs- und Pool-Fehler (`ConnectionPoolTimeoutError`, `ConnectionPoolError`, NIO `IOError`/`NIOConnectionError`/`ChannelError`, NIOSSL-Fehler, `MySQLError.closed`, MariaDB-Serverfehler 1040/1053/1129/1203/2002/2003/2006/2013, SQLite busy/locked/cantOpen/ioError) sowie über `NSUnderlyingErrorKey` eingewickelte Ursachen. Alles andere (Syntaxfehler, doppelte Einträge, echte Fehler) bleibt 500.
2. **Antwort:** 503, Code `database_unavailable`, deutsche Meldung „Der Server kann die Datenbank gerade nicht erreichen. Bitte gleich noch einmal versuchen.“, Header `Retry-After: 2` (Pool-Zeitlimit: 5). Geloggt wird einmal je Anfrage auf Warnstufe nur die Klasse („database connection failed“), ohne Host, Zugangsdaten oder SQL.
3. **Bereitschaft unverändert:** `GET /ready` fragt die Datenbank ab (mit einem Wiederholversuch) und liefert bei Ausfall 503 `not_ready`; der Swarm-Healthcheck (`stack.yaml`, `curl -fsS /ready`, 15 s, 5 Wiederholungen) nimmt ein solches Replikat nach etwa 75 s aus der Rotation, `/health` bleibt absichtlich unabhängig von der Datenbank (Lebendigkeit). Der Reverse Proxy des Betreibers sollte `/ready` oder `/health` je nach Wunsch prüfen; ohne eigenen Check verteilt der Swarm-Ingress nur auf gesunde Tasks.
4. **Vertrag v0.20.0** (additiv): gemeinsame Antwort `ServiceUnavailable` mit `Retry-After`.

## Offen

- MCP-Werkzeugaufrufe melden Infrastrukturfehler weiterhin als `internal_error` (kein HTTP-Status im JSON-RPC-Ergebnis).
- Die PWA behandelt 503 mit `Retry-After` noch nicht automatisch (Wiederholung); Folgepaket im PWA-Repo.

## Nachtrag S1b (19.10.2026): Klassifizierung und ausgehende Aufrufe

Befund Q1: Allgemeine NIO-Fehler (`IOError`, `NIOConnectionError`, `ChannelError`, `NIOSSLError`) werden als Datenbankausfall gemeldet, auch wenn sie von einem anderen ausgehenden Aufruf stammen. Geprüft: Alle ausgehenden Netzwerkaufrufe fangen oder verpacken ihre Fehler selbst (S3 `StorageBackendError`, SMTP `SMTPError`/Diagnose-Ergebnis, Push `PushOutcome.retry`, MCP als JSON-RPC-Fehler); die einzige Lücke war der OIDC-Client (`http.execute`/`collect`): sein Transportfehler wird jetzt als `OIDCClientError.network` geworfen (Test mit geschlossenem Port; `InfrastructureError.classify` liefert dafür `nil`).

Bewusst **nicht** umgesetzt: eine harte Beschränkung der Middleware auf Fehler, die nachweislich aus einer Datenbankoperation stammen. Eine Grenze im Treiber (Verpacken von `Database`) bricht die SQL-Zugriffe (`requireSQL`), und Fluents Abfrageverlauf erfasst Rohabfragen (`auth_lock`, Migrationen) nicht. Ein Beschränken auf einzelne Transaktions-Helfer würde unauthentifizierte Pfade (Anmeldung) wieder auf 500 zurückfallen lassen, also genau den Fehler aus dem Kontext dieses ADR. Stattdessen: ausgehende Aufrufe liefern nie rohe NIO-Fehler (Regel für neue Clients), und die Warnzeile nennt jetzt zusätzlich den Swift-Typ (`infrastructure error: database connection failed (IOError)`, ohne Meldungstext), damit eine Fehlzuordnung im Log auffällt.
