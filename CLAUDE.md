# Timetrack – Arbeitsgrundlage für Claude Code

Backend und PWA implementiert (Etappe 1–4), native Apple-Apps implementiert (Etappe 5, Geräteprüfung offen); alle drei Repos sind öffentlich (seit 17.10.2026). Tatsächlicher Prüfstand in docs/STATUS.md. Die Implementierung soll Claude Code übernehmen;
der Nutzer plant, selbst kaum Code zu schreiben. Fragen gesammelt und nummeriert im
normalen Chat stellen, keine interaktiven Frageformulare.

Das Repository ist das Projektgedächtnis, Sessions sind wegwerfbar. Kein Wissen darf nur in
Chat, Plugin-Thread oder persönlichem Memory liegen. Gemeinsamer Einstieg: `AGENTS.md`.

## Lesen

Zu Beginn jeder Sitzung zuerst `docs/STATUS.md`, `docs/ARBEITSPLAN.md` und
`docs/ENTWICKLUNGSABLAUF.md` lesen, anschließend relevante ADRs unter `docs/decisions/`.

1. `docs/KONZEPT.md`: bestätigte Anforderungen und offene fachliche Details.
2. `docs/ARCHITEKTUR.md`: technischer Entwurf mit Authentifizierung und MCP.
3. `docs/UMSETZUNG.md`: Etappen, Abnahmekriterien und Umsetzungsstand je Etappe.
4. `EINRICHTUNG.md`: lokale Voraussetzungen, Start-/Testbefehle, Konfiguration, Colima und Codex-Plugin.

## Entwicklung mit Agents

Claude Code koordiniert Agents; ungefähr 50 % der tatsächlichen Implementierung übernimmt
Codex über das Claude-Codex-Plugin. Reviews allein erfüllen diesen Anteil nicht.
Gewichtete Arbeitspakete und tatsächliche Beiträge in `docs/ARBEITSPLAN.md` fortlaufend führen.
Worktrees oder getrennte Dateibereiche, ein Schreibverantwortlicher pro Paket und gegenseitige Reviews.
Plugin-Fähigkeiten anhand der installierten Version prüfen; keine Befehle erfinden oder Modellwahl erzwingen.
Lokales Docker läuft über Colima auf diesem ARM64-Mac. Entwicklungsumgebung mit Compose,
späteres Produktionsziel Swarm; vorhandene Infrastruktur und Daten nicht verändern.
Der Startauftrag steht in `CLAUDE_STARTPROMPT.md`.
Vor Sessionende oder Kontextwechsel Status, Tests, unintegrierte Änderungen und nächsten Schritt
im Repository sichern. Dokumentationspflege ist Teil jeder Implementierung und ihrer Abnahme.

## Festgelegte Richtung

- Open Source unter AGPLv3 (AGPL-3.0-only); Lizenztext vorhanden; Abhängigkeitsinventar in docs/LIZENZEN.md (Release-Prüfung offen).
- Backend Swift/Vapor/Fluent; MariaDB empfohlen, SQLite unterstützt, kein PostgreSQL.
- PWA Svelte/shadcn-svelte; Node für Entwicklung/Build erlaubt, nicht im Produktionsbetrieb.
- Kein VS Code. PhpStorm für PWA und Backend (Noctule), Xcode für native Apps.
- Drei öffentliche Repositories, Backend als Hauptrepo; URLs, Pfade und Einrichtung: `docs/REPOSITORIES.md`.
- Linux Docker/Swarm, amd64 und arm64; vorhandene DB 12.3.3-MariaDB-ubu2404.
- Reverse Proxy, Domains, TLS und vorhandene Identitätsinfrastruktur nicht provisionieren.
- App-eigene Passkeys primär, mehrere pro Konto; OpenID Connect optional, kein Pflicht-Authentik.
- Wiederherstellung beim Einrichten wählbar: E-Mail-Codes, Rückfallpasswort oder Recovery-Codes.
- Registrierung nur per Einladung/Token, auch bei OIDC. Private Konten und explizite Planfreigaben.
- Planfreigaben können geplante und tatsächliche Zeiten sowie Urlaub umfassen, standardmäßig privat.
- MCP für ChatGPT/Claude mit OAuth; persönliche Bearer-Tokens für andere Clients.
  Beide Wege verwenden dieselben Fachregeln und Kontorechte wie REST.
