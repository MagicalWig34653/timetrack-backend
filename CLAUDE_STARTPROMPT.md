# Startprompt für Claude Code

Den folgenden Block vollständig in einer Claude-Code-Sitzung in diesem Projektordner einfügen.
Die übrigen Markdown-Dateien bleiben dabei im Ordner und sind Teil des Auftrags.

```text
Übernimm die technische Leitung und Implementierung von Timetrack aus dem Backend-Hauptrepo.
Die drei Repos sind eingerichtet; prüfe den tatsächlichen Stand gemäß docs/STATUS.md und docs/REPOSITORIES.md.
Ich möchte selbst möglichst keinen Code schreiben. Arbeite mit Agents und delegiere ungefähr
50 % der tatsächlichen Implementierungsarbeit über das installierte Claude-Codex-Plugin an Codex.
Codex soll eigene Features und Tests implementieren, nicht nur deine Arbeit reviewen.

Lies zuerst:
- AGENTS.md
- CLAUDE.md
- docs/STATUS.md
- docs/ARBEITSPLAN.md
- docs/ENTWICKLUNGSABLAUF.md
- docs/REPOSITORIES.md
- relevante ADRs unter docs/decisions/
- EINRICHTUNG.md
- docs/KONZEPT.md
- docs/ARCHITEKTUR.md
- docs/UMSETZUNG.md

Diese Dateien enthalten unsere bereits besprochenen Entscheidungen. Stelle bestätigte Richtungen
nicht erneut zur Diskussion. Kennzeichne ergänzende Annahmen; frage nur bei echten fachlichen
Blockern gesammelt im normalen Chat. Keine interaktiven Frageformulare.

Arbeitsweise:
1. Prüfe den Ist-Stand, vorhandene Änderungen und lokale Werkzeuge. Docker läuft auf diesem Mac
   über Colima; ARM64 ist die lokale Architektur. Die Anwendung muss später auch auf Linux amd64
   laufen. Prüfe lokalen Docker-Kontext/Daemon, Compose, Buildx und Toolchain-Versionen.
   Unterscheide fehlende Werkzeuge, fehlende Berechtigungen und gestoppte Dienste.
2. Prüfe /codex:setup und die Anleitung der tatsächlich installierten Plugin-Version.
   Zuletzt wurde codex@openai-codex 1.0.6 gefunden. Für Implementierungsaufträge ist der Agent
   codex:codex-rescue vorgesehen, mit Schreibzugriff. Verwende für unabhängige Pakete --fresh,
   für echte Fortsetzungen --resume. Es handelt sich um einen Agent, nicht um einen Skill.
   Nutze den unterstützten Plugin-Weg und halte Modell-/Effort-Einstellungen unverändert.
   Falls Login oder Plugin blockiert, benenne die konkrete nötige Nutzeraktion, erledige daneben
   unabhängige Arbeit und behaupte keinen Codex-Anteil, der nicht stattgefunden hat.
3. Aktualisiere docs/ARBEITSPLAN.md mit gewichtetem Umfang, Verantwortlichen und Abnahmekriterien.
   Plane etwa 50 % Codex und 50 % Claude-Implementierung, Richtwert 40–60 % pro Meilenstein.
   Belege den Anteil durch abgeschlossene Arbeitspakete, nicht Zeilen oder Tokens.
4. Initialisiere bei Bedarf Git, schütze bestehende Dateien und erstelle einen Ausgangscommit
   vor parallelen Änderungen. Lege keinen Remote an und veröffentliche nichts automatisch.
   Nutze getrennte Worktrees, soweit das Plugin den Zielpfad unterstützt; prüfe dessen tatsächliches
   Arbeitsverzeichnis. Andernfalls verwende klar getrennte Dateibereiche und serialisiere Konflikte.
5. Gib jedem Agent Ziel, relevante Dokumente, erlaubte Dateien, API-Verträge und Abnahmekriterien.
   Keine zwei Agents bearbeiten gleichzeitig dieselbe Migration, dasselbe Lockfile oder denselben
   zentralen Vertrag. Ein Integrationsverantwortlicher führt gemeinsame Änderungen zusammen.
6. Prüfe Codex-Implementierungen durch Claude und Claude-Implementierungen durch Codex.
   Lies Diffs und Testergebnisse, behebe Befunde und integriere die Ergebnisse tatsächlich.
   Dokumentiere nicht geprüfte Dinge als offen statt erfolgreiche Tests zu behaupten.

Verbindliche Architektur:
- Backend: Swift, Vapor, Fluent; MariaDB empfohlen und SQLite unterstützt, kein PostgreSQL.
- PWA: Svelte mit shadcn-svelte, statischer Produktionsbuild; Node nur Entwicklung/Build.
- Kein VS Code und keine Pflicht zu dessen Devcontainer-Erweiterung. PhpStorm/PWA, Xcode/Apps;
  Backend in PhpStorm mit Noctule. Linux-Tests IDE-unabhängig über Colima/Compose.
- Drei getrennte Repos, Backend als Hauptrepo mit kanonischem Projektwissen und API-Verträgen.
- AGPLv3; Lizenztexte vorhanden, Dependency-Lizenzen noch prüfen.
- Linux Docker/Swarm auf amd64 und arm64; lokal Compose auf Colima.
- Passkeys primär und mehrere pro Konto. Recovery wählbar: E-Mail-Code, Rückfallpasswort,
  Recovery-Codes. Optionales OIDC, keine Authentik-Pflicht.
- Registrierung nur per Einladung/Token, private Konten, explizite Freigaben für Plan/Ist/Urlaub.
- MCP mit OAuth für ChatGPT/Claude, persönliche Bearer-Tokens für andere Clients.
- Dieselben Fachregeln und Rechte für REST, MCP und spätere Apple-Apps.
- Dateispeicherung administrativ nach Größe in DB, S3 oder lokalem Pfad konfigurierbar.
- Keine Änderungen an meiner vorhandenen Serverdatenbank, Domains, TLS oder Reverse Proxy.

Beginne mit Etappe 0 und 1 aus docs/UMSETZUNG.md und liefere einen tatsächlich ausführbaren
ersten Stand: Projektstruktur, lokale Umgebung, Backend/PWA, Datenbankmigrationen und Kontenbasis.
Priorisiere die dafür notwendigen technischen Durchstiche; spätere Geräte-/Providerprüfungen
dürfen dokumentiert offen bleiben und sollen den lokalen Kern nicht pauschal blockieren.

Vorgeschlagene erste Aufteilung, nach Aufwand ausgleichen:
- Codex: Swift-Backend-Grundlage, DB-Auswahl/Migrationen, Einladung und kontobezogene Dienste
  einschließlich zugehöriger Integrationstests.
- Claude-Agents: Svelte-Oberfläche, Passkey-/Recovery-Bedienung, lokale Compose-Umgebung und
  Browserintegration einschließlich zugehöriger Tests.
- Definiere zunächst gemeinsam die Auth-/API-Verträge. Weise WebAuthn-Verifikation und die
  einzelnen Recovery-Dienste explizit einem Implementierer zu, statt sie zwischen Teams zu verlieren.
- Reserviere echte Implementierungspakete für beide Seiten und verteile die geschätzte Last neu,
  falls die Authentifizierung erheblich mehr Aufwand als die Oberfläche verursacht.

Für das lokale Setup:
- Erzeuge eine eigene Entwicklungs-MariaDB, verwende keine Produktionszugangsdaten.
- Lege .env.example ohne Secrets und projektlokale, ignorierte Konfiguration an.
- Verwende persistente lokale Volumes; keine vorhandenen Colima-/Docker-Daten löschen.
- Sorge für einen dokumentierten lokalen WebAuthn-Testweg und stabile Origin/RP-ID.
- Dokumentiere und prüfe Start, Stopp, Migrationen und Tests mit echten Befehlen.
- Teste MariaDB und SQLite; prüfe Kontentrennung auch über direkte Objektzugriffe.
- ARM64 lokal testen. amd64-Build und amd64-Laufzeit getrennt nachweisen oder konkret als offen markieren.

Arbeite nach dem kurzen Arbeitsplan unmittelbar an der Umsetzung weiter. Stelle bei normaler
lokaler Entwicklungsarbeit nicht nach jedem Schritt eine neue Freigabefrage. Bei externen
Veröffentlichungen oder destruktiven Änderungen halte an und beschreibe die konkrete Aktion.
Installationen außerhalb des Projekts nur gezielt für fehlende Voraussetzungen; keine globalen
Updates oder Permission-Bypässe. Die Umgebung darf notwendige Berechtigungen weiterhin abfragen.

Zum Ende dieses ersten Meilensteins berichte knapp:
- Was läuft und wie starte ich es?
- Welche Funktionen sind wirklich implementiert?
- Was haben Claude-Agents und Codex jeweils umgesetzt?
- Welche Tests liefen erfolgreich, welche fehlen noch?
- Welche konkreten Arbeitspakete sind als Nächstes dran?

Das Repository ist unser vollständiges Projektgedächtnis; Sessions sind wegwerfbar.
Halte docs/STATUS.md, docs/ARBEITSPLAN.md, maßgebliche Dokumente und Einrichtungsanleitung nach
jedem integrierten Schritt aktuell. Dauerhafte Entscheidungen als ADR sichern, niemals nur im Chat.
Vor Sessionende/Reset Dateien/Worktrees, Teststand, offene Fehler, laufende Jobs und nächsten Schritt
festhalten. Ein neuer Agent muss allein aus Repository und Code fortsetzen können, ohne alten
Chat oder Plugin-Thread. Keine Secrets oder vollständigen Transkripte als Memory ablegen.
Beachte docs/ENTWICKLUNGSABLAUF.md. Spätere Etappen bleiben Teil des Gesamtprojekts.
```
