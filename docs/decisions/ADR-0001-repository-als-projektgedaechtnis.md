# ADR-0001: Repository als Projektgedächtnis

Status: akzeptiert durch ausdrückliche Nutzervorgabe am 13.10.2026.

## Kontext

Timetrack wird durch Claude-Agents und Codex über das Claude-Codex-Plugin entwickelt.
Sitzungen müssen austauschbar sein; dauerhafte Kenntnis darf nicht in einzelnen Chats liegen.
Das entsprechende Muster im Projekt Turaco wurde als Vorbild genannt und gelesen.

## Entscheidung

Anforderungen, Architekturentscheidungen, tatsächlicher Implementierungsstand, Testergebnisse,
Arbeitspakete und nächste Schritte werden fortlaufend im Repository gepflegt.
`AGENTS.md` und `CLAUDE.md` führen alle Agents zu denselben maßgeblichen Dokumenten.
`docs/ENTWICKLUNGSABLAUF.md` definiert Start, Checkpoints, Übergaben und Definition of Done.
`docs/STATUS.md` trennt Implementierung von Planung, `docs/ARBEITSPLAN.md` führt die aktive Arbeit.

## Alternativen

Chatverlauf oder persönliches Agent-Memory als Hauptquelle wären nicht reproduzierbar und
nicht gleichermaßen für alle Agents verfügbar. Vollständige Transkriptarchive wären zu groß,
redundant und könnten vertrauliche Daten enthalten. Beides ersetzt die Repo-Dokumentation nicht.

## Folgen

Dokumentation gehört zum selben Arbeitsschritt wie die Implementierung. Zusätzliche Pflege wird
bewusst akzeptiert. Frische Sessions benötigen keine alte Session-ID. Plugin-IDs dürfen als
temporäre Hinweise erscheinen, sind aber keine Wissensquelle. Kein externer Memory-Dienst nötig.
Turacos Stack, Modellrouting und dort vorhandene Skills werden nicht automatisch übernommen.
