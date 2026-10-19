# Timetrack

Selbst gehostete Arbeitszeiterfassung für Auszubildende und Beschäftigte: Zeiten erfassen, Urlaub und Planung verwalten, Berichtsheft führen, Daten exportieren und importieren, mit PWA, nativen Apple-Apps und optional mit KI-Assistenten über MCP. AGPL-3.0-only.

> **Status: Alpha.** Backend und PWA sind funktional (Etappe 1–4), die nativen Apple-Apps sind implementiert, aber noch nicht auf Echtgeräten erprobt. Es gibt keine Release-Version, kein produktives Deployment im Repository und keine Garantie für Datenformate oder API-Stabilität (Vertrag aktuell v0.14.0). Was geprüft ist und was nicht, steht ehrlich in [docs/STATUS.md](docs/STATUS.md).

Dies ist das **Hauptrepository**: Es enthält das Backend, den API-Vertrag, Betrieb/Deployment, die Website und die gesamte Projektdokumentation (Konzept, Architektur, Entscheidungen, Arbeitsplan).

## Funktionen

- Mehrere getrennte Konten pro Server, Registrierung nur per Einladung, Passkeys (mehrere je Konto), Wiederherstellung per Recovery-Codes, Rückfallpasswort oder E-Mail-Code, optional OpenID Connect.
- Zeiterfassung mit Arbeitsmodellen (Gültigkeitszeiträume), Orten, Timer, Korrekturen, Pausenhinweisen, Berufsschulregel, Rundung nur an den äußersten Tagesgrenzen und Zeitkonto; Rohzeit, Korrektur und Bewertung bleiben getrennt.
- Automatik über Geräte-Token (Apple-Kurzbefehle), je Ort direkt, als Vorschlag oder aus.
- Urlaub, Abwesenheiten, Feiertage (alle Bundesländer), Planung und Planfreigaben für ausgewählte Konten.
- Berichtsheft (Lernfelder, Zeit, Notizen) mit kopierbarer Ausgabe.
- Export (XLSX/PDF/CSV) und Import (CSV/XLSX mit Vorschau und Rücknahme), Dateispeicher in Datenbank, lokalem Pfad oder S3.
- MCP-Endpunkt mit OAuth und persönlichen Tokens für ChatGPT/Claude und andere Clients, mit denselben Regeln und Rechten wie die REST-API.
- Hinweise und Web Push, abschaltbare Module, Kontenverwaltung, Datenauskunft und Selbstlöschung.

## Architektur

Swift 6 / Vapor / Fluent als modularer Monolith (`Sources/TimetrackKit`, Einstieg `Sources/App`), MariaDB (empfohlen) oder SQLite, kein PostgreSQL. REST unter `/api/v1` nach [contracts/openapi.yaml](contracts/openapi.yaml), dazu `/mcp` und `/oauth/*`. Das Backend liefert die gebaute statische PWA aus. Container-Images für Linux amd64 und arm64; Entwicklung mit Docker Compose, Produktion als Swarm-Stack. Details: [docs/ARCHITEKTUR.md](docs/ARCHITEKTUR.md).

## Repositories

