# SEC-PATH – Pfadnormalisierung der Middleware

Stand: 03.11.2026. Branch `sec-path-normalize`, isolierter Clone `/private/tmp/tt-be-slash`.
Nur dort gearbeitet; Hauptcheckout unverändert. Kein Push. Clone bis zum Fetch durch den Auftraggeber behalten.

## Befund und Umsetzung

Vapors DefaultResponder zerlegt den URL-Pfad an `/` und verwirft leere Segmente.
Die Auth-Middleware prüfte dagegen rohe Stringpräfixe; `Routes.swift` übergibt beim
zusätzlichen fachlichen Limit bewusst keine IP. Damit umging beispielsweise
`/api/v1/auth//login/options` den IP-Zähler, obwohl derselbe Handler ausgeführt wird.

`Request.routePathComponents` verwendet `split(separator: "/", omittingEmptySubsequences: true)`;
`normalizedRoutePath` setzt diese Komponenten für die bestehenden Stringprüfungen zusammen.
Es erfolgt keine Prozentdekodierung für die Routerentscheidung. Die Anfrage-URL wird nicht verändert.

| Stelle | Status | Ergebnis |
| --- | --- | --- |
| `SessionService.swift`, AuthRateLimitMiddleware | fixed | Komponentenvergleich für register/login/recovery und die beiden E-Mail-Präfixe; Methoden weiterhin nur POST/PUT. Bestehende E-Mail-Stringpräfixsemantik innerhalb des letzten Segments erhalten. IP wird weiterhin vor dem Handler/Body belastet. |
| `Routes.swift`, limit | already safe | Absichtlich kein zusätzlicher IP-Zähler: Middleware zählt einmal, Handler ergänzt fachliche Zähler. Unverändert. |
| `Groups/GroupRoutes.swift`, GroupPublicMiddleware | fixed | Normalisierter Pfad für noindex/no-referrer/no-store, auch bei Fehlerantworten. |
| `AutomationService.swift`, DeviceScopeGuard | already safe | Exakte rohe Allowlist ist fail-closed: Varianten werden mit Bearer abgewiesen, keine Ausweitung der erlaubten Pfade. Unverändert. |
| `PWAStaticMiddleware.swift`, reservierte Präfixe | fixed | Normalisierte Routerpfade gehen an den Router; auch der nach Prozentdekodierung geprüfte reservierte Pfad verwirft leere Segmente. Dateisystem-/Symlink-/Traversalprüfungen unverändert. |
| `SessionService.swift`, Recovery-Allowlist | already safe | Exakte Pfad-/Methoden-Allowlist weist Varianten geschlossen ab; keine neue Recovery-Berechtigung. Unverändert. |
| `Modules/ModuleRoutes.swift`, ModuleGuard.keys | already safe | Modulzuordnung zerlegt bereits in nichtleere Segmente. |
| `Modules/ModuleRoutes.swift`, Public-Ausnahme | fixed | Zusätzliche rohe Präfixprüfung gefunden: Public-Link-Routen ignorieren auch bei Doppelslash veraltete Sitzungscookies. Server-Modulsperren bleiben vorgeschaltet. |
| `AuthSupport.swift`, APIErrorMiddleware | fixed | Im Audit gefundene rohe API-/Trigger-Präfixe für erfolgreiche Antwort-Cacheheader normalisiert. |
| `TimeErrorMiddleware.swift` | fixed | Im Audit gefundene rohe Präfixauswahl für das Fehlerformat normalisiert. |

Dateisystem-Präfixprüfungen (Storage, statische Dateien, Wartung, Import) sind keine
Routerentscheidungen und bleiben unverändert. Kein neuer Vertrag, keine Migration,
keine Abhängigkeit oder Konfigurationsoption. Keine ADR erforderlich: bestehende Regeln werden erhalten.

## Geänderte Dateien

