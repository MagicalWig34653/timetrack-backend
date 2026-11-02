# Adversariales Backend-Review – 01.11.2026

> **Herkunft und Sicherung (02.11.2026):** Dieses Review wurde auf ausdrückliche Nutzeranweisung vom 01.11.2026 mit Codex durchgeführt (Ausnahme von der Nutzerentscheidung vom 19.10.2026 „kein Codex mehr“). Das Modell ist laut Codex-Ausgabe GPT-6.1-sol; der Reasoning-Effort wurde nicht verifiziert. Der Text unten ist unverändert übernommen (Prüfung auf private Daten: keine E-Mail-Adressen, Domains, Hostnamen, IP-Adressen, Home-Pfade, Personennamen oder Geheimnisse gefunden, keine Bereinigung nötig). Der Abgleich gegen den aktuellen Code (`main`, Vertrag 0.41.0) steht am Ende des Dokuments. Als Review gezählt, nicht als Umsetzung.

Modell: GPT-6.1-sol (Codex). Reasoning effort: Der konkrete Runtime-Parameter wird dieser Sitzung nicht offengelegt; ein tatsächlich verwendeter Wert wie `medium` oder `high` ist deshalb nicht verifizierbar.

Geprüfter Stand: `main`, `fd2f3aeae912aaae5ee85a4a8343d978daa37d94`, OpenAPI 0.39.0. Ausgangspunkt: Review C9–C18 und Reparaturen C19; Schwerpunkt auf den danach hinzugekommenen Funktionen. Statisches Review, keine Anwendung gestartet, keine Tests, Builds oder Migrationen ausgeführt. Insbesondere sind Wettläufe und Datenbank-Teilfehler unten aus dem gelesenen Kontrollfluss hergeleitet, nicht durch Laufzeitversuche reproduziert. Die Schreibbeschränkung wurde auf diese Berichtsdatei eingehalten; kein Commit/Push.

Während des Reviews erschien eine fremde Änderung an `Tests/TimetrackKitTests/OIDCTokenTests.swift` (zwei Diff-Zeilen); sie wurde nicht verändert oder als Review-Ergebnis gewertet. Der HEAD blieb unverändert.

## Ergebnis

| severity | Anzahl |
| --- | ---: |
| critical | 0 |
| high | 2 |
| medium | 8 |
| low | 1 |
| info | 0 |

Alle elf Befunde haben eine konkrete Codegrundlage. Bedingte Betriebsszenarien sind ausdrücklich benannt. Es wurde kein direkter Zugriff eines gewöhnlichen Kontos auf private Objekte eines anderen Kontos nachgewiesen. Das ist keine Zusicherung der Fehlerfreiheit.

## F01 – high – Ungeprüfte Pagination kann den Backend-Prozess beenden

**Status:** behoben in CX-A (7e64cb7), Details `docs/handoffs/CX-A.md`.

**Datei:Zeile:** `Sources/TimetrackKit/TimeCancelled.swift:46`; weiterer gleicher Fehler: `Sources/TimetrackKit/Accounts/AccountAdminService.swift:22`.

**Problem:** `listCancelled` prüft nur `offset >= 0` und bildet danach `offset + limit` mit normaler Swift-Integerarithmetik. `Int.max` ist ein zulässiger dekodierter Wert, die Addition löst jedoch einen Overflow-Trap aus. Das ist kein werfbarer Fehler und wird von den Fehler-Middlewares nicht abgefangen. Die Admin-Liste hat dasselbe Muster.

**Fehlerszenario:** Ein normales angemeldetes Konto ruft `GET /api/v1/time/segments/cancelled?offset=9223372036854775807&limit=1` auf. Nach dem Count führt die Addition zum Prozessabbruch; vorhandene stornierte Segmente sind nicht erforderlich. MCP `list_cancelled_segments` erreicht dieselbe Methode und erlaubt ein Integer-Offset ohne Obergrenze (`MCPTools.swift`). Wiederholungen können auch mehrere Replikate treffen.

