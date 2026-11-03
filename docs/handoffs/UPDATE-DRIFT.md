# UPDATE-DRIFT – Stack-Konfiguration beim Update prüfen

Stand 03.11.2026, Branch `update-drift`, Basis main a32a3c1; jq-Folgeänderung auf 6b526e6. Ein Schreiber (Codex), isolierter temporärer Klon; kein Merge, kein Push. Das Hauptcheckout wurde nicht verändert. Worktree-Erstellung scheiterte am Schreibschutz der Git-Referenzen. Vor dem Entfernen des Klons wird der Commit als Git-Bundle zur Übernahme erhalten.

## Ergebnis und Entscheidung

`deploy/swarm/update.sh` 2.3.0 rendert vor dem Frühabbruch bei gleichem Image die Stack-Datei mit exportierter `.env` und sämtlichen Overlays (`docker stack config`). Vergleich gegen `docker service inspect`: Env-Namen und Werte (fehlend/zusätzlich/geändert, leer bleibt von ungesetzt unterscheidbar), Secret-Namen/Dateiziele/UID/GID/Modus, Replikazahl und Netzwerkidentitäten über die Manager-Netzwerkliste. Reihenfolge ist unerheblich. Externe Secrets des ganzen Stacks werden über Namen auf Existenz geprüft; keine Secret-Inhalte werden gelesen.

Sicherere Wahl: Drift blockiert das Update mit Exit 1 vor Änderungen an Env-Datei oder Diensten. `--yes` und `--force` umgehen das nicht. Erst `--apply-stack-drift` erlaubt Stack-Deploy. Begründung: Stack-Deploy übernimmt auch Änderungen an anderen Diensten, Ports, Mounts und Overlays; das wäre als stiller Nebeneffekt eines Image-Updates zu weitreichend. `--status` bleibt lesend und liefert Exit 1 bei Drift/fehlenden Secrets; `--dry-run` zeigt Befunde ohne Änderungen (Exit 0 für den Plan, Fehler bei unprüfbarer Konfiguration).

Expliziter Abgleich und Wiederherstellung des fehlenden Migrationsdienstes nutzen dieselbe Funktion: aktuelles Backend-Image einschließlich Digest und laufende Replikazahl, `--resolve-image never`, exportierte `.env` und dieselben Overlays. Ein letztes generiertes Overlay erhält Image/Replikas auch gegen feste Werte in Betreiber-Overlays. Danach Rollout abwarten und normalen Migrations-/Image-Ablauf fortsetzen. Der Abgleich läuft nach dem Backup-Hook und vor der Migration mit dem neuen Image; er kann das Backend mit der neuen Konfiguration neu starten, auch wenn später die Migration scheitert. `.env.bak` ist kein Konfigurations-Rollback. Bei Replika-Drift bleibt bewusst die laufende Anzahl erhalten; die deklarierte Konfiguration muss anschließend angepasst werden.

Fehlende externe Secrets blockieren vor Änderungen mit deutschem Hinweis auf `create-secrets.sh --add-only`, insbesondere den optionalen Platzhalter `tt_oidc_client_secret`. Individuelle Secret-Namen erfordern passende vorhandene Secrets. Rendering-/Deploy-Fehlerdetails bleiben verborgen, weil Docker dabei Werte ausgeben kann. Der Vergleich zeigt für alle Env-Variablen ausschließlich Namen, auch für nicht geheime Variablen. Gerenderte Daten liegen in einem privaten temporären Verzeichnis (Modus 700), Cleanup im bestehenden EXIT-Trap. Aufruf-/Deploy-/Rollout-Zeitgrenzen und Fehlermeldungsstil bleiben erhalten. Voraussetzung auf dem Manager: `jq`; fehlt es, deutscher Abbruch vor Änderungen. Die abgelehnte Python-/PyYAML-Abhängigkeit wurde entfernt. Bash und awk lesen ausschließlich die benötigten Abschnitte der normalisierten YAML-Ausgabe von `docker stack config`; jq dekodiert Skalare, vergleicht gegen `docker service inspect --format '{{json .Spec}}'` und erzeugt das erhaltende Overlay. Die Logik bleibt in update.sh eingebettet, sodass `--self-update` keine weitere Datei benötigt. Verhalten, Felder und Exit-Codes bleiben erhalten.

