# IDEs und lokale Entwicklungswege

Stand: 13.10.2026, am 17.10.2026 nur auf Aktualität der Aussagen gesichtet, nicht neu geprüft (Inhalt Quellen und Plugin-Versionen können überholt sein). Bestätigt: kein VS Code. PhpStorm für PWA, Xcode für native Apps.
Backend jetzt beschlossen: PhpStorm mit Noctule. Drei Repos, Backend als Hauptrepo; siehe `REPOSITORIES.md`.

## JetBrains-Option

Noctule ist ein Drittanbieter-Plugin für JetBrains-IDEs einschließlich PhpStorm und GoLand.
Es unterstützt Swift Package Manager, SourceKit-LSP-basierte Vervollständigung/Navigation
und Build-/Run-/Testbefehle. Laut Anbieter aktuell IDE-Versionen 2025.3–2026.2 und Swift ab 6.2.
Damit ist das vorhandene PhpStorm ein Kandidat für PWA und Backend im selben Projekt.
Die konkrete installierte IDE-/Toolchain-Kombination vor Festlegung erproben.

Entscheidende Einschränkung: integriertes Swift-Debugging ist laut Anbieter noch nicht vorhanden.
Grundfunktionen sind kostenlos, bestimmte Funktionen wie der integrierte Testrunner sind kostenpflichtig.
Keine Stabilitätszusage: Der Nutzer möchte gerade keine unzuverlässige Plugin-Abhängigkeit.
Noctule ist nun gewählt; Einschränkungen bleiben dokumentiert. Xcode kann bei Debuggingbedarf helfen.
Quellen:
https://noctule.dev/
https://noctule.dev/docs/overview/

Das Backend-Verzeichnis mit Package.swift oder das übergeordnete Monorepo kann geöffnet werden;
Noctule erkennt enthaltene Swift-Pakete. Quelle:
https://noctule.dev/docs/swiftpm/open/

## Alternative ohne zusätzliches Swift-Plugin

Xcode kann auch das Vapor-Backend als Swift-Paket öffnen und lokal debuggen.
Backendprozess auf macOS, Entwicklungsdatenbank in Colima; Linux-Builds/-Tests zusätzlich ausführen.
Quelle: https://docs.vapor.codes/getting-started/xcode/

JetBrains AppCode wurde eingestellt. Eine neue Umgebung nicht auf alte AppCode-Versionen stützen.
Quelle: https://www.jetbrains.com/objc/

## JetBrains Air als Agent-Oberfläche

Air ist für Agent-Aufträge, parallele Arbeit und Änderungsreviews interessant; es ersetzt nicht
automatisch die Swift-Sprachunterstützung und den Debugger einer klassischen IDE.
Die aktuellen Angebote unterscheiden Air in IDEs und Air Teams (Cloud-Ausführung).
Für unseren lokalen Colima-Workflow kommt zunächst die IDE-Integration in Betracht;
keine Migration in Cloud-Umgebungen ist beschlossen.
Quelle: https://www.jetbrains.com/air/

Air in IDEs kann lokale Agents beziehungsweise deren Terminaloberfläche verwenden.
Laut aktueller Dokumentation benötigt Claude Agent in der Chatoberfläche JetBrains AI oder
Anthropic-API-Zugang; ein Claude-Abonnement verwendet man über Claude Code in der Terminaloberfläche.
Quelle: https://www.jetbrains.com/help/air-ides/air-overview.html

Vorschlag für Timetrack: PhpStorm für PWA/Repository, optional Air für Agent-Verwaltung,
Xcode für Backend-Debugging und native Apps; Linux-Tests weiter mit Colima.
Das installierte Claude-Codex-Plugin ist nicht automatisch Teil eines eingebetteten Claude Agent.
Vor Nutzung in Air explizit prüfen: echte Claude-Code-Sitzung, Plugin geladen, richtiger
Projektpfad und funktionierender schreibender Codex-Auftrag. Bestehenden 50/50-Workflow erhalten.
Keine Zusage vollständiger Swift-IDE-Funktionen durch Air, keine Air-Pflicht oder Installation.

## Gemeinsame Leitplanken

PhpStorm bleibt für die Svelte-PWA vorgesehen, Xcode für native SwiftUI-Apps.
Keine zusätzliche JetBrains-IDE kaufen, bevor die vorhandene mit Noctule geprüft wurde.
Keine VS-Code-Abhängigkeit und keine vorausgesetzte VS-Code-Devcontainer-Einrichtung.
Linux-Entwicklungstests über IDE-unabhängige Docker-/Compose-Befehle mit Colima vorsehen.
Builds, Tests und Agent-Workflow müssen unabhängig von der IDE funktionieren.
Persönliche IDE-Zustände, Zugangsdaten und lokale Caches nicht ins Repository aufnehmen.