**Empfehlung:** Offset sinnvoll begrenzen und die Bereichsbildung mit `addingReportingOverflow` absichern; identisches Muster bei der Admin-Liste beheben. Regressionen für REST, MCP und die größte zulässige Integerzahl ergänzen.

## F02 – high – OAuth und persönliche Tokens können nach Sitzungswiderruf neue Zugangsdaten erzeugen

**Status:** behoben in CX-A (7e64cb7), Details `docs/handoffs/CX-A.md`.

**Datei:Zeile:** `Sources/TimetrackKit/OAuth/OAuthCredentials.swift:53`; `Sources/TimetrackKit/OAuth/OAuthService.swift:174`.

**Problem:** `createToken` prüft `context.fresh()` ausschließlich vor dem Warten auf `auth_lock`. Innerhalb der Transaktion fehlt `auth.authenticate(context.token, on: tx)`. `decide` verwendet ebenfalls den zuvor geprüften Kontext und bindet den Consent an dessen alten Session-Hash, ohne die Sitzung erneut auf Widerruf/Ablauf zu prüfen. Im Unterschied dazu authentifiziert `TimeServices.session` innerhalb des Locks erneut.

**Fehlerszenario:** Eine Anfrage mit noch gültiger Sitzung passiert die Middleware und wartet auf den Lock. Eine davor ausgeführte Logout-/Admin-Widerrufstransaktion widerruft diese Sitzung und committet. Anschließend erstellt die wartende Anfrage trotzdem ein persönliches Token oder einen OAuth-Grant samt Code. Nach reinem Sitzungswiderruf sind diese neuen Zugangsdaten sofort nutzbar. Bei Kontodeaktivierung können nach der Credential-Bereinigung entstandene persönliche Tokens nach einer späteren Reaktivierung nutzbar werden.

**Empfehlung:** Im serialisierten Schreibvorgang die Sitzung erneut authentifizieren und `normal`/`fresh` auf den aktuellen Kontext anwenden. Consent-Bindung und Account-ID daraus ableiten. Deterministische Tests mit Widerruf zwischen Middleware-Prüfung und Lock-Erwerb vorsehen.

## F03 – medium – MCP schreibt mit einem inzwischen widerrufenen oder eingeschränkten Principal

**Status:** behoben in CX-A (7e64cb7), Details `docs/handoffs/CX-A.md`.

**Datei:Zeile:** `Sources/TimetrackKit/MCP/MCPTools.swift:14`; zugehörig `Sources/TimetrackKit/MCP/MCPRoutes.swift:176` und `Sources/TimetrackKit/OAuth/BearerPrincipal.swift:25`.

**Problem:** Der Bearer wird vor Ratenbegrenzung und Tool-Transaktion geprüft. `McpToolContext.session` prüft unter dem Lock nur, ob das Konto aktiv ist. Token-Ablauf, Token-/Grant-Widerruf und aktuelle Scopes werden nicht neu gelesen. Die Scope-Prüfung in `call` nutzt den alten Principal. Bei OAuth enthält dieser zudem nur die Grant-ID, nicht die konkrete Access-Token-ID.

**Fehlerszenario:** Eine Tool-Anfrage wird authentifiziert und wartet. Der Besitzer widerruft das persönliche Token oder den Grant, oder beschränkt dessen Scopes auf Lesen. Die danach ausgeführte Anfrage kann weiterhin `create_segment`/`correct_segment` durchführen. Die erneute Modulprüfung verhindert diesen Credential-Wettlauf nicht.

**Empfehlung:** Die konkrete Credential-Identität bis in die Transaktion mitführen, dort Gültigkeit und aktuelle Scopes erneut auflösen und die Tool-Berechtigung damit prüfen. Widerruf und Tool-Ausführung entsprechend koordinieren.

## F04 – medium – Recovery verrät aktivierte Verfahren durch Status- und Zeit-Orakel

**Datei:Zeile:** `Sources/TimetrackKit/AuthSupport.swift:126`; `Sources/TimetrackKit/RecoveryService.swift:174`.

