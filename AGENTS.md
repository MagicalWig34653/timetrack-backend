# Timetrack – Einstieg für alle Coding-Agents

Das Repository ist das Projektgedächtnis. Sessions sind wegwerfbar.
Chatverlauf, Plugin-Threads und persönliche Agent-Memory dürfen keine Voraussetzung zur Fortsetzung sein.

Vor jeder nichttrivialen Aufgabe:

1. `docs/STATUS.md` lesen: Was ist tatsächlich vorhanden und geprüft?
2. `docs/ARBEITSPLAN.md` lesen: Wer bearbeitet was, welcher Schritt folgt?
3. `docs/ENTWICKLUNGSABLAUF.md` und relevante Entscheidungen unter `docs/decisions/` lesen.
4. Relevante Teile von `docs/KONZEPT.md`, `docs/ARCHITEKTUR.md` und `docs/UMSETZUNG.md` lesen.
5. Code, Tests, Git-Status und tatsächliche Dateien prüfen; Planung ist keine Implementierung.

Claude-spezifischer Einstieg: `CLAUDE.md`. Lokaler Start: `EINRICHTUNG.md`.
Fragen gesammelt im normalen Chat; keine interaktiven Frageformulare.

## Sprache

Code einschließlich Kommentaren, Tests und technischen Bezeichnern auf Englisch;
nutzerseitige Texte auf Deutsch. Verbindliche Details: `docs/ENTWICKLUNGSABLAUF.md`,
Abschnitt „Sprache von Code und Oberfläche“. Gilt auch für alle delegierten Agent-Aufträge.

## Arbeitsregeln

- Claude koordiniert; ungefähr 50 % Umsetzung durch Codex über das Claude-Codex-Plugin.
- Jeder Auftrag enthält Grenzen, Dateien/Worktree, API-Vertrag und Abnahmekriterien.
- Keine parallelen Schreiber auf denselben Dateien. Gemeinsame Verträge/Migrationen koordinieren.
- Agent-Ergebnisse im Repository festhalten und integrieren, nicht nur im Plugin-Thread belassen.
- Fachliche Regeln und Autorisierung zwischen REST, MCP und Apps gemeinsam verwenden.
- Kontentrennung, Datenintegrität, Idempotenz und nachvollziehbare Roh-/Bewertungszeiten erhalten.
- Bestehende Entscheidungen nicht still ändern; wesentliche Änderungen als ADR dokumentieren.
- Keine Secrets, Tokens, privaten Beispieldaten oder vollständigen Chats ins Repository schreiben.
- Tests passend zur Änderung; nicht ausgeführte Prüfungen als offen markieren.
- Dokumentation und Status im selben Arbeitsschritt aktualisieren.

Vor Übergabe/Sessionende oder Kontextwechsel: Ergebnisse, Dateien/Branch, Teststand,
offene Fehler, laufende Jobs, Migrationsfolgen und nächsten konkreten Schritt im Repository sichern.
Details: `docs/ENTWICKLUNGSABLAUF.md`. Dokumentationslandkarte: `docs/README.md`. Keine Buildbefehle behaupten, die nicht in `EINRICHTUNG.md` stehen oder ausgeführt wurden.
