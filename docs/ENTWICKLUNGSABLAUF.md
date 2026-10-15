# Dauerhaftes Projektwissen und wegwerfbare Sessions

Bestätigte Vorgabe: Der Wissensstand liegt im Repository. Eine neue Claude- oder Codex-Sitzung
muss ohne alte Unterhaltung weiterarbeiten können. Vorbild sind Turacos Context Management,
Agent-Einstiege und Definition of Done; dessen Stack, Modellnamen und Skills werden nicht übernommen.

## Kanonische Quellen

| Inhalt | Maßgebliche Datei |
| --- | --- |
| Produktanforderungen und fachliche Regeln | `KONZEPT.md` |
| Technische Struktur und Schnittstellen | `ARCHITEKTUR.md` |
| Begründete Architektur-/Prozessentscheidungen | `decisions/` |
| Tatsächlich implementiert, geprüft und noch fehlend | `STATUS.md` |
| Aktive Pakete, Verantwortliche, nächste Schritte | `ARBEITSPLAN.md` |
| Gesamte Implementierungsreihenfolge und Abnahme | `UMSETZUNG.md` |
| Lokale Einrichtung, Start-/Testbefehle, Konfiguration | `../EINRICHTUNG.md` |
| Agent-Einstiege | `../AGENTS.md`, `../CLAUDE.md` |
| Dokumentationslandkarte, ADR-Index | `README.md` |
| Testdienste, Ports, Testdomain | `TESTUMGEBUNGEN.md` |
| MCP-Anbindung und Tools | `MCP.md` |
| Abhängigkeitslizenzen | `LIZENZEN.md` |

Details nur in ihrer maßgeblichen Datei pflegen und von anderen Dateien darauf verweisen.
Status ist eine Momentaufnahme, keine zweite Anforderungssammlung. Alte Details nicht nur anhängen:
überholte Aussagen ersetzen oder als überholt markieren. Bei Widersprüchen Code/Tests mit der
beschlossenen Spezifikation vergleichen; eine Abweichung ist kein stiller Beschluss.
Neue explizite Nutzerentscheidungen vor Umsetzung in der passenden Datei festhalten.

## Sprache von Code und Oberfläche

Verbindliche Nutzervorgabe vom 14.10.2026, gilt für alle drei Repositories:

- Sämtlicher selbst geschriebener Code auf Englisch: Variablen, Funktionen, Typen, Module,
  technische Dateinamen, Kommentare, Docstrings, Tests und Testbeschreibungen.
- Datenbankschema, Migrationen, API-Pfade/-Felder, Fehlercodes, MCP-Toolnamen,
  Konfigurationsschlüssel und interne Log-/Diagnosemeldungen ebenfalls auf Englisch.
- Alles für Endnutzer Sichtbare auf Deutsch: Oberfläche, Hilfetexte, Validierungs- und
  Fehlermeldungen, Benachrichtigungen, E-Mails sowie Beschriftungen in Exporten/Berichten.
  Technische Fehlercodes bleiben Englisch; die Oberfläche zeigt verständliche deutsche Texte.
- Nutzertexte von der Programmlogik trennen und über die jeweiligen Lokalisierungsressourcen
  verwalten. Lokalisierungsschlüssel auf Englisch. Benutzereingaben nicht automatisch übersetzen.
- Die deutschsprachigen Konzept-, Einrichtungs- und Agent-Dokumente sowie die Kommunikation
  mit dem Nutzer bleiben auf Deutsch; die Codevorgabe erfordert keine Übersetzung dieser Dokumente.

## Parallelarbeit: eigener Worktree je Schreiber

Jeder gleichzeitig schreibende Agent bekommt einen **eigenen Git-Worktree** (Backend: `../timetrack-backend-wt/<paket>`, PWA: `../timetrack-pwa-wt/<paket>`), auch im PWA-Repo.
Zwei Agents im selben Verzeichnis überschreiben sich beim `git checkout` gegenseitig (Vorfall 15.10.2026, L14/L15). Ausnahme: Codex darf (Sandbox) nur im Hauptordner des Backends schreiben,
dort arbeitet höchstens ein Schreiber auf eigenem Branch. Nach dem Merge Worktrees mit `git worktree remove --force` entfernen (Reste in `.build`/`node_modules` ggf. mit `rm -rf`).
Vor jeder Übernahme führt der Lead Build und Tests selbst aus (inkl. Linux-Compile des Backends mit `docker build --target build .` bei größeren Änderungen).

## Beginn jeder Sitzung

1. Agent-Einstieg, Status, Arbeitsplan, relevante ADRs und Fach-/Technikdokumente lesen.
2. Vorhandene Änderungen, Branches/Worktrees und Tests prüfen, ohne fremde Arbeit zu verwerfen.
3. Alte Einträge „in Arbeit“ verifizieren: existiert der Agent/Job noch, sind Änderungen integriert?
   Session-IDs sind Hinweise, keine Belege für laufende Arbeit. Keine doppelte Ausführung starten.
4. Einen konkreten Auftrag übernehmen, Dateibesitz und Abnahme im Arbeitsplan aktualisieren.
5. Kurz den nächsten Schritt benennen und arbeiten; nicht das gesamte Konzept neu aufrollen.

