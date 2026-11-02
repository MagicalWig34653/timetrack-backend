# UPDATE-FIX: update.sh ohne Endlos-Warten (02.11.2026)

## Symptom
`deploy/swarm/update.sh` hängt; `timetrack_migrate` startet im Log immer wieder neu (Meldungen „Prepare“, „database connection OK“, „No new migrations.“) im Abstand von 10 bis 30 Minuten.

## Befund (belegt durch Code)
- `migrate` ist `mode: replicated-job`, `restart_policy: condition: none` (stack.yaml). Swarm startet einen fertigen Job nicht selbst neu.
- Jeder `update.sh`-Lauf startet den Job mit `docker service update --force` neu. Mehrere Neustarts im Log bedeuten daher mehrere Skriptläufe (oder manuelle `service update --force`), keine Endlosschleife von Swarm. Das Skript hatte keine Sperre gegen Parallel- oder Wiederholungsläufe.
- `git diff 428fd67..HEAD -- deploy scripts Dockerfile`: nur Kommentare in stack.yaml (SEC-B) und Compose-Ports; Healthcheck, Job-Definition, Entrypoint unverändert. SEC-B/CX/PLAN-OFFDAY haben den Ablauf nicht geändert.
- Die Warteschleifen waren begrenzt (300 s/600 s), aber: die Zeit zählte nur die `sleep`-Schritte (langsame Docker-Aufrufe zählten nicht mit), `curl` (Registry, `/ready`, `/health`) und `docker`-Aufrufe hatten keine Zeitgrenze, die Rückfrage ohne `--yes` wartet auf Eingabe.

## Hypothesen (nicht belegt)
1. Der Migrations-Task bleibt nach „No new migrations.“ im Zustand `Running`, weil `app.asyncShutdown()` (entrypoint.swift) mit dem MariaDB-Pool nicht zurückkehrt; passt zu den gleichzeitigen Pool-Zeitüberschreitungen (Branch `pool-fix`). Das Skript meldet dann nach 300 s Zeitüberschreitung; der Betreiber startet erneut.
2. Rollout bleibt `updating`, weil `/ready` des neuen Backends wegen Pool-Zeitüberschreitungen nicht grün wird (Healthcheck 15 s x 5, start-first, Monitor 60 s).
3. Ein hängender `curl`/`docker`-Aufruf ohne Zeitgrenze (Registry, Proxy).
Welche zutrifft, zeigen die Befehle in docs/DEPLOYMENT.md („Fehlersuche beim Update“). Dort steht auch, wie man ein hängendes Update abbricht oder fortsetzt.

## Änderung
- Zeitgrenzen je `docker`-Aufruf (`timeout`, falls vorhanden), `curl --connect-timeout/--max-time`, Wanduhr-Zeit für Migration und Rollout, überschreibbar mit `MIGRATE_TIMEOUT`/`ROLLOUT_TIMEOUT`.
- Bei Fehler/Zeitüberschreitung/Strg+C: `docker service ps --no-trunc`, letzte Logzeilen, Hinweise (Status, Logs, `docker service rollback`, alter Stand in `.env.bak`).
- Warnung, wenn der Migrationstask >60 s `Running` ist, obwohl das Log sein Ende zeigt.
- Sperrverzeichnis gegen parallele Läufe.
- Test: Stubs für `docker`/`curl` (Erfolg; Migration bleibt `Running` mit Zeitüberschreitung), `bash -n`, shellcheck ohne neue Warnungen. Kein echter Swarm, keine Serveraktionen.
