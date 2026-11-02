# Handoff POOL-FIX: Pool-Timeouts in der Produktion (02.11.2026)

Branch `pool-fix`. Keine Vertragsänderung, keine Migration, keine neue Konfiguration. Untersucht wurde der Stand ab `c7b6417` (Vertrag 0.42.0) gegen `428fd67`.

## Meldung

Swarm, MariaDB, `poolPerLoop=1 poolTimeout=10s`. Der Start ist unauffällig („database connection OK“). Etwa eine Stunde später erscheinen Dutzende `Connection request timed out ... [database-id: mysql, waiter: 740..753]`, `notification runner tick failed (ConnectionPoolTimeoutError)` und `database keep-alive ping failed: connectionRequestTimeout`. Die Instanz erholt sich nicht.

## Geprüfte Hypothesen

| | Hypothese | Ergebnis |
| --- | --- | --- |
| a | Verschachtelte Verbindungsanforderung in einer Transaktion (CX-A F02/F03, SEC-A, SEC-C) | **Nicht belegt, im Code nicht gefunden.** Alle neuen Pfade (`OAuthCredentials.createToken/decide/revokeGrant`, `McpToolContext.session` mit `revalidate`, `reserveMail`, `recoveryLocked`, `recordRecoveryFailure`, Export-Audit, `enforceQuota`) arbeiten in der Transaktion ausschließlich auf `tx`. Die Aufrufe davor und danach (`limited`, `notify`, Wartungsschritte) laufen nacheinander, nicht verschachtelt. Ein verschachteltes Anfordern bei 1 Verbindung je Loop wäre zudem deterministisch (jede einzelne Anfrage hinge 10 s); die komplette Suite lief mit der Standardkonfiguration (1 je Loop) auf MariaDB grün. Last-Test `testPoolStressWithOneConnectionPerLoop`: 900 gemischte Anfragen, 120 parallel, 6 Event-Loops, 1 Verbindung je Loop, Pool-Frist 5 s (Sitzung, Timer, Token anlegen, MCP-Tool, OAuth-Authorize, OAuth-Grants, Benachrichtigungen, Wiederherstellung anonym, `/ready`): 0 Antworten ≥ 500, Dauer 1 s. |
| b | Reihenfolge der Sperren nach Entfernen von `auth_lock` in `limited` (SEC-11) | **Nicht belegt.** `limited` zählt und schreibt ohne Sperre, das Aufräumen ist eine eigene Anweisung. Das kann höchstens kurze InnoDB-Wartezeiten oder einen erkannten Deadlock (ein 500) erzeugen, keinen Pool-Stillstand. |
| c | Lang laufende Hintergrundjobs (Notification-Runner, Wartung `oauth_clients`, Outbox) | **Nicht belegt.** Sie halten keine Verbindung über eine Wartezeit, `MailOutbox` nutzt keine Datenbank. Die Meldungen des Runners und des Pings sind Folgen, nicht Ursache. |
| d | Verlorene Verbindung, Pool erholt sich nicht | **Mechanismus belegt** (siehe unten). Das gab es vor SEC-* ebenso; mit `git blame` und Vergleich von 428fd67 ist am Pool-Code seit X1/Hotfix (17.10.) nichts geändert worden. |

## Belegter Mechanismus

Nachgestellt in Linux (`swift:6.3-noble`, MariaDB 12.3.3) mit `socat` als Zwischenstück, dessen Kindprozess per SIGSTOP stillgelegt wird: Die TCP-Verbindung bleibt offen, es kommt kein RST/FIN (wie ein von Firewall/NAT/IPVS verworfener Fluss). Eine Abfrage auf dieser Verbindung kehrt nie zurück; die einzige gepoolte Verbindung des Event-Loops bleibt belegt. Folgen, genau wie im Log:

- alle weiteren Anfragen dieses Loops laufen nach der Pool-Frist in `ConnectionPoolTimeoutError` („Connection request timed out“, steigende `waiter`-Nummern);
- der Keep-Alive-Ping desselben Loops wartet ebenfalls (`connectionRequestTimeout`) bzw. der **bisherige Ping hing selbst für immer** und hielt damit auch die Pings aller anderen Loops an (eine einzige Schleife über alle Loops);
- `/ready` prüfte `request.db`, also nur den Pool eines zufälligen Loops. Bei 2 von 6 festgefahrenen Loops lieferte `/ready` in 13 von 24 Aufrufen 200, die übrigen hingen. Swarm braucht 5 aufeinanderfolgende Fehlschläge und ersetzt den Task deshalb praktisch nie: die Instanz „recovert nicht“.

Vorher/nachher (gleicher Test, 2 von 6 Verbindungen stillgelegt):