- `Sources/TimetrackKit/RoutePath.swift` (neu)
- `Sources/TimetrackKit/SessionService.swift`
- `Sources/TimetrackKit/Groups/GroupRoutes.swift`
- `Sources/TimetrackKit/Modules/ModuleRoutes.swift`
- `Sources/TimetrackKit/PWAStaticMiddleware.swift`
- `Sources/TimetrackKit/AuthSupport.swift`
- `Sources/TimetrackKit/TimeErrorMiddleware.swift`
- `Tests/TimetrackKitTests/PathNormalizationTests.swift` (neu)
- `docs/STATUS.md`, `docs/ARBEITSPLAN.md`, `CHANGELOG.md`, diese Übergabe

## Prüfungen und Grenzen

Vier neue Tests als Erweiterung der vorhandenen AuthTests mit deren XCTVapor-/In-Memory-SQLite-Aufbau:

- `testPathNormalizationAuthRateLimit`: Loginvarianten erreichen vorher den Handler;
  nach 60 IP-Ereignissen 429 für kanonische und Doppelslash-Pfade aller fünf Präfixgruppen;
  GET bleibt außerhalb der POST-/PUT-Begrenzung.
- `testPathNormalizationRecoveryRemainsClosed`: kanonische erlaubte Pfade weiter nutzbar,
  Varianten erlaubter und gesperrter Pfade bleiben gesperrt.
- `testPathNormalizationDeviceScopeRemainsClosed`: echter Gerätetoken, normaler
  Automationpfad erreicht Bodyprüfung, Varianten und fachfremde Pfade bleiben 401.
- `testPathNormalizationPublicHeadersAndPWAReservedRoutes`: Health-Routing,
  reservierte Pfade ohne SPA-Fallback, Gruppenheader und Public-Ausnahme mit veraltetem Cookie.

Tatsächlich ausgeführt (03.11.2026):

1. `swift test --build-system native --filter PathNormalization`: Exit 1 vor Kompilierung;
   zunächst unzugänglicher Standard-Modulcache. Wiederholung mit TMPDIR,
   CLANG_MODULE_CACHE_PATH und SWIFTPM_MODULECACHE_OVERRIDE innerhalb des Clones:
   Exit 1, `sandbox-exec: sandbox_apply: Operation not permitted` beim Manifest.
2. `swift test --build-system native` mit denselben lokalen Cache-/Temp-Umgebungsvariablen:
   Exit 1, derselbe Manifestfehler. Keine Tests ausgeführt, kein Socket-Bind-Test erreicht.
3. `swiftc -frontend -parse` für alle acht geänderten/neuen Swift-Dateien: Exit 0.
   Das ist ausschließlich Syntaxprüfung, kein Typecheck oder Laufzeittest.
4. `git diff --check`: Exit 0.

Keine Sandbox-Umgehungsflags verwendet. Keine MariaDB-Prüfung. Lokale Logs
`targeted-tests.log` und `full-tests.log` bleiben unversioniert im Clone; sie enthalten
werkzeugseitige lokale Pfade und gehören nicht ins öffentliche Repository.
Keine laufenden Jobs oder Dienste.

## Nächster konkreter Schritt

Auftraggeber fetcht `sec-path-normalize` aus dem behaltenen Clone und führt zuerst
`swift test --build-system native --filter PathNormalization`, anschließend
`swift test --build-system native` in einer geeigneten Testumgebung aus. Erst danach
ist die Laufzeitabnahme belegt; derzeit ist auch der Typecheck offen.

## Rückfragen

Keine. Die bereits geschlossenen Allowlisten werden gemäß „nur echte Abweichungen ändern“ beibehalten.

## Abweichungen vom Auftrag

Die verlangte Laufzeitverifikation ist durch den Manifest-Sandboxfehler nicht möglich.
Der erste Swift-Aufruf nutzte die werkzeugseitigen Standard-Temp-/Cachepfade; die
Wiederholungen verwenden ausschließlich Temp-/Modulcacheverzeichnisse im Clone.
Die zwei zusätzlichen, real betroffenen Antwortprüfungen wurden im Rahmen des
beauftragten Audits minimal angeglichen. Der Arbeitsplan wurde gemäß Repositoryregeln mit aktualisiert.