## Dateien und Prüfungen

Die jq-Folgeänderung betrifft ausschließlich `deploy/swarm/update.sh`, `scripts/test-update.sh`, `docs/DEPLOYMENT.md`, `docs/UPDATE.md`, `docs/STATUS.md`, `docs/ARBEITSPLAN.md`, `CHANGELOG.md` und diese Übergabe. `migrate-dir.sh` bleibt gegenüber 6b526e6 unverändert. Kein neuer Schalter, keine API-/Schemaänderung und keine weitere Abhängigkeit.

Abschließender Prüfstand (03.11.2026):

- `bash -n` einzeln für `deploy/swarm/update.sh` und `scripts/test-update.sh`: jeweils Exit 0.
- `shellcheck -x -P SCRIPTDIR -S warning deploy/swarm/update.sh scripts/test-update.sh`: Exit 0, beide Dateien.
- `scripts/test-update.sh`: Exit 0, alle 70 Prüfungen bestanden. Bestehende 66 Prüfungen erhalten; ergänzt: fehlendes jq vor Mutation und drei Prüfungen mit echter normalisierter Docker-YAML-Ausgabe (Quotes, Backslash, Steuerzeichen, mehrzeilige Werte mit/ohne abschließendem Zeilenumbruch, leer/ungesetzt, Secret-Ziel/UID/GID/Modus und interne/externe Netzwerke).
- Derselbe vollständige Testlauf mit einem ausschließlich aus benötigten Werkzeug-Symlinks aufgebauten PATH: `command -v python3` findet nichts; alle 70 Prüfungen bestanden, einschließlich echter lokaler `docker stack config`-Ausgabe. Weder update.sh noch der Teststub importieren YAML oder rufen Python auf.
- `scripts/check-all.sh --fast`: Exit 0, 3 PASS (Vertrag/YAML, sämtliche Shell-Dateien, Update-Tests), 6 SKIP (Swift-Build, SQLite-/MariaDB-Tests, daemonabhängige Compose-/Stack-Prüfungen, Restore-Beweis). Die bestehende allgemeine Vertrags-/YAML-Prüfung verwendet weiterhin vorhandenes Python 3.14/PyYAML; das gehört nicht zur Laufzeitabhängigkeit von update.sh und wurde nicht geändert.
- `git diff --check`: Exit 0.

Tests ausschließlich mit Stub-Swarm; reale Docker-CLI nur für lokales `stack config`. Für `check-all.sh` blockiert ein temporärer Docker-Wrapper sämtliche anderen Docker-Aufrufe, insbesondere Daemon-Zugriffe. Alle temporären Dateien liegen im isolierten Arbeitsverzeichnis; nach Erstellung und Prüfung des Git-Bundles wird der Klon entfernt. Kein Push, kein Merge, keine Änderung am Hauptcheckout.

## Grenzen / nächster Schritt

Kein echter Swarm, keine produktiven Secrets, keine Migrationen oder Dienste gestartet. Swift-Tests/Build und Restore-Beweis nicht Bestandteil dieser Shell-Änderung. Netzwerk-Aliasse/Treiberparameter, Configs, Mounts, Ports und andere Dienste werden nicht auf Drift verglichen; Stack-Deploy kann sie dennoch übernehmen. Secret-Inhalte sind unveränderlich und werden nicht verglichen. Nicht replizierte Backend-Konfigurationen werden abgewiesen. Keine Schema-/API-Änderung. Keine laufenden Jobs nach Übergabe.

Nächster Schritt: Commit auf main übernehmen, `jq` auf einem Test-Manager bereitstellen und den Abgleich einschließlich Rollback und eigener Overlays kontrolliert auf einem Test-Swarm prüfen. Integration und Produktionstest offen.