**Problem:** Ein Recovery-Versuch hat nur dann eine `accountId`, wenn Konto und ausgewähltes Verfahren verfügbar sind. `limitRequest(.recovery)` belastet das Handle-Limit nur für solche Versuche. Scheinversuche für unbekannte Konten oder ausgeschaltete Verfahren belasten dieses Limit nicht. Außerdem wartet `recoveryStart` nur bei tatsächlich aktivierter E-Mail-Recovery auf den SMTP-Versand; `try?` vereinheitlicht den Status, aber nicht die Antwortzeit.

**Fehlerszenario:** Innerhalb von fünf Minuten vier Recovery-Versuche für dasselbe Handle/Verfahren starten und auf mehrere dieser IDs falsche Beweise senden. Bei einem aktivierten Verfahren wächst der Handle-Zähler mit jedem Complete-Aufruf und erreicht vor dem gemeinsamen IP-Limit 429. Bei Scheinversuchen bleiben die Complete-Antworten 401. Die fünf Versuche pro ID lassen sich durch mehrere Start-IDs berücksichtigen. Für E-Mail-Recovery ist zusätzlich die SMTP-Latenz ein messbares Signal. Damit ist die geforderte Ununterscheidbarkeit trotz gleicher Start-Antwort nicht gegeben.

**Empfehlung:** Alle Versuche an denselben normalisierten, gehashten Identifier-Zähler binden, auch Scheinversuche; dazu keinen echten Account-Fremdschlüssel voraussetzen. Mail über eine vom HTTP-Ergebnis entkoppelte Zustellung senden. Die komplette Antwortfolge einschließlich Rate-Limits testen.

## F05 – medium – Fehlgeschlagene öffentliche Gruppenschreibzugriffe umgehen die Ratenlimits

**Datei:Zeile:** `Sources/TimetrackKit/Groups/GroupRoutes.swift:70`.

**Problem:** Die IP-/Schreib-/Link-Zähler werden in derselben Transaktion wie die Fachoperation angelegt. Wirft diese beispielsweise `name_taken`, `answers_invalid`, `group_closed`, `group_full` oder `not_found` für ein Unterobjekt, rollen alle Zähler zurück. Nur `edit_secret_invalid` wird außerhalb der Transaktion nachgezählt. Unbekannte Link-Tokens werden dagegen korrekt über einen Rückgabewert committet.

**Fehlerszenario:** Ein Teilnehmer kennt einen gültigen Link und sendet wiederholt eine bestehende Namensbelegung mit gültigen Antworten oder einen ungültigen Optionsverweis. Jede Anfrage erwirbt den globalen `auth_lock` und führt Datenbankabfragen aus, aber weder die Grenze von 40 Schreibzugriffen pro IP noch die von 150 pro Link wird erreicht. Die Last betrifft damit auch Authentifizierung und Schreibvorgänge anderer Konten.

**Empfehlung:** Ratenzähler unabhängig vom Erfolg der Fachtransaktion dauerhaft erfassen. Alternativ fachliche Fehler als Ergebniswert aus einer Transaktion mit sicher zurückgenommenen Fachänderungen transportieren. Regressionen für jede Fehlerklasse und falsche Endpoint-Typen ergänzen.

## F06 – medium – g1b bleibt nach Teilfehler dauerhaft migrationsunfähig

**Datei:Zeile:** `Sources/TimetrackKit/Groups/GroupModels.swift:266`.

**Problem:** Zwei unbedingte `ALTER TABLE ... ADD link_token` folgen aufeinander. Der gelesene Fluent-Migrator ruft `prepare` auf und schreibt erst danach den Migrationseintrag; er umschließt diese Schritte nicht automatisch mit einer Transaktion. MariaDB-DDL ist hier ohnehin nicht gemeinsam zurückrollbar. Es gibt weder eine Spaltenprüfung noch getrennte Migrationseinträge pro Tabelle.

**Fehlerszenario:** Das erste ALTER gelingt, das zweite scheitert oder der Prozess endet vor dem Migrationseintrag. Beim nächsten Start wird wieder das erste ALTER ausgeführt und scheitert an der vorhandenen Spalte. Ein bloßer Neustart kann das Upgrade nicht fortsetzen. Dasselbe Problem betrifft die zweistufige Rücknahme.