| Repository | Inhalt |
| --- | --- |
| [timetrack-backend](https://github.com/MagicalWig34653/timetrack-backend) (dieses) | Backend, API-Vertrag, Betrieb, Website, Dokumentation |
| [timetrack-pwa](https://github.com/MagicalWig34653/timetrack-pwa) | Progressive Web App (Svelte 5/SvelteKit, shadcn-svelte) |
| [timetrack-apple](https://github.com/MagicalWig34653/timetrack-apple) | Apps für macOS, iOS/iPadOS und watchOS (SwiftUI) |

Ablage nebeneinander: `<workspace>/timetrack-backend`, `<workspace>/timetrack-pwa`, `<workspace>/timetrack-apple` (siehe [docs/REPOSITORIES.md](docs/REPOSITORIES.md)).

## Installation

Das fertige, öffentliche Image `ghcr.io/magicalwig34653/timetrack-backend` (amd64 und arm64, enthält die Web-App) wird standardmäßig verwendet; selbst bauen ist optional.

```sh
mkdir timetrack && cd timetrack     # Dateien aus deploy/compose/ holen, .env anpassen, dann:
./init-secrets.sh --generate-db-password && docker compose --profile db up -d
docker compose run --rm --no-deps -T backend bootstrap-admin --env production   # Einladungslink für den ersten Admin
```

| Seite | Inhalt |
| --- | --- |
| [Überblick und Auswahl](docs/INSTALLATION.md) | Voraussetzungen, Compose oder Swarm, Image und Tags |
| [Docker Compose](docs/installation/compose.md) / [Docker Swarm](docs/installation/swarm.md) | Schritt für Schritt |
| [Eigene MariaDB](docs/installation/mariadb.md), [Reverse Proxy und TLS](docs/installation/proxy.md) | Datenbank und Proxy vorbereiten |
| [Ersteinrichtung](docs/installation/ersteinrichtung.md) | Admin, Passkey, Onboarding, Einladungen, Apps, Import, MCP |
| [Aktualisieren](docs/UPDATE.md), [Sichern](docs/installation/backup.md), [Probleme](docs/installation/probleme.md), [Konfiguration](docs/installation/konfiguration.md) | Betrieb |
| [Image selbst bauen](docs/IMAGE-BAUEN.md) | nur bei eigenen Änderungen |

Ausführliche Referenz für den Swarm mit Checklisten: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Schnellstart (Entwicklung)

Voraussetzungen: Swift-Toolchain (Xcode bzw. Swift 6.x), Docker mit Compose (z. B. Colima). Ausführliche Anleitung mit allen Varianten: [EINRICHTUNG.md](EINRICHTUNG.md).

```sh
scripts/dev-env.sh init       # .env mit Zufallspasswörtern erzeugen (nicht committen)
scripts/dev-env.sh up-app     # Backend + MariaDB im Container, Port 18080
docker compose --project-name timetrack-dev --profile app run --rm -T backend bootstrap-admin
                              # gibt einen einmaligen Einladungslink für den ersten Admin aus
swift test --build-system native   # Tests (SQLite; MariaDB-Läufe brauchen die Variablen aus `scripts/dev-env.sh test-db`)
```

Die PWA wird im Repository timetrack-pwa gebaut (`npm run build`) und über `PWA_STATIC_DIR` vom Backend ausgeliefert. Produktionsbetrieb: [docs/INSTALLATION.md](docs/INSTALLATION.md), [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) und [docs/BETRIEB.md](docs/BETRIEB.md).

## Dokumentation

- [Dokumentationslandkarte und ADR-Index](docs/README.md)
- [Tatsächlicher Stand](docs/STATUS.md), [Arbeitsplan](docs/ARBEITSPLAN.md), [Etappen](docs/UMSETZUNG.md)
- [Konzept](docs/KONZEPT.md), [Architektur](docs/ARCHITEKTUR.md), [Designsprache](docs/DESIGN.md), [MCP-Anbindung](docs/MCP.md)
- [CI, Images und Website](docs/CI.md), [Lizenzinventar](docs/LIZENZEN.md)
- Agent-Einstieg für Coding-Agents: [AGENTS.md](AGENTS.md), [CLAUDE.md](CLAUDE.md)

Die Dokumentation und die Oberfläche sind deutsch; Code, Kommentare und Tests englisch.

## Mitarbeit und Sicherheit

Das Projekt wird mit Coding-Agents entwickelt; das Repository ist das Projektgedächtnis (siehe [docs/ENTWICKLUNGSABLAUF.md](docs/ENTWICKLUNGSABLAUF.md)). Fehlermeldungen und Vorschläge sind als Issues willkommen (bitte nur synthetische Daten, keine echten Arbeitszeiten oder Zugangsdaten); Pull Requests bitte vorher als Issue abstimmen. Sicherheitslücken nicht öffentlich melden, sondern über die private Meldung von GitHub (Reiter „Security“), siehe [.github/SECURITY.md](.github/SECURITY.md).

## Lizenz

[GNU AGPL-3.0-only](LICENSE). Abhängigkeiten stehen unter eigenen Lizenzen ([docs/LIZENZEN.md](docs/LIZENZEN.md); die Release-Prüfung ist noch offen). Das Image enthält die Lizenztexte unter `/usr/share/doc/timetrack/THIRD-PARTY-NOTICES` (erzeugt mit `scripts/third-party-notices.sh`). **Vorschlag, nicht in Kraft:** [LICENSE-EXCEPTION.md](LICENSE-EXCEPTION.md) (OpenSSL-Verlinkungsausnahme nach AGPL §7), nötig nur solange das eingebettete BoringSSL von `swift-nio-ssl` 2.37.5 die alte OpenSSL-Lizenz trägt; die Entscheidung liegt beim Rechteinhaber, kein Rechtsrat.
