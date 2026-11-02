# Handoff UPDATE-V2: update.sh brach still ab, Umbau (02.11.2026)

Branch `update-v2`. Keine Vertragsänderung, keine Migration. Nichts auf dem Server ausgeführt, keine Registry-Aufrufe (nur Stubs).

## Meldung
Nach dem Löschen von `timetrack_migrate` endete `bash update.sh --force` nach „Schritt 3/6 … Wrote TIMETRACK_IMAGE to ./.env“ ohne Fehlermeldung.

## Ursache (reproduziert mit `docker`-Stub)
Das Skript läuft mit `set -euo pipefail`. In Schritt 4 steht

```sh
before=" $(dk service ps "$MIGRATE_SERVICE" -q --no-trunc 2>/dev/null | tr '\n' ' ')"
```

Existiert der Dienst nicht, liefert `docker service ps` Exit 1 („No such service“). Mit `pipefail` ist der Status der Pipeline 1; der Status einer Zuweisung ist der der letzten Befehlsersetzung, also beendet `set -e` das Skript. Der Fehlertext ging nach `/dev/null`, der einzige Trap (`EXIT`) räumte nur die Sperre auf. Der Stub-Lauf der alten Fassung zeigte exakt die Ausgabe des Betreibers (Exit 1, letzte Zeile „Wrote TIMETRACK_IMAGE …“, `bash -x` endet bei `before=' '` und `rm -rf …lock`). Der `timeout`-Wrapper des Hotfixes 30edd9d war es nicht; er hat den Fehler nur nicht verhindert, weil `|| true` fehlte. Der Fehler trat vorher nie auf, weil der Dienst immer existierte.

Zusatzbefund: Ein zweiter Lauf mit `--force` überschrieb `.env.bak` mit der schon geänderten `.env`; der alte Stand ging verloren.

## Änderung (`deploy/swarm/update.sh`, Version 2.0.0, komplett neu geschrieben, eigenständig)
- **Fix:** `task_ids`/`svc_field` schlucken erwartbare Fehler; `service_exists` unterscheidet „No such service“ (Wert 1) von jedem anderen Dockerfehler (laut abbrechen).
- **Fehlender Migrationsdienst:** wird vor dem Schreiben der `.env` erkannt, in Schritt 4 per `docker stack deploy -c stack.yaml` aus der `.env` wiederhergestellt, mit Image und Replikazahl des laufenden Backends (Backend bleibt unverändert). Fehlt `stack.yaml` neben dem Skript: klare Meldung, `.env` unberührt (`--stack-file` möglich).
- **Nie still:** `set -E`, `ERR`-Trap merkt Befehl/Zeile/Code, `EXIT`-Trap meldet auf Deutsch Schritt, Phase, Befehl, Zeile, Exit-Code und Hinweise; alle `die`-Meldungen deutsch; INT/TERM melden ebenfalls.
- **Idempotent bei `--force`:** `.env.bak` wird nur bei Image-Wechsel (oder ohne vorhandene Sicherung) geschrieben; veraltete Sperre (Prozess tot) wird entfernt.
- **Neu:** `--status` (Exit 1 bei Problemen), `--rollback` (Image aus `.env.bak` oder `--tag`; Schema bleibt), `--dry-run` (lesende Docker-Aufrufe, meldet fehlenden Migrationsdienst), `--self-update` (+ `--script-url`, `--script-ref` als Commit-Pin, `--no-self-check`), `--version`, `UPDATE_BACKUP_CMD` vor der Migration, `update-history.log`, Farben nur am Terminal, Manager-Prüfung (`docker info`).
- **Selbstupdate:** Quelle `raw.githubusercontent.com/<owner>/timetrack-backend/<ref>/deploy/swarm/update.sh`, `<owner>` aus dem Image-Namen in der `.env` (kein Name im Skript). Download in Temporärdatei, Prüfung (Shebang, `SCRIPT_VERSION`, Endmarke `# END update.sh`, `bash -n`), Anzeige von Version, sha256 und `diff`, Rückfrage (nie stilles Überschreiben), Sicherung `update.sh.prev`, danach Neustart des Skripts durch den Betreiber. Beim normalen Start nur ein Hinweis, wenn der Branch eine andere Fassung hat.
- **deploy-Branch:** `deploy-branch.yml` löst bei Änderungen unter `deploy/swarm/**` aus, `sync-deploy-branch.sh` kopiert `update.sh` und `stack.yaml`; das neue Skript liegt also nach dem Merge ohne weitere Änderung auf `deploy` (nach dem Workflowlauf). README des Branches nennt `--self-update`. `docs/DEPLOYMENT.md` Abschnitt 2 beschreibt „Skript vom deploy-Branch holen“ (Klon + `git pull --ff-only` oder `--self-update`), Abschnitt 13 die neuen Modi und den Fall „migrate fehlt“ (auch als manuelle Befehle).

## Vergleich mit Todolino (nur gelesen, kein Code übernommen)
Das dortige `update.sh` (137 Zeilen) ist im Kern unser altes Skript; weiter ist das Umfeld: `setup.sh` (Einrichtungsassistent), `lib.sh`, `scripts/swarm-deploy.sh` mit Swarm-Config als clusterweitem Deployment-Lock und Wiederherstellung eines fehlenden `migrate`-Dienstes per `stack deploy` mit der aktuellen Replikazahl, Backup/Restore-Skripte, Overlay-Stacks, ein Branch-README mit `git pull --ff-only` als Updateweg. Dort gibt es kein Selbstupdate, kein `--rollback`/`--status`, keinen ERR/EXIT-Trap.
- **Übernommen (Idee, eigene Umsetzung):** `deploy`-Branch als Updateweg mit `git pull --ff-only` (war bei uns vorhanden, jetzt dokumentiert), Wiederherstellung des fehlenden Migrationsdienstes per `stack deploy` mit unveränderter Replikazahl.
- **Nicht übernommen:** Swarm-Config-Lock (unsere Datei-Sperre genügt auf einem Manager, ergänzt um Erkennung veralteter Sperren), `setup.sh`-Assistent (Produktions-Setup ist hier `create-secrets.sh` plus Anleitung), Overlay-Stacks, Zeitlimit 120x2 s ohne Wanduhr.
- Lizenz/Datenschutz: kein Fremdcode, keine Namen, Domains, Pfade oder Secrets übernommen.

## Prüfung
`bash -n`, `shellcheck -S warning` (sauber), `scripts/test-update.sh` (36 Prüfungen mit zustandsbehaftetem `docker`-Stub: fehlender Dienst, Dienst vorhanden, Job hängt, Job schlägt fehl, fehlende Stack-Datei, Stack-Deploy-Fehler, unerwarteter Fehler, Docker nicht erreichbar, Dry-Run, Backup-Befehl, Status, Rollback, Sperre, Selbstupdate inkl. abgeschnittenem Download), alles in `scripts/check-all.sh` eingehängt (shellcheck umfasst jetzt `deploy/swarm/*.sh`). `scripts/check-all.sh --fast`: PASS.

## Offen / Grenzen
- Kein echter Swarm getestet; `docker stack deploy` aus der `.env` setzt voraus, dass die `.env` alle Pflichtvariablen enthält und per `source` lesbar ist. Weitere Änderungen an `.env`/`stack.yaml` rollen dabei auch das Backend.
- `timeout` fehlt auf macOS; dort laufen Docker-Aufrufe ohne Zeitgrenze (Produktion: Linux).
- Hängendes Beenden des Migrationsjobs (POOL-FIX-Thema) bleibt eine Meldung mit Zeitüberschreitung, kein automatischer Eingriff.