**Empfehlung:** Beide Schritte anhand des tatsächlichen Schemas wiederaufnehmbar gestalten oder einzeln versionieren; teilweise angewendete Vorbereitung und Rücknahme ausdrücklich auf MariaDB und SQLite prüfen. Auch den Fehler nach erfolgreichem zweiten ALTER, aber vor dem Migrationseintrag testen.

## F07 – medium – Kontoexport lässt Urlaubs-Stichtagsbestände vollständig aus

**Datei:Zeile:** `Sources/TimetrackKit/Accounts/AccountExportService.swift:137`.

**Problem:** Der Export liest Urlaubseinstellungen und Urlaubskorrekturen, aber an keiner Stelle `VacationSnapshotRecord`. Stichtagsdatum und `remainingHalfDays` fehlen sowohl als eigene Tabelle als auch in den Einstellungen. `VacationService.balance` verwendet genau diese Datensätze als Ersatz der früheren Anspruchshistorie (`PlanningServices.swift:89`). Der Manifest weist diese Auslassung nicht aus. Vertrag `/me/export` und ADR-0016 beschreiben den Export aller eigenen fachlichen Bereiche.

**Fehlerszenario:** Ein Konto setzt statt einer kompletten Historie einen Urlaubsrestbestand und exportiert vor einer Kontolöschung. Im ZIP bleiben zwar Anspruch und Korrekturen, aber der maßgebliche Anfangsrestbestand fehlt. Der vorherige Urlaubssaldo lässt sich aus dem Export nicht rekonstruieren.

**Empfehlung:** Kontoeigene Snapshots mit ID, Datum und Restbestand exportieren, im Manifest zählen und einen Test ergänzen, der den Urlaubssaldo einschließlich Snapshot aus den exportierten Werten nachvollzieht.

## F08 – medium – C3 verliert nach Teilfehler die notwendige W4-Invalidierung

**Datei:Zeile:** `Sources/TimetrackKit/AbsenceSemanticsMigrations.swift:68`.

**Problem:** `NormaliseAbsenceStatuses` sammelt betroffene Konten aus den alten Statuswerten, führt mehrere rohe UPDATEs aus und invalidiert erst danach die Zeitkonto-Checkpoints. Die Datenänderungen und die Invalidierung sind nicht in einer gemeinsamen Transaktion. Die rohen UPDATEs umgehen das Model-Middleware. Nach erfolgreicher Statusänderung kann ein erneuter Lauf das betroffene Konto nicht mehr aus den alten Statuswerten ermitteln.

**Fehlerszenario:** Während eines Upgrades mit weiterlaufender Replik steht ein W4-Checkpoint im Speicher. C3 macht einen früher geplanten Krankheitstag zu `recorded`; anschließend scheitert der Prozess vor `touch`. Beim Neustart sind die Zeilen bereits normalisiert, die Auswahl `affected` ist für dieses Konto leer. Die weiterlaufende Replik kann deshalb den alten Checkpoint weiterverwenden, während Tagesbewertungen schon den neuen Status sehen. Ohne parallel weiterlaufende Replik entfällt dieses konkrete Cache-Szenario, weil der Prozesscache neu startet.

**Empfehlung:** Den gesamten DML-Teil nach dem gegebenenfalls nötigen Spalten-ALTER atomar einschließlich `touch` ausführen. Wiederaufnahme muss alle schon normalisierten betroffenen Konten sicher invalidieren können. Unterbrechungen nach jedem UPDATE und vor/nach einzelnen `touch`-Aufrufen prüfen.

## F09 – medium – ICS liefert ausgeschaltete Abwesenheitsinhalte weiter aus

**Datei:Zeile:** `Sources/TimetrackKit/CalendarFeeds.swift:258`.

**Problem:** Reguläre Abwesenheiten werden nur bei `planning && options.contains("absences")` ausgegeben. Der neue C3-Zweig für ausdrückliche Tagesmarkierungen prüft dagegen nur die Feed-Option. `DayService.snapshot` liefert `preferences` auch bei ausgeschaltetem Planning-Modul. Dadurch erscheinen explizite Markierungen für Urlaub, Krankheit und Freistellung weiterhin im öffentlichen Token-Feed. Der OpenAPI-Vertrag zu `/ics/{file}` verspricht ausdrücklich, dass Abwesenheiten bei abgeschaltetem `planning` entfallen.

