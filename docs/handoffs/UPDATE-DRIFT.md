# UPDATE-DRIFT – Stack-Konfiguration beim Update prüfen

Stand 03.11.2026, Branch `update-drift`, Basis main a32a3c1. Ein Schreiber (Codex), isolierter temporärer Klon; kein Merge, kein Push. Das Hauptcheckout wurde nicht verändert. Worktree-Erstellung scheiterte am Schreibschutz der Git-Referenzen. Vor dem Entfernen des Klons wird der Commit als Git-Bundle zur Übernahme erhalten.

## Ergebnis und Entscheidung

`deploy/swarm/update.sh` 2.3.0 rendert vor dem Frühabbruch bei gleichem Image die Stack-Datei mit exportierter `.env` und sämtlichen Overlays (`docker stack config`). Vergleich gegen `docker service inspect`: Env-Namen und Werte (fehlend/zusätzlich/geändert, leer bleibt von ungesetzt unterscheidbar), Secret-Namen/Dateiziele/UID/GID/Modus, Replikazahl und Netzwerkidentitäten über die Manager-Netzwerkliste. Reihenfolge ist unerheblich. Externe Secrets des ganzen Stacks werden über Namen auf Existenz geprüft; keine Secret-Inhalte werden gelesen.

Sicherere Wahl: Drift blockiert das Update mit Exit 1 vor Änderungen an Env-Datei oder Diensten. `--yes` und `--force` umgehen das nicht. Erst `--apply-stack-drift` erlaubt Stack-Deploy. Begründung: Stack-Deploy übernimmt auch Änderungen an anderen Diensten, Ports, Mounts und Overlays; das wäre als stiller Nebeneffekt eines Image-Updates zu weitreichend. `--status` bleibt lesend und liefert Exit 1 bei Drift/fehlenden Secrets; `--dry-run` zeigt Befunde ohne Änderungen (Exit 0 für den Plan, Fehler bei unprüfbarer Konfiguration).

Expliziter Abgleich und Wiederherstellung des fehlenden Migrationsdienstes nutzen dieselbe Funktion: aktuelles Backend-Image einschließlich Digest und laufende Replikazahl, `--resolve-image never`, exportierte `.env` und dieselben Overlays. Ein letztes generiertes Overlay erhält Image/Replikas auch gegen feste Werte in Betreiber-Overlays. Danach Rollout abwarten und normalen Migrations-/Image-Ablauf fortsetzen. Der Abgleich läuft nach dem Backup-Hook und vor der Migration mit dem neuen Image; er kann das Backend mit der neuen Konfiguration neu starten, auch wenn später die Migration scheitert. `.env.bak` ist kein Konfigurations-Rollback. Bei Replika-Drift bleibt bewusst die laufende Anzahl erhalten; die deklarierte Konfiguration muss anschließend angepasst werden.

Fehlende externe Secrets blockieren vor Änderungen mit deutschem Hinweis auf `create-secrets.sh --add-only`, insbesondere den optionalen Platzhalter `tt_oidc_client_secret`. Individuelle Secret-Namen erfordern passende vorhandene Secrets. Rendering-/Deploy-Fehlerdetails bleiben verborgen, weil Docker dabei Werte ausgeben kann. Der Vergleich zeigt für alle Env-Variablen ausschließlich Namen, auch für nicht geheime Variablen. Gerenderte Daten liegen in einem privaten temporären Verzeichnis (Modus 700), Cleanup im bestehenden EXIT-Trap. Aufruf-/Deploy-/Rollout-Zeitgrenzen und Fehlermeldungsstil bleiben erhalten. Neue Voraussetzung auf dem Manager: Python 3 mit PyYAML (`python3-yaml`); fehlt sie, Abbruch vor Änderungen. Die Python-Logik ist im Skript eingebettet, sodass `--self-update` keine weitere Datei benötigt.

## Dateien und Prüfungen

Geändert: `deploy/swarm/update.sh`, `scripts/test-update.sh`, `docs/DEPLOYMENT.md`, `docs/UPDATE.md`, `docs/STATUS.md`, `docs/ARBEITSPLAN.md`, `CHANGELOG.md` und diese Übergabe. Zusätzlich kleinste Portabilitäts-/Stabilitätskorrektur in `deploy/swarm/migrate-dir.sh`: echter Tabulator statt GNU-sed-spezifischem `\t`; pipefail-Pipelines konsumieren Eingaben vollständig statt per `grep -q` gelegentlich SIGPIPE auszulösen. Auch der Testhelfer konsumiert seine Ausgabe vollständig. Diese Probleme traten beim geforderten bestehenden Regressionstest auf.

Abschließender Prüfstand (03.11.2026):

- `shellcheck -x -P SCRIPTDIR -S warning deploy/swarm/update.sh deploy/swarm/migrate-dir.sh scripts/test-update.sh`: Exit 0 (Warnstufe wie im Repository).
- `bash -n` für alle drei geänderten Shell-Dateien: Exit 0.
- `scripts/test-update.sh`: Exit 0, 66 Prüfungen bestanden (Drift/kein Drift, gleiches Image, `.env`-Export, wirksames Overlay, Secret-/Netzwerk-/Replika-Drift, fehlende Secrets vor Mutation, expliziter Abgleich mit Digest/Replikas, nachfolgend sauberer Status, Trockenlauf, Renderingfehler ohne Wertausgabe sowie bestehende Update-/Rollback-/Restore-Fälle).
- `scripts/check-all.sh --fast`: Exit 0, YAML-/Vertragsprüfung, Shell-Prüfung und Offline-Tests PASS; Swift, Daemon-abhängige Compose-/Stack-Prüfungen und Restore-Beweis SKIP. Lokales `docker stack config` separat innerhalb der 66 Prüfungen bestanden.
- `git diff --check`: Exit 0.

 Tests ausschließlich mit Stub-Swarm; reale Docker-CLI nur für lokales `stack config`. Für `check-all.sh` verhindert ein Wrapper jeden Daemon-Aufruf und erlaubt lediglich lokale Konfigurationsbefehle. Python 3.14 mit vorhandenem PyYAML verwendet; der Standard-Python hatte kein PyYAML. Ein Installationsversuch im temporären venv scheiterte an gesperrtem Netzwerk, kein Systempaket geändert.

## Grenzen / nächster Schritt

Kein echter Swarm, keine produktiven Secrets, keine Migrationen oder Dienste gestartet. Swift-Tests/Build und Restore-Beweis nicht Bestandteil dieser Shell-Änderung. Netzwerk-Aliasse/Treiberparameter, Configs, Mounts, Ports und andere Dienste werden nicht auf Drift verglichen; Stack-Deploy kann sie dennoch übernehmen. Secret-Inhalte sind unveränderlich und werden nicht verglichen. Nicht replizierte Backend-Konfigurationen werden abgewiesen. Keine Schema-/API-Änderung. Keine laufenden Jobs nach Übergabe.

Nächster Schritt: Commit auf main übernehmen, Python/PyYAML auf einem Test-Manager bereitstellen und den Abgleich einschließlich Rollback und eigener Overlays kontrolliert auf einem Test-Swarm prüfen. Integration und Produktionstest offen.