- Fachliche Daten/Dateimetadaten in DB, Dateien regelbasiert in DB, S3 oder lokalem Pfad.
- Backend/PWA/Shortcuts zuerst, dann macOS, dann iOS/iPadOS; watchOS gewünscht.
- Native Apps SwiftUI/Liquid Glass/Apple HIG; Zielgeräte laut Nutzer auf OS 27.
- Selbstständigenfunktionen später. Offline-Schreiben optional. iCloud darf bis zur nativen App warten.

## Sprache

Code, Kommentare, Tests und technische Bezeichner durchgängig auf Englisch;
Oberfläche und andere nutzerseitige Texte auf Deutsch. Details und Lokalisierung:
`docs/ENTWICKLUNGSABLAUF.md`, Abschnitt „Sprache von Code und Oberfläche“.
Diese Regel bei jedem Agent-Auftrag mitgeben.

## Leitplanken

- Tages-/Wochen-Soll, Schule, Fahrtzeiten, Pausen und Zeitkonto konfigurierbar.
- Arbeitsmodelle mit Gültigkeitszeitraum; beim Ausbildungsende Historie erhalten.
- Rohzeit, Korrektur und gerundete Bewertung trennen. Rundung standardmäßig an,
  15 Minuten zugunsten des Arbeitnehmers, nur erster Tagesbeginn/letztes Tagesende.
  Innere Abschnittsgrenzen und tatsächliche Pausen/Lücken bleiben unverändert.
- Berufsschulstunden unterhalb der konfigurierten Schwelle manuell ergänzen;
  keine automatische Rückkehrpflicht ableiten. Rechtsprofile für Jugendliche fehlen noch (nur `arbzg-adult-de`).
- Berichtsheftfelder: Lernfeld, Zeit, Notizen; kopierbare Ausgabe für das IHK-Portal.
- Pausenhinweise anhand tatsächlicher Zeiten; keine nicht genommenen Pausen erfinden.
- Automatik direkt/Vorschlag/aus je Ort und global abschaltbar; Vorbeifahrt nicht buchen.
- Standortsignal, Planung und tatsächliche Zeit sind unterschiedliche Objekte.
- KI erstellt bearbeitbare Entwürfe, erfindet keine Tätigkeiten. KI-Zugang getrennt vom App-Login.
- Kontentrennung auch für MCP, Exporte, Anhänge, Jobs, Suche und Push durchsetzen.
- Vorschläge nicht als Nutzerentscheidungen darstellen; offene Details kenntlich halten.

## Öffentliches Repository, Kennungen, Namen

- **Commit-Autor ist die Pseudonym-Identität des Projekts** (Git-Konfiguration nicht ändern, kein `--author`). Keine privaten E-Mail-Adressen, Pfade, Hostnamen, IP-Adressen oder Domains in Repos; keine Namen oder Altersangaben realer Personen.
- **Namensentscheidung (17.10.2026):** Das Projekt heißt Timetrack; „Chronolog“ ist nur der App-Store-Eintrag, Anzeigename in Apps und PWA bleibt Timetrack. Die produktive Domain (Passkey-RP-ID) und die Bundle-ID bleiben unverändert. Das **Backend-Repo verwendet dafür Platzhalter** (`timetrack.example.org`, `com.example.timetrack`, Team-ID `ABCDE12345`); die echten Werte stehen nur im Apple-Repo (funktional nötig) und in der privaten Betreiber-Konfiguration. Diese Konvention beibehalten.
- Commit-Hashes in Handoffs vor dem 17.10.2026 sind durch die Historienbereinigung ungültig; mit Paket-ID und `git log --grep` arbeiten.

Build-, Start- und Testbefehle stehen in EINRICHTUNG.md; produktionsnahes Deployment (Swarm) ist noch offen. Dokumentationslandkarte: docs/README.md.