**Fehlerszenario:** Ein bestehendes Kalenderabo enthält `absences`. Das Konto oder der Betreiber schaltet Planning aus. Neue Abrufe entfernen reguläre Abwesenheitsdatensätze, geben aber weiterhin Krankheitstage aus ausdrücklichen Tagesmarkierungen aus. Ein Nutzer kann sich daher nicht auf die beschriebene Modulsperre für diese Inhalte verlassen.

**Empfehlung:** Die Modulsperre auch auf den Tagesmarkierungszweig anwenden und Abwesenheiten aus beiden Speicherwegen gemeinsam testen. Falls Tagesmarkierungen bewusst unabhängig bleiben sollen, muss dies als explizite Vertragsentscheidung mit verständlicher Nutzerinformation erfolgen.

## F10 – medium – Jugendprofil kann eine Blockwoche mit mehr als 40 Stunden gutschreiben

**Datei:Zeile:** `Sources/TimetrackKit/TimeEngine/PreparedEvaluation.swift:160`; `Sources/TimetrackKit/TimeEngine/TimeEngine.swift:99`.

**Problem:** `blockWeek` gilt für die komplette Woche, sobald mindestens fünf Schultage und 25 Unterrichtsstunden vorliegen. Anschließend erhält jeder Tag mit Schulsegment acht Stunden (`blockWeekCreditSeconds / blockWeekDays`), ohne die Anzahl gutgeschriebener Tage auf fünf oder die Wochengutschrift auf 40 Stunden zu begrenzen. Die Tagesregel „ein voller Schultag pro Woche“ wird im Blockwochenzweig übersprungen. ADR-0028 spezifiziert ausdrücklich fünf Schultage mit je acht Stunden.

**Fehlerszenario:** Sechs Tage derselben Woche haben jeweils ein Schulsegment und fünf erfasste Unterrichtsstunden. Die Schwelle wird erreicht und alle sechs Tage erhalten acht Stunden: insgesamt 48 statt der festgelegten 40 Stunden Blockwochengutschrift. Eine Wochenwarnung über 40 Stunden korrigiert den Zeitkontosaldo nicht. Dies ist ein Abgleich gegen die beschlossene Produktregel, keine eigenständige juristische Bewertung.

**Empfehlung:** Eine eindeutige Auswahl der fünf Blockschultage bzw. eine explizite Behandlung zusätzlicher Schultage definieren und die Gesamtgutschrift entsprechend begrenzen. Fünf-, Sechs- und Sieben-Tage-Wochen einschließlich Modellwechseln testen.

## F11 – low – Wochenübersicht und Statistik zählen Urlaub an halben Betriebstagen doppelt so hoch

**Datei:Zeile:** `Sources/TimetrackKit/TimeWeek.swift:207`; `Sources/TimetrackKit/TimeStatistics.swift:176`.

**Problem:** Die Urlaubszähler verwenden ausschließlich die gespeicherten Halbtagsflags der Abwesenheit. Die N4-Regel, nach der ein halber Betriebstag höchstens einen halben Urlaubstag verbraucht, bleibt unberücksichtigt. `VacationEngine.count` berücksichtigt sie dagegen korrekt (`VacationEngine.swift:38`).

**Fehlerszenario:** Ein genehmigter Urlaub umfasst einen als `half` konfigurierten 24.12., ohne explizites Halbtagsflag. Das Urlaubskonto zieht 0,5 Tage ab, `TimeWeek.summary.vacationDays` und die Statistik weisen 1 Tag aus. Über größere Zeiträume widersprechen sich so die dargestellten Verbrauchssummen.

**Empfehlung:** Dieselbe effektive Tagesverbrauchsberechnung wie im Urlaubskonto für Woche und Statistik verwenden; nicht nur das ursprüngliche Eingabeflag auswerten. N4-Fälle mit ganzen und halben Abwesenheiten über alle Ansichten vergleichen.