## Während der Arbeit

- Nach jeder integrierten Teilaufgabe und jeder wesentlichen Entscheidung Dokumentation aktualisieren.
- Implementierer liefern geänderte Dateien, Ergebnis, Testbefehle/-ausgänge und Restprobleme.
- Lead integriert Änderungen und die kompakten Ergebnisse in Status/Arbeitsplan.
- Prüfer lesen Anforderungen und tatsächlichen Diff unabhängig; Befunde mit Datei/Problem/Status sichern.
- Ein Schreibverantwortlicher je Bereich; Lead pflegt gemeinsame Statusdateien, Worker liefern
  Übergaben in ihrem Arbeitspaket. Auch Dokumentationsdateien nicht gleichzeitig überschreiben.
- Etwa 50 % Codex-Implementierung anhand vorab gewichteter Pakete verfolgen. Review separat zählen.
- Fehlgeschlagene Versuche nur dokumentieren, wenn Ursache/Ergebnis erneute Fehlversuche vermeiden hilft.

## Vor Sessionende, Kontextreset oder Agent-Wechsel

Ein kompakter Checkpoint in `STATUS.md` und `ARBEITSPLAN.md` enthält:

- aktuelles Ziel und akzeptierte Entscheidungen, mit Links statt doppelter Volltexte;
- implementierter Stand, betroffene Dateien, Branch/Worktree und ggf. Commit;
- noch unintegrierte Änderungen und ihren Ort;
- Prüfungen: Datum, Befehl, Ergebnis, zugehöriger Codezustand und Einschränkungen;
- ungelöste Fehler mit Reproduktionshinweis und nächstem Lösungsansatz;
- Migrationen/Datenfolgen und offene Rechte-/Sicherheitsbefunde;
- laufende Dienste/Jobs und wie ihr Zustand geprüft oder ihre Arbeit übernommen wird;
- nächster konkreter Schritt, ohne Abhängigkeit von einem alten Chat oder Thread.

Wichtige Änderungen in nachvollziehbaren Commits sichern, sobald Git initialisiert ist.
Ein Arbeitsbaum allein ist kein Backup. Unfertige Arbeit gegebenenfalls als klaren WIP-Commit
auf dem Arbeitsbranch sichern; nicht als fertiges Feature ausgeben. Keine Pushes automatisch ableiten.
Keine ungesicherten Änderungen für einen vermeintlich sauberen Übergabestand löschen.

Nicht bis zum Sessionende warten: regelmäßige kleine Checkpoints begrenzen Verluste bei Abbruch.
Ein unerwarteter Abbruch kann trotzdem den letzten ungesicherten Gedanken verlieren; deshalb
dürfen Implementierungsentscheidungen nicht länger ausschließlich im Gespräch verbleiben.

## Architekturentscheidungen (ADR)

Neue wesentliche Frameworks, Datenhaltung, Authentifizierungsmodelle, Modulgrenzen oder Änderungen
an festgelegten Regeln brauchen einen kurzen ADR: Kontext, Status, Entscheidung, Alternativen,
Folgen und betroffene Dokumente. Status: vorgeschlagen, akzeptiert oder ersetzt.
Routineentscheidungen selbst treffen und begründen; echte Nutzerpräferenzen nicht überschreiben.
Ersetzte ADRs bleiben als Historie erhalten und verweisen auf ihren Nachfolger.

## Definition of Done

- Verhalten erfüllt die Abnahmekriterien; keine offenen relevanten Reviewbefunde verschweigen.
- Tests/Builds auf passender Ebene ausgeführt; nicht geprüfte Plattformen ausdrücklich nennen.
- Autorisierung, Migrationen und Wiederholbarkeit bei betroffenen Änderungen geprüft.
- Maßgebliche Fach-/Technikdokumente, Status und Arbeitsplan aktualisiert.
- Keine Secrets, privaten Daten oder maschinenspezifischen Zugangsdaten im Diff.
- Ein frischer Agent kann den Stand und nächsten Schritt allein aus dem Repository rekonstruieren.

## Prüfbefehle

Es gibt bewusst noch kein pauschales `make check` und kein `scripts/check-all.sh` (Backlog in `ARBEITSPLAN.md`).
Der Lead führt vor jeder Übernahme selbst aus (Befehle und Voraussetzungen in `../EINRICHTUNG.md`):

- Backend: `swift test --build-system native` (mit MariaDB-Variablen aus `scripts/dev-env.sh test-db` und eigener
  `MARIADB_TEST_DB`, sonst werden MariaDB-Varianten übersprungen); bei größeren Änderungen `docker build --target build .`
  bzw. `docker compose --profile app build backend` für den Linux-Compile.
- PWA: `npm run check`, `npm test`, `npm run test:e2e:mock`, `npm run test:e2e` (echte Wegwerf-Backends), bei PWA-Änderungen `npm run test:e2e:pwa`.
- Dokumentation: relative Links und genannte Dateipfade prüfen; Stand-Daten nur ändern, wenn der Inhalt verifiziert wurde.

Worker testen gezielt ihren Bereich, der Lead führt nach der Integration die Gesamtprüfung aus und trägt Zahlen in `STATUS.md` ein.
Nicht ausgeführte Prüfungen bleiben als offen markiert.
