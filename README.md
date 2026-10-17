# Timetrack – Backend und Hauptrepo

Hier Claude Code starten. Dieses Repository führt das vollständige Projektwissen,
Agent-Aufträge und API-Verträge für Backend, PWA und Apple-Apps (Apple-Apps noch nicht begonnen).

## Was hier liegt

Swift/Vapor/Fluent-Backend (`Sources/TimetrackKit`, Einstieg `Sources/App`) mit MariaDB und SQLite:
Konten, Einladungen, Passkeys, Recovery, optionales OIDC, Zeittracking, Urlaub/Planung/Freigaben,
Export/Import, Dateispeicher, Berichtsheft, OAuth-Server, MCP-Endpunkt `/mcp`, Hinweise und Web Push.
Das Backend liefert auch die gebaute statische PWA aus (`PWA_STATIC_DIR`). Maßgeblich für den
tatsächlich geprüften Stand ist [docs/STATUS.md](docs/STATUS.md); der API-Vertrag steht in
[contracts/openapi.yaml](contracts/openapi.yaml) (aktuell v0.9.0).

## Einstieg

- [Einrichtung, Start- und Testbefehle](EINRICHTUNG.md)
- [Deployment in Produktion (Swarm, eigene MariaDB, Proxy)](docs/DEPLOYMENT.md)
- [Dokumentationslandkarte und ADR-Index](docs/README.md)
- [Tatsächlicher Stand](docs/STATUS.md) und [Arbeitsplan](docs/ARBEITSPLAN.md)
- [Produktkonzept](docs/KONZEPT.md), [Architektur](docs/ARCHITEKTUR.md), [Etappen](docs/UMSETZUNG.md), [Repository-Pfade](docs/REPOSITORIES.md)
- [Prompt für Claude Code](CLAUDE_STARTPROMPT.md), [Agent-Einstieg](AGENTS.md)

Lizenz: AGPL-3.0-only, vollständiger Text in LICENSE; Abhängigkeitsinventar in [docs/LIZENZEN.md](docs/LIZENZEN.md).
Keine Remotes eingerichtet, nichts veröffentlicht.