## Prüfumfang und verbleibende Verifikation

Gelesen wurden Projektvorgaben, Konzept, Architektur, Umsetzungsplan, ADRs und vorheriger Review sowie insbesondere die Implementierungen für Passkeys/Sitzung/CSRF/Recovery, OIDC-Start/Callback/Registrierung, OAuth-Consent/Tokens, MCP-Authentifizierung und Tool-Transaktionen, account-scoped Zeit-/Planungsdienste und Freigaben, Kalenderfeeds und Triggerlinks, öffentliche Gruppen mit Besitzer-/Teilnehmerrechten, Kontoexport/-löschung, Speicher/Anhänge, Importjobs, Push-Zustellung/APNs und Job-Lease. Die genannten Migrationen g1b, W4, C3 und P13 wurden im tatsächlichen Code geprüft. OpenAPI wurde gezielt für die betroffenen Endpunkte und Datenformen abgeglichen. Eine eigenständige globale Suchroute wurde bei der Quelltextsuche in den geprüften Adaptern nicht gefunden; Listen-/Objektzugriffe wurden an ihren Kontofiltern geprüft.

Die äußere Tagesrundung verwendet im gelesenen Engine-Pfad den ersten und letzten zählenden Abschnitt; innere Lücken werden nicht pauschal aufgefüllt. Nachtschichten bleiben dem Beginn-Arbeitstag zugeordnet. W4 verwendet kontobezogene Cache-Schlüssel und Datenbank-Change-Marks. P13 erhält Legacy-Felder bei der Migration, prüft Blockreihenfolge und schwärzt Orte/Notizen in Planfreigaben. Gruppen-Objektzugriffe prüfen Besitzer bzw. Link und untergeordnete IDs; Bearbeitungsschlüssel werden nicht öffentlich ausgegeben. Diese Beobachtungen sind begrenzte positive Prüfresultate, keine vollständigen Korrektheitsbeweise.

Offen bleiben Laufzeitreproduktionen der elf Befunde, die volle SQLite-/MariaDB-Suite und gezielte Tests von Unterbrechungen, Wiederaufnahme und kontrolliert angehaltenen konkurrierenden Anfragen. Eine vollständige Ausführung aller Vertragstests sowie reale Browser-/Apple-/Push-/OIDC-Provider-Prüfungen erfolgten nicht. Vorhandene Testzahlen aus STATUS.md wurden nicht als selbst ausgeführte Tests übernommen.

Nächster konkreter Schritt: F01 und F02 zuerst beheben und reproduzierbare Regressionen ergänzen; danach Credential-Widerruf, Recovery-Orakel, öffentliche Fehler-Ratenlimits und Migrationsteilfehler gezielt auf beiden Datenbanktreibern testen. Dieser Review enthält keine Implementierungsänderungen.

## Abgleich gegen den aktuellen Code (02.11.2026)

Abgleich durch Claude gegen `main` (Vertrag 0.41.0, nach SEC-A/C/D) und `docs/reviews/2026-11-01-security-review.md`, durch Code-Lesen; es wurden keine Tests ausgeführt und kein Quellcode geändert. Das Codex-Review prüfte Vertrag 0.39.0, also vor SEC-A/C/D. Zeilenangaben beziehen sich auf den heutigen Stand.