| | `/ready` 200 | `/ready` 503 | hängt | Anfragen nach Keep-Alive-Heilung |
| --- | --- | --- | --- | --- |
| vorher | 13 | 0 | 11 | 24 von 36 in Ordnung |
| nachher | 0 | 24 | 0 | 36 von 36 in Ordnung |

## Nicht belegt: der Auslöser in der Produktion

Warum eine Verbindung dort still verworfen wurde, ist aus dem Log nicht ableitbar. Plausibel nach einem Server-Neustart sind Verbindungen, die vor vollständigem Aufbau des Overlay-Netzes/IPVS entstanden sind, oder ein Neustart der Datenbank ohne RST. Ebenso denkbar ist ein anderer Pool-Blocker (etwa eine offene Transaktion auf `auth_lock`, die alle Schreibanfragen in Reihe hält). Das ist **Vermutung**, kein Beleg.

## Hinweis aus UPDATE-FIX (Hypothesen 1 und 2)

- **Hypothese 1 (Migrationstask kehrt nach „No new migrations.“ wegen `asyncShutdown()` nicht zurück): widerlegt.** `App migrate --yes --env production` gegen MariaDB 12.3.3 (Linux, `poolPerLoop=1`, Keep-Alive an) beendet sich zweimal hintereinander (Migration und „No new migrations.“) in unter 1 s mit Exit 0.
- **Hypothese 2 (Rollout bleibt `updating`, weil `/ready` nicht grün wird):** Mit dem Fix wird `/ready` nur 503, wenn der Pool eines Loops nicht innerhalb von 1,0 s antwortet. Ein gesunder neuer Task wird dadurch nicht blockiert (Last-Test: `/ready` unter 120 parallelen Anfragen ohne 5xx). Ein Task mit festgefahrenem Pool bleibt bewusst rot, damit `start-first` ihn nicht in Rotation nimmt und Swarm zurückrollt bzw. ersetzt.
- Prüfstand: SQLite 521 Tests, 45 übersprungen, 0 Fehler. MariaDB: 521 Tests, 3 übersprungen, ein einziger Fehler in `testC19PushClaimsAndHeartbeatSQLite` (Zeitverhalten bei stark ausgelasteter Maschine; allein wiederholt 2 von 2 grün).
- Ein Absturz des ersten SQLite-Laufs (`No database configuration registered for DatabaseID(string: "mysql")`) kam aus meinem ersten Entwurf von `PoolHealth.loopDatabases` und ist behoben (Prüfung auf registrierte MariaDB-Konfiguration).

## Änderungen

- `Sources/TimetrackKit/PoolHealth.swift` (neu): `withDeadline`, `ping` (schließt eine nach 5 s nicht antwortende Verbindung, der Pool ersetzt sie), `allLoopsAnswer`.
- `/ready` (`Routes.swift`): Pool **jedes** Event-Loops mit Frist (1,0 s je Loop, 1,2 s je Versuch, ein Wiederholungsversuch nach 200 ms, insgesamt unter dem Healthcheck-Timeout von 3 s). SQLite unverändert.
- `DatabaseKeepAlive` (`Configure.swift`): je Loop eine eigene Aufgabe, Ping mit Frist und Schließen der toten Verbindung, Logzeile nennt den Loop-Index (`event loop N`), keine Zugangsdaten.
- Tests `Tests/TimetrackKitTests/PoolStressTests.swift`: `testPoolStressWithOneConnectionPerLoop` (MariaDB, `MARIADB_TEST_HOST`), `testReadinessReportsBlackholedPoolConnections` und `testKeepAliveReplacesBlackholedIdleConnections` (zusätzlich `POOL_PROXY=1`, `socat` auf `127.0.0.1:3307` zur Test-DB und `/work/freeze.sh`; ohne diese übersprungen, beide waren vor der Änderung rot).

## Betreiber: Sofortmaßnahme und Diagnose

1. Task neu starten: `docker service update --force <stack>_backend` (nicht die Datenbank).
2. Vor dem Neustart sichern: `SHOW FULL PROCESSLIST;` und `SELECT * FROM information_schema.INNODB_TRX;` auf der Datenbank. Gesucht: Verbindungen des Backend-Benutzers im Zustand `Sleep` mit sehr hoher `Time` (tote Verbindung des alten Tasks) oder eine Transaktion, die `auth_lock` hält (`trx_started` alt, `trx_state` `RUNNING`, andere Zeilen `LOCK WAIT`). Beides entscheidet zwischen „tote Verbindung“ und „Sperre“.
3. Backend-Log: `database keep-alive ping failed (event loop N)` zeigt, welche Loops betroffen sind; wenige Loops betroffen = tote Verbindung, alle gleichzeitig = Datenbank/Sperre.
4. `DB_KEEPALIVE_SECONDS` nicht auf 0 setzen. `TRUSTED_PROXY_CIDRS=10.0.0.0/8` ist nur ein Hinweis (SEC-B) und steht mit dem Pool in keinem Zusammenhang.