| Befund | Schwere | Status | Beleg (Datei:Zeile) |
| --- | --- | --- | --- |
| F01 Überlauf bei `offset + limit` | high | **BEHOBEN (CX-A, 7e64cb7)**: zentrale `Pagination.range` (offset 0...100000, überlaufsicher) für stornierte Segmente, Zeitkonto-Anpassungen und Konten-Admin-Liste (REST und MCP); weitere Listen haben keinen `offset`; Tests `CXAReviewTests` | `Sources/TimetrackKit/Pagination.swift` |
| F02 Credentials nach Sitzungswiderruf | high | **BEHOBEN (CX-A, 7e64cb7)**: `createToken`, `decide`, `revokeGrant` authentifizieren in der Transaktion erneut; Tests mit widerrufener Sitzung | `Sources/TimetrackKit/OAuth/OAuthCredentials.swift`, `OAuthService.swift` |
| F03 MCP mit widerrufenem Principal | medium | **BEHOBEN (CX-A, 7e64cb7)**: Token-Hash im Principal, `revalidate` unter dem Lock (Widerruf, Ablauf, aktuelle Scopes); Tests | `Sources/TimetrackKit/MCP/MCPTools.swift`, `OAuth/BearerPrincipal.swift` |
| F04 Recovery-Orakel (Zähler, SMTP-Latenz) | medium | Größtenteils durch SEC-A überholt (SEC-03/SEC-04): Sperre je getipptem Handle, identisch für unbekannte Handles; Versand nach der Antwort über Outbox. Restpunkt: der Handle-Zähler in `limitRequest(.recovery)` bleibt an `accountId` gebunden, wirkt aber nur noch als Zusatz zur Sperre (geringes Restrisiko) | `Sources/TimetrackKit/RecoveryService.swift:158-160,186,191-193`, `Sources/TimetrackKit/AuthSupport.swift:131-134`, `docs/reviews/2026-11-01-security-review.md` SEC-03/04 |
| F05 Gruppen-Schreibzugriffe umgehen Limits bei Fachfehlern | medium | NEU, offen, bestätigt (nur `edit_secret_invalid` wird nachgezählt; SEC-11 betraf die Anmelde-Zähler, nicht diesen Pfad) | `Sources/TimetrackKit/Groups/GroupRoutes.swift:66-90` |
| F06 g1b nicht wiederaufnehmbar | medium | NEU, bestätigt, praktisch gering (Migration läuft nur einmal; betrifft Teilfehler beim ersten Lauf) | `Sources/TimetrackKit/Groups/GroupModels.swift:263-272` |
| F07 Export ohne Urlaubs-Stichtagsbestände | medium | NEU, offen, bestätigt (kein `VacationSnapshotRecord` im Export; Löschung und Saldo kennen ihn) | `Sources/TimetrackKit/Accounts/AccountExportService.swift:132-143` (fehlend), `Sources/TimetrackKit/PlanningServices.swift:89`, `Sources/TimetrackKit/Accounts/AccountEraser.swift:85` |
| F08 C3-Migration ohne atomare Invalidierung | medium | NEU, bestätigt, praktisch gering (Einmalmigration; Cache-Szenario nur mit weiterlaufender Replik) | `Sources/TimetrackKit/AbsenceSemanticsMigrations.swift:63-79` |
| F09 ICS gibt Tagesmarkierungen bei abgeschaltetem Planning aus | medium | NEU, offen, bestätigt (`planning` fehlt in der Bedingung; Snapshot liefert `preferences` auch bei `planningEnabled: false`) | `Sources/TimetrackKit/CalendarFeeds.swift:258` (Vergleich Zeile 242), `Sources/TimetrackKit/TimeEvaluationServices.swift:47` |
| F10 Blockwoche über 40 Stunden | medium | NEU, offen, bestätigt (jeder Schultag der Woche erhält 8 h, keine Begrenzung auf fünf Tage; nur bei mehr als fünf Schultagen, also Randfall) | `Sources/TimetrackKit/TimeEngine/PreparedEvaluation.swift:147-160`, `Sources/TimetrackKit/TimeEngine/TimeEngine.swift:98-99`, ADR-0028 |
| F11 Urlaubszähler Woche/Statistik ohne halben Betriebstag | low | NEU, offen, bestätigt (nur Eingabe-Halbtagsflag) | `Sources/TimetrackKit/TimeWeek.swift:207-209`, `Sources/TimetrackKit/TimeStatistics.swift:176`, Vergleich `Sources/TimetrackKit/VacationEngine/VacationEngine.swift:38` |

Zusammenfassung: 11 Befunde (2 high, 8 medium, 1 low). Stand nach CX-A: F01, F02, F03 behoben (7e64cb7). Zuvor bestätigt und offen: 10 (F01, F02, F03, F05, F07, F09, F10, F11 sowie F06/F08 als geringes Restrisiko bereits angewendeter Migrationen). Durch SEC-A weitgehend behoben: 1 (F04). Falsch positiv: 0. Doppelt zum Sicherheitsreview: 0 (nur F04 überschneidet sich fachlich mit SEC-03/SEC-04). Keine Befunde des Sicherheitsreviews (SEC-01 bis SEC-17) wurden hier widerlegt. Die Befunde sind nicht umgesetzt; ein Fix-Paket ist nicht angelegt.


## Umsetzung CX-B (02.11.2026, Commit 52cd8e9, Paket-ID `CX-B`)

Alle sechs Befunde waren am Code bestätigt (kein Falsch-Positiv). Keine Vertragsänderung (Vertrag bleibt 0.41.0).

| Befund | Status | Umsetzung und Test |
| --- | --- | --- |
| F05 | behoben (52cd8e9) | `GroupRoutes.write` merkt sich die in der Transaktion geschriebenen Zähler (`grp-ip`, `grp-write-ip`, `grp-write-tok`) und schreibt sie bei jedem `APIError` (Fachfehler) nach dem Rollback erneut außerhalb der Transaktion; `edit_secret_invalid` zählt zusätzlich den Fehlversuch-Zähler. Test `testG1FailedWritesStillCountAgainstTheRateLimits`. |
| F06 | behoben (52cd8e9) | `g1b.add_group_link_tokens` legt je Tabelle die Spalte nur an, wenn sie fehlt (`columnExists`). Test `testG1bMigrationIsResumable` (SQLite: vollständiger Zustand; MariaDB mit `G1_ON_MARIADB=1`: Teilzustand durch Löschen einer Spalte). |
| F07 | behoben (52cd8e9) | Kontoexport enthält `vacation-snapshots.json` (id, date, remainingHalfDays) und `counts["vacation-snapshots"]`. Löschung kannte den Datensatz schon. Test im Export-/Löschszenario in `AccountAdminTests`. Es gibt keinen Importer für das Exportformat, daher keine Importänderung; der Vertragstext nennt `vacation-*` bereits. |
| F08 | behoben (52cd8e9) | Datenschritte und `TimeChangeTracker.touch` von `c3.normalise_absence_statuses` laufen in einer Transaktion (Spalte `legacy_status` bleibt vorab, DDL ist auf MariaDB nicht transaktional). Nach Fehler bleibt alles unverändert, der Wiederholungslauf findet alle betroffenen Konten. Test `testC3NormalisationIsAtomicAndRepeatable`. |
| F09 | behoben (52cd8e9) | Der Tagesmarkierungszweig des ICS-Feeds verlangt `planning` wie die Abwesenheiten. Test `testCalendarFeedHidesDayMarksWithPlanningOff`. |
| F10 | **Entscheidung offen** | Nur Charakterisierungstest `testBlockSchoolWeekWithSixSchoolDaysCharacterization` (6 Schultage = 48 h). Siehe unten. |
| F11 | behoben (52cd8e9) | Gemeinsame Regel `TimeWeekDayDTO.vacationDays` (halber Abwesenheitstag oder halber Betriebstag zählt 0,5, wie `VacationEngine.count`); Wochenübersicht und Statistik nutzen sie, die Statistik reicht nun auch `companyDayTreatment` an das DTO weiter. Test `testHalfCompanyDayCountsHalfVacationDayInWeekAndStatistics`. |

**F10, Entscheidungsbedarf:** ADR-0028 verlangt „fünf Schultage mit je acht Stunden“, der Code vergibt acht Stunden an jeden Tag der Mo-So-Woche mit Schulsegment. Das Gesetz begrenzt die Anrechnung der Blockwoche auf 40 Stunden. Offen ist, welche Tage gutgeschrieben werden, wenn es mehr als fünf Schultage gibt (die ersten fünf in Kalenderreihenfolge, Arbeitstage des Modells zuerst, oder der Nutzer wählt) und was am überzähligen Schultag gilt (keine Gutschrift, Sollstunden unverändert). Solange das nicht entschieden ist, bleibt das Verhalten unverändert. Der Charakterisierungstest schlägt bei einer Änderung bewusst an.
