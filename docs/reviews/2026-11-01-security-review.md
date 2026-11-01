# Security-Review Backend (01.11.2026)

Gegenstand: Backend-Repository auf `main` (Stand `fd2f3ae`), rein lokale, schreibgeschützte Quellcode-Prüfung durch einen Claude-Agent (kein Codex, kein Code an externe Dienste, keine Tests und keine Netzwerkzugriffe ausgeführt, `npm audit` bewusst nicht gelaufen, weil es Paketnamen an die Registry sendet). Es wurde kein Code geändert.

Bedrohungsmodell: öffentliches Repository, öffentlich erreichbarer Server hinter Reverse Proxy, mehrere Konten, Registrierung nur per Einladung. Angreifer: (a) anonym im Netz, (b) angemeldetes Mitglied gegen andere Konten, (c) Besitzer eines gestohlenen Sitzungscookies oder Tokens.

Methode: Routen, Middleware, Dienste, Migrationen, Konfiguration, Dockerfile, Compose/Swarm, Skripte und Workflows gelesen; jede Aussage unter „Befunde“ wurde im Code nachvollzogen (Datei:Zeile). Was nur vermutet ist, steht getrennt unter „Hypothesen“. Zeilennummern beziehen sich auf `fd2f3ae` und `Sources/TimetrackKit/` (Kurzform ohne Präfix).

Einordnung: CVSS-3.1-artig (Basiswert grob geschätzt, keine amtliche Berechnung). Kritisch 9.0 bis 10, Hoch 7.0 bis 8.9, Mittel 4.0 bis 6.9, Niedrig 0.1 bis 3.9, Info ohne Wert.

## Zusammenfassung

| Schwere | Anzahl | IDs |
| --- | --- | --- |
| Kritisch | 0 | |
| Hoch | 0 | |
| Mittel | 4 | SEC-01 bis SEC-04 |
| Niedrig | 9 | SEC-05 bis SEC-13 |
| Info | 4 | SEC-14 bis SEC-17 |

Keine ausnutzbare Lücke mit hohem Schweregrad gefunden. Kontentrennung (IDOR), SQL, Pfad-Traversal, SSRF der Push-Zustellung, XLSX-Import, Formel-Injektion, OAuth/OIDC-Protokollhärtung und Token-Speicherung (nur Hashes) halten der Prüfung stand (Details unter „Negativbefunde“). Die Mittel-Befunde betreffen Wiederherstellung/Sitzungen (SEC-02 bis SEC-04) und die Vertrauensannahme für Proxy-Header im Swarm-Betrieb (SEC-01).

## Befunde

### SEC-01 Mittel (5.3, `AV:N/AC:L/PR:N/UI:N/C:N/I:L/A:N`, bedingt): Swarm-Routing-Mesh macht das gesamte Internet zum „vertrauenswürdigen Proxy“

- Ort: `TrustedProxies.swift:139-160` (`resolve`), `deploy/swarm/stack.yaml` (Abschnitt `ports`, `mode: ingress`), `docs/BETRIEB.md:228`, `docs/DEPLOYMENT.md:116`.
- Beschreibung: Die Doku verlangt, das Subnetz des `ingress`-Netzes in `TRUSTED_PROXY_CIDRS` einzutragen. Hinter dem Routing Mesh erscheint jede Verbindung, die den veröffentlichten Port eines Knotens erreicht, mit einer Adresse aus diesem Netz (Quell-Adress-Umsetzung), unabhängig davon, ob sie vom Proxy oder direkt aus dem Internet kommt. Ist der Port nicht per Firewall auf den Proxy beschränkt, wird `X-Forwarded-For` jedes Angreifers akzeptiert. Die Stack-Datei weist nur im Kommentar auf die Firewall hin; `docs/BETRIEB.md` warnt vor „zu weitem Netz“, nennt aber den Routing-Mesh-Fall nicht ausdrücklich als „vertraut das ganze Internet, wenn der Port offen ist“.
- Szenario: Ein Angreifer sendet Anfragen direkt an die Knoten-Adresse und setzt pro Anfrage einen anderen Wert im Header. Alle IP-basierten Zähler (`AuthRateLimitMiddleware`, Gruppen-Zähler `grp-*`, Auslöse-Links `trigger-miss`, ICS-Zähler, OAuth/OIDC) werden umgangen. Das Handle-Limit (15 je 5 Minuten) bleibt bestehen und begrenzt Rateversuche gegen Konten weiter.
- Empfehlung: In Doku und `stack.yaml` fett als Pflicht formulieren: Port ausschließlich vom Proxy erreichbar (Knoten-Firewall) oder Proxy-Adresse als `/32` eintragen; Prüfschritt „direkter Aufruf mit gefälschtem Header darf den Zähler nicht zurücksetzen“ ergänzen. Optional Startwarnung, wenn ein CIDR breiter als `/16` ist.
- Status: offen (Konfiguration und Doku, kein Codefehler).

### SEC-02 Mittel (4.9, `AV:N/AC:H/PR:N/UI:N/C:H/I:L/A:N`): Wiederherstellung und Passkey-Widerruf beenden bestehende Sitzungen, OAuth-Grants und Tokens nicht

- Ort: `RecoveryService.swift:177-215` (`recoveryComplete`), `WebAuthnService.swift:110-127` (`addPasskey`, Beförderung der Wiederherstellungssitzung), `WebAuthnService.swift:129-145` (`changePasskey`, Widerruf).
- Beschreibung: Wer die Wiederherstellung durchläuft, bekommt eine Wiederherstellungssitzung und kann danach einen neuen Passkey anlegen. Dabei werden weder andere Sitzungen des Kontos noch OAuth-Grants, persönliche API-Tokens, Auslöse-Links, Kalender-Abos oder Gerätetokens widerrufen. Der Widerruf eines Passkeys beendet ebenfalls keine Sitzung. Der Nutzer muss „Andere Sitzungen beenden“ (`DELETE /me/sessions`) selbst auslösen; es gibt auch keine Benachrichtigung über eine abgeschlossene Wiederherstellung.
- Szenario: Ein Angreifer hat ein Sitzungscookie oder einen MCP-Token erbeutet. Der Besitzer bemerkt es, wählt „Passkey verloren“, stellt wieder her und legt einen neuen Passkey an. Die Sitzung und der Token des Angreifers bleiben bis zum Ablauf (Standard 30 Tage; Stack 14 Tage; Tokens bis 365 Tage) nutzbar.
- Empfehlung: Beim Abschluss der Wiederherstellung (und optional beim Passkey-Widerruf) `AccountEraser.revokeCredentials(of:)`-ähnlich alle anderen Sitzungen, OAuth-Grants und API-Tokens beenden (Auslöse-Links und Feeds mindestens anbieten); E-Mail-Hinweis „Wiederherstellung abgeschlossen“ an die bestätigte Adresse.
- Status: offen.

### SEC-03 Mittel (5.9 bei aktivem Rückfallpasswort, `AV:N/AC:H/PR:N/UI:N/C:H/I:H/A:N`): Online-Raten des Rückfallpassworts nur durch Handle-Zähler begrenzt, ohne Stärkeprüfung und ohne Benachrichtigung

- Ort: `RecoveryService.swift:144-215`, `AuthSupport.swift:133-145` (`limited`, Handle-Limit 15 je 300 s), `RecoveryService.swift:50-66` (Mindestlänge 12, sonst keine Prüfung).
- Beschreibung: Je Wiederherstellungsvorgang sind 5 Versuche erlaubt, neue Vorgänge sind über `recovery/start` unbegrenzt startbar, begrenzt nur durch den Handle-Zähler (15 Ereignisse je 5 Minuten, unabhängig von der IP). Das ergibt grob 2.900 Rateversuche je Tag und Konto. Das Passwort braucht nur 12 Zeichen ohne Qualitätsprüfung. Ein Treffer liefert eine Wiederherstellungssitzung und damit die Möglichkeit, einen Passkey anzulegen (Kontoübernahme). Argon2id (64 MiB, 3 Durchläufe) und gleichartige KDF-Arbeit für unbekannte Konten (kein Zeitorakel) sind gut; es fehlt eine Eskalation (Sperre mit steigender Dauer) und eine Meldung an den Besitzer.
- Szenario: Ein Angreifer kennt ein Handle (Handles sind Anzeigenamen) und probiert eine Liste häufiger 12-Zeichen-Passwörter über Wochen durch.
- Empfehlung: Wörterbuch-/Entropieprüfung beim Setzen (zum Beispiel Blocklist häufiger Passwörter, Mindestentropie oder 16 Zeichen), exponentielle Sperre je Konto nach Fehlversuchen, Benachrichtigung bei fehlgeschlagenen und erfolgreichen Wiederherstellungen, im UI Hinweis „Rückfallpasswort nur als lange Zufallsfolge“. Alternativ Rückfallpasswort nur zusammen mit Recovery-Codes zulassen.
- Status: offen.

### SEC-04 Mittel (4.3, `AV:N/AC:L/PR:N/UI:N/C:N/I:N/A:L` plus Datenschutz): Wiederherstellung per E-Mail: Mail-Flut gegen Dritte und Zeitorakel

- Ort: `RecoveryService.swift:144-175`.
- Beschreibung: `recovery/start` mit Methode `email` sendet für Konten mit aktiver E-Mail-Wiederherstellung synchron (`try? await mailSender.sendCode`, Zeile 174) einen Code an die hinterlegte Adresse; für unbekannte Konten oder Konten ohne aktive Wiederherstellung geschieht nichts. Zwei Folgen: (1) Mail-Flut: bis zu 15 Mails je 5 Minuten je Handle (Handle-Zähler), also rund 4.300 Mails je Tag an das Opfer, ohne Cooldown je Konto; (2) Zeitorakel: Der Antwortzeit-Unterschied (SMTP-Roundtrip) verrät, ob ein Handle ein Konto mit aktiver E-Mail-Wiederherstellung ist, obwohl die Antwort sonst absichtlich einheitlich ist (Anti-Enumeration).
- Empfehlung: Cooldown und Tageslimit je Konto (zum Beispiel 1 je Minute, 5 je Stunde); Versand asynchron nach der Antwort (Hintergrundaufgabe) oder Antwortzeit auffüllen.
- Status: offen.

### SEC-05 Niedrig (3.1): Keine Sicherheitsheader für PWA und die meisten API-Antworten vom Backend

- Ort: `PWAStaticMiddleware.swift:20-52` (nur `nosniff` und Cache-Control), `Configure.swift:70-76` (keine zentrale Header-Middleware), vereinzelt `Referrer-Policy` an Token-Routen (`TriggerLinks.swift:244`, `CalendarFeeds.swift:401`, `Groups/GroupSupport.swift:95-100`). Die PWA-Hülle enthält kein CSP-Meta (`deploy/pwa-static/index.html`).
- Beschreibung: Die PWA wird ohne `Content-Security-Policy`, `frame-ancestors`/`X-Frame-Options`, `Referrer-Policy` und `Permissions-Policy` ausgeliefert, HSTS wird nur dem Proxy überlassen (`docs/DEPLOYMENT.md:320`). Tatsächliche Ausnutzung wird durch `SameSite=Lax` (Cookies gehen in fremden Frames nicht mit) und Svelte-Escaping abgemildert; bei einer XSS-Lücke in der PWA gäbe es keine zweite Verteidigungslinie. Der Einladungslink `/invite/<token>` und `/g/<token>` (Gruppen: Header gesetzt) tragen das Geheimnis im Pfad; für `/invite/` wird keine `Referrer-Policy: no-referrer` gesendet.
- Empfehlung: Zentrale Middleware oder Proxy-Vorgabe: CSP (`default-src 'self'`, `frame-ancestors 'none'`, `base-uri 'none'`, `form-action 'self'`), `Referrer-Policy: no-referrer`, `X-Content-Type-Options`, HSTS im Proxy-Beispiel der Doku.
- Status: offen.

### SEC-06 Niedrig (3.5, `AV:N/AC:L/PR:L/UI:N/C:N/I:N/A:L`): Kein Speicherkontingent je Konto

- Ort: `Storage/StorageRoutes.swift:19-31`, `Storage/StorageService.swift:174-205`, `Storage/StorageModels.swift:8-15`.
- Beschreibung: Je Datei gilt ein Limit (Standard 10 MiB, hart 64 MiB), aber weder Anzahl noch Gesamtgröße je Konto sind begrenzt; Uploads sind nicht ratenbegrenzt. Bei der Standardregel „alles in die Datenbank“ kann ein Mitglied die Datenbank füllen. Jede Anfrage puffert bis zur Grenze im Speicher.
- Empfehlung: Kontingent (Bytes und Anzahl) je Konto, konfigurierbar; Upload-Rate je Konto.
- Status: offen.

### SEC-07 Niedrig (3.1): Kontoexport ohne frische Anmeldung, Ratenbegrenzung und Speichergrenze

- Ort: `Accounts/AccountRoutes.swift:29-39`, `Accounts/AccountExportService.swift`.
- Beschreibung: `GET /me/export` erzeugt das gesamte Archiv (inklusive aller Dateien) im Speicher und verlangt nur eine normale Sitzung. Ein gestohlenes Cookie kann alle Daten in einem Schritt abziehen; wiederholte Aufrufe belasten den Speicher.
- Empfehlung: `context.fresh()` verlangen, Aufruf-Limit (zum Beispiel 3 je Stunde), Streaming oder Größengrenze.
- Status: offen.

### SEC-08 Niedrig (3.1): Der Server versendet Bestätigungs-Mails an beliebige Adressen

- Ort: `Accounts/ProfileService.swift:44-56`, `Routes.swift:56` (`PUT /me/profile/email`), `SessionService.swift:99-102` (Zähler 60 je 5 Minuten je IP).
- Beschreibung: Ein Mitglied mit frischer Sitzung kann Codes an beliebige Adressen senden lassen (fester Text, Absender des Betreibers). Es gibt kein Limit je Konto; das IP-Limit ist wegen SEC-01 unter Umständen umgehbar. Missbrauch belastet die Absender-Reputation.
- Empfehlung: Limit je Konto (zum Beispiel 5 je Stunde und 20 je Tag) und je Zieladresse.
- Status: offen.

### SEC-09 Niedrig (2.7, setzt Administratorrechte voraus): Administrator-konfigurierter S3-Endpunkt und lokaler Pfad ohne Zielprüfung

- Ort: `Storage/StorageService.swift:133-137` (`validEndpoint`), `Storage/S3Client.swift:113-120` (verwendet den Vapor-Client, der Weiterleitungen folgt), `Storage/StorageService.swift:359-371` (`validateRoot`).
- Beschreibung: Jeder `http(s)`-Host (auch Loopback, Link-Local, Metadaten-Adressen) ist als Endpunkt zulässig; der Pfad `localPath` darf jedes beschreibbare Verzeichnis außerhalb von `/` sein. Das ist die Aufgabe des Betreiber-Admins, aber kein Schutz gegen ein kompromittiertes Admin-Konto (SSRF in das interne Netz, Dateilesen/-schreiben außerhalb des Datenverzeichnisses).
- Empfehlung: Optionale Allow-List (`STORAGE_S3_ALLOWED_HOSTS`, `STORAGE_LOCAL_ROOT`) per Umgebungsvariable; Weiterleitungen für den S3-Client abschalten; Schreiben nur unterhalb eines festen Wurzelverzeichnisses.
- Status: offen (Akzeptanz möglich, dann in `docs/BETRIEB.md` als Betreiberrisiko vermerken).

### SEC-10 Niedrig (2.6): Teilnehmerlinks der Gruppen stehen zusätzlich im Klartext in der Datenbank

- Ort: `Groups/GroupModels.swift:6,33,91` (`link_token`), `Groups/GroupPolls.swift:219,278`, `docs/decisions/ADR-0033-gruppenmodul.md` (Nachtrag g1b).
- Beschreibung: Entscheidung g1b (Besitzer sieht den Link wieder) hebt den Hash-Schutz auf: ein Datenbank- oder Backup-Leck gibt alle offenen Umfrage- und Bestelllinks frei (Lesen der Teilnehmernamen, Abstimmen). Bewusste, dokumentierte Abwägung; das Risiko ist auf anonyme Teilnahme begrenzt.
- Empfehlung: Mit `STORAGE_SECRET_KEY` (SecretBox) verschlüsseln statt Klartext; Backups entsprechend behandeln.
- Status: offen (bewusst akzeptiert, Härtung möglich).

### SEC-11 Niedrig (3.1, `A:L`): Zähler lassen sich von Dritten ausreizen (Sperre Unbeteiligter) und laufen vor der Prüfung in der globalen Sperre

- Ort: `OAuth/OAuthTokenLimiter.swift:11` (Schlüssel `client:<client_id>`, 120 je 5 Minuten, global je Client), `RecoveryService.swift`/`AuthSupport.swift:136` (Handle-Zähler 15), `Groups/GroupRoutes.swift:54,68` (`grp-miss` je IP), `TriggerLinks.swift:152-170`, `CalendarFeeds.swift:363-390`.
- Beschreibung: (a) Wer eine `client_id` kennt, kann den Token-Endpunkt dieses Clients für andere Nutzer sperren, weil der Zähler nicht an das Client-Geheimnis oder eine Sitzung gebunden ist (Public Client). (b) Handle-Zähler sperren das Opfer für Wiederherstellung (nicht für Passkey-Login, der nach Credential-ID zählt). (c) Alle unauthentifizierten Zähler-Pfade schreiben in der serialisierten Transaktion mit der globalen Sperre `auth_lock` (`AuthSupport.swift:95-98`), sodass eine Flut von Treffern/Fehlversuchen von vielen Adressen aus die Schreibdurchsatz-Obergrenze aller Konten drückt; ohne korrekt gesetzte `TRUSTED_PROXY_CIDRS` teilen sich alle Clients einen Zähler.
- Empfehlung: Zähler und Verwerfen offensichtlich ungültiger Eingaben vor `auth_lock` (zum Beispiel prozesslokaler Token-Bucket für anonyme Pfade); Sperren je (Client, IP) statt je Client.
- Status: offen.

### SEC-12 Niedrig (3.1): Offene Client-Registrierung (DCR) erlaubt Einwilligungs-Phishing und Tabellenwachstum

- Ort: `OAuth/OAuthService.swift:65-91`, `OAuth/OAuthService.swift:162-170` (`consent`).
- Beschreibung: Jeder anonyme Aufrufer kann Clients mit frei wählbarem Anzeigenamen registrieren (20 je 5 Minuten je IP). Die Zustimmungsseite zeigt Clientnamen und Host der Weiterleitung; ein Angreifer kann sich als bekannter Dienst benennen und per Link zur Zustimmung bewegen. Bei Zustimmung gehen Code und Token an den Host des Angreifers (Umfang laut gewählten Scopes: Zeiten, Abwesenheiten, Berichtsheft, Schreibzugriffe). Die Registrierung bleibt bis zu 30 Tage in der Tabelle, bis Aufräumen greift; unbenutzte Clients werden nur in 50er-Schritten bei neuen Registrierungen entfernt.
- Empfehlung: Auf der Zustimmungsseite Redirect-Host hervorheben, „nicht verifizierter Client“ kennzeichnen und Datum der Registrierung zeigen; Scopes standardmäßig nur lesend vorbelegen; Aufräumen in `MaintenanceService`.
- Status: offen.

### SEC-13 Niedrig (2.0): Produktions-Compose veröffentlicht standardmäßig auf allen Schnittstellen; Secret-Dateien 0644

- Ort: `deploy/compose/compose.yaml:44-46` (`BIND_ADDR:-0.0.0.0`), `deploy/compose/init-secrets.sh` (`chmod 644`, Verzeichnis 0700).
- Beschreibung: Das Backend lauscht ohne TLS auf allen Schnittstellen des Hosts, wenn `BIND_ADDR` nicht gesetzt ist; Klartext-HTTP kann direkt erreichbar sein. Secrets sind für den Container-Benutzer lesbar (bewusst, durch Verzeichnisrechte 0700 abgesichert).
- Empfehlung: Standard `127.0.0.1`; Hinweis, dass bei `0.0.0.0` der Port zu firewallen ist.
- Status: offen.

### SEC-14 Info: Lieferkette und Pipeline

- Ort: `Package.swift:14-16`, `Package.resolved`, `.github/workflows/*.yml`.
- `Argon2Swift` hängt am Zweig `main`, dessen C-Unterpaket `phc-winner-argon2` am Zweig `master` (festgelegt über Revision in `Package.resolved`; ein `swift package update` zieht ungeprüft nach), `webauthn-swift` ist `1.0.0-beta.1`. Actions sind an Tags (`@v4`), nicht an Commit-SHAs gepinnt. Der Docker-Workflow baut zusätzlich zyklisch die PWA von `main` des Schwester-Repositorys ins Image (Vertrauensgrenze: Vertrauen in das PWA-Repository, kein CI-Gate dort). Berechtigungen sind minimal (`contents: read`, `packages: write`/`contents: write` nur in den Jobs, die es brauchen); Eingaben aus Events fließen nur über `env` oder bereinigte Werte (`tr -c 'A-Za-z0-9._-'`) in Skripte; Pull-Request-Läufe haben keinen Schreibzugriff auf die Registry.
- GitHub meldet beim Push 15 offene Dependabot-Warnungen (5 hoch, 8 mittel, 2 niedrig laut Alert-Liste, Stand heute); alle betreffen ausschließlich `site/package-lock.json` (Dokumentationsseite: `vite`, `undici`, `esbuild`, `minimatch`, `@faker-js/faker`, Entwicklungs-/Build-Abhängigkeiten, kein Laufzeitbestandteil des Backends oder der Images). Keine SwiftPM-Warnung. Einzelne Aktualisierung ohne Hauptversionssprung bleibt offen.
- Empfehlung: Revisionen als `.package(..., revision:)` festlegen oder Fork mit Tag nutzen; Actions per SHA pinnen (Dependabot hält sie aktuell); Hinweis in `docs/CI.md`.
- Status: offen (Info).

### SEC-15 Info: Sitzungsdauer und Cookie-Härtung

- Ort: `Configuration.swift:114` (Standard 720 Stunden, absolut, kein Leerlauf-Timeout), `SessionService.swift:48-50` (Cookie `tt_session`, `HttpOnly`, `SameSite=Lax`, `Secure` nur bei HTTPS-Basis-URL, kein `__Host-`-Präfix).
- Empfehlung: Leerlauf-Timeout (zum Beispiel 14 Tage) und Präfix `__Host-` für die Produktion; Standardwert im Code an den Stack (336 Stunden) angleichen.
- Status: offen (Info).

### SEC-16 Info: Unbekannte Fehler werden als 500 beantwortet, aber nicht protokolliert

- Ort: `AuthSupport.swift:36` (`APIErrorMiddleware`: unbekannter Fehlertyp wird zu `500 not_ready` ohne Log).
- Beschreibung: Gut für die Geheimhaltung, schlecht für Erkennung und Betrieb: Angriffsversuche, die Serverfehler auslösen, sind im Log nicht sichtbar. Empfehlung: nur den Fehlertyp (`type(of:)`) und die Routen-Kennung ohne Pfadparameter protokollieren.
- Status: offen (Info).

### SEC-17 Info: Konten-Orakel bei Planfreigaben

- Ort: `PlanningServices.swift:427-430` (`create`: `recipient_not_found` gegen Erfolg).
- Beschreibung: Jedes angemeldete Mitglied kann prüfen, ob ein Handle existiert (bei Einladungsprinzip und kleiner Nutzerzahl geringes Risiko; Handles gelten ohnehin als Name unter Mitgliedern). Empfehlung: einheitliche Antwort oder Ratenbegrenzung; Entscheidung dokumentieren.
- Status: offen (Info).

## Hypothesen (nicht verifiziert)

- H-01 XLSX-Import: Der Filter gegen DTD/Entities arbeitet auf Bytes (`Import/ImportTable.swift:184`, nur `<!DOCTYPE`/`<!ENTITY` in UTF-8). Ein Teil in UTF-16/UTF-32 würde den Filter umgehen und erst im XML-Parser (`shouldResolveExternalEntities = false`) landen. Ob die Plattform-Bibliothek interne Entity-Expansion (Billion Laughs) bei kleinem Eingang begrenzt, ist nicht geprüft; die Grenzen für Eintragszahl, Gesamtgröße (50 MiB, beim Entpacken erzwungen) und Zeilen begrenzen die Wirkung. Empfehlung: Parser-Test mit Entity-Bombe in UTF-16 oder Kodierung ablehnen (nur UTF-8, BOM-Prüfung).
- H-02 Zu Punkt 7 der Aufgabe (`OIDCTokenTests.testNoSecretsInRedirectsOrLogs`, `log leaks eyJ`): Der Test sammelt über `LogSink` alle Meldungen auf Stufe `trace` ungefiltert (der Produktions-Handler `Sources/App/TimestampedLogHandler.swift:31-34` schwärzt zusätzlich über `TriggerTokenScrubber`). Die Zeichenfolge `eyJ` kommt auch zufällig in base64url-Zufallswerten (State, Nonce, Tokens) vor (Wahrscheinlichkeit je 43-Zeichen-Wert rund 1.6 in 10.000); jeder im Trace-Log ausgegebene Zufallswert kann den Test sporadisch rot färben. Außerdem würde ein im Trace-Log vorhandener JWT-Teil (nur Header) vom Scrubber nicht erfasst, weil dessen Muster drei Segmente verlangt (`TriggerLinks.swift:293`). Nur notiert, die Ursache untersucht ein anderer Agent.
- H-03 `ModuleGuard` leitet das Modul aus `req.url.path` (roh, prozentkodiert) ab; der Router vergleicht ebenfalls rohe Segmente (`DefaultResponder.getRoute`, `URI.path` ist `percentEncodedPath`). Dadurch ist nach Lesen des Vapor-Codes keine Umgehung des Modulschalters per `%67roups` zu erwarten. Ein Test mit kodierten Pfadsegmenten ist nicht gelaufen.

## Negativbefunde (geprüft, in Ordnung)

Kontentrennung und IDOR
- Alle `find(`-Aufrufe und alle Abfragen mit `\.$id ==`/`~~` wurden durchgesehen: Datensätze mit Konto-Bezug werden mit `accountId` gefiltert oder über `TimeServices(accountId:)`-Bereiche geladen (Zeit, Orte, Pläne, Berichte, Abwesenheiten, Dateien, Anhänge, Import, Vorschläge, Benachrichtigungen, Trigger-Links, Feeds, Gruppen-Eigentümerrouten). Fremde IDs ergeben 404.
- Referenzen auf Orte, Lernfelder und Dateien beim Anlegen/Importieren werden gegen das eigene Konto geprüft (`TimeServices.swift:159`, `Reports/ReportService.swift:67-70`, `Import/ImportService.swift:137-143`).
- MCP: Alle Tools laufen über `McpToolContext` mit einem an das Konto gebundenen `TimeServices`; Scopes, Modulschalter und deaktivierte Konten werden je Aufruf geprüft; Gruppen-, Datei-Inhalts- und Admin-Funktionen sind nicht als Tool vorhanden; Bearer-Tokens gelten nur für `/mcp` und `/automation/events` (`DeviceScopeGuard`).
- Planfreigaben: Ansicht wird je Bereich aus einer Whitelist aufgebaut, Orte und Notizen der Blöcke werden entfernt (`PlanningServices.swift:463-495`); Widerruf und deaktivierte Eigentümer greifen.
- Kontolöschung: `AccountEraser.wipes` deckt jede Tabelle mit Konto-Spalte ab und wird von `AccountDeletionTests` gegen das Schema geprüft; Anmeldedaten werden vorher widerrufen (`Accounts/AccountEraser.swift`).
- Öffentliche Gruppen: Link-Token 256 Bit, nur Hash-Abfrage, einheitliche 404, Zähler je IP/Link/Miss, `no-store`/`noindex`/`no-referrer`, Bearbeitungsschlüssel gehasht, CSV formelsicher, Bereinigung von Steuer- und Bidi-Zeichen, Eigentümer-deaktiviert-Fall.

Authentifizierung
- WebAuthn: Challenges einmalig und befristet, Benutzerverifikation erforderlich, Origin-Allow-List, `crossOrigin`/`topOrigin` abgelehnt, Credential-ID an Umschlag gebunden, `userHandle` an Konto gebunden, Zähler-Prüfung, Auth-Lock gegen Wettläufe.
- Sitzung: Zufallstoken 256 Bit, nur Hash gespeichert, `HttpOnly`, CSRF-Token per HMAC-artiger Ableitung mit Domänentrennung, Prüfung bei jeder nicht-sicheren Methode, „frische“ Sitzung (10 Minuten) für sicherheitsrelevante Änderungen, Wiederherstellungssitzung auf Passkey-Anlage beschränkt.
- OIDC: State einmalig und gehasht, Nonce, PKCE S256, Bindungs-Cookie, Link nur mit frischer Sitzung, Konto-Verknüpfung nur über (Issuer, Sub), nie über E-Mail; Discovery-Issuer-Abgleich, JWKS nur aus Discovery, Algorithmen nur RS256/ES256, keine `jwk/jku/x5u/crit`, `iss/aud/azp/exp/iat/nbf/nonce` geprüft, Weiterleitungen abgeschaltet, Antwortgrößen begrenzt, Tokens nicht gespeichert.
- OAuth-Server: PKCE S256 Pflicht, Redirect-URI exakter Vergleich (https oder Loopback), Code 60 Sekunden einmalig mit Widerruf des Grants bei Wiederverwendung, Refresh-Rotation mit Wiederverwendungserkennung, Tokens nur als Hash, Zustimmung an Sitzung gebunden, `resource`-Prüfung, Scopes nur verengbar, Widerruf wirkt sofort auf Zugriffstoken.
- Persönliche Tokens: `ttp_`-Präfix, Hash, Scopes, Ablauf bis 365 Tage, höchstens 25 aktive, Erstellung nur mit frischer Sitzung.
- Rückfallpasswort: Argon2id; Wiederherstellungscodes 192 Bit gehasht; Einmalverbrauch per bedingtem Schreiben mit Zeilenanzahl.
- Auslöse-Links `/t/`, Kalender `/ics/`: 256-Bit-Token (Hash), Ablauf/Widerruf, einheitliche 404, Zähler, Prefetch/HEAD löst nichts aus, `no-store`/`noindex`/`no-referrer`.

Injektion und Parsing
- SQL: Kein unbereinigter Wert fließt in rohes SQL; `unsafeRaw`/`raw` nur mit festen Texten oder Bezeichnern aus Code (Migrationen, `columnExists`).
- Lokaler Dateispeicher: generierter, formgeprüfter Schlüssel (`ab/cd/<uuid>`), `realpath`-Eindämmung, `O_NOFOLLOW`, Rechte 0700/0600, atomares Umbenennen; Prüfsumme und Größe beim Lesen; Typ per Inhaltsprüfung (nicht Dateiname), Dateiname bereinigt, `nosniff`, Inline nur für Whitelist mit `sandbox; default-src 'none'`.
- XLSX/CSV: Formel-Injektion in CSV und XLSX behandelt (`=`, `+`, `-`, `@`, Tab, CR), XML-Escaping, XLSX-Import mit Eintrags-, Größen- (beim Entpacken erzwungen), Pfad- und Symlink-Prüfung, DTD/Entity-Ablehnung, Zeilen-/Spaltenlimits.
- SSRF: Web-Push nur zu fester Host-Allow-List, einmalige Namensauflösung, Prüfung auf öffentliche Adressen, `dnsOverride`, keine Weiterleitungen; APNs nur feste Apple-Hosts; SMTP-Ziel nur aus der Betreiberkonfiguration; OIDC-Ziele aus der Betreiberkonfiguration, https oder Loopback.
- Mail: Adressen streng validiert (nur sichtbares ASCII), CR/LF in Betreff abgelehnt, Header kodiert, HTML-Vorlage escaped, SMTP-Klartext nur an Loopback erlaubt.
- ICS: Escape von Backslash, Semikolon, Komma, Zeilenumbruch; Orte und Notizen gelangen nicht in den Feed.

Proxy, Header, Konfiguration
- `TRUSTED_PROXY_CIDRS`: leer = niemand, `/0` abgelehnt, XFF von rechts gelesen, IPv6 /64, X-Real-IP nur bei genau einem Wert; Host-Header wird nirgends zur URL-Bildung genutzt (`PUBLIC_BASE_URL`).
- CORS nur für OAuth-Metadaten, Registrierung, Token, Widerruf (`*`, ohne Anmeldedaten); `/mcp` prüft `Origin`.
- `Cache-Control: no-store` für API, Token-URLs, Exporte und Dateien.
- Docker: Nicht-Root (uid 10001), `read_only`, tmpfs, Secrets über `*_FILE`, Entrypoint nur mit fester Variablenliste (`eval` auf feste Namen), Healthcheck auf `/ready`, Migrationen in eigenem Job mit minimalen Rechten, Ressourcenlimits, Rollback bei Fehlschlag.
- Skripte: `MYSQL_PWD` statt Argument, `umask 077`, `chmod go-rwx` auf Sicherungen, Geheimnisse werden nicht ausgegeben, keine `curl | sh`.
- Logs: Der Handler schwärzt Link-Token, APNs-Tokens, PEM-Schlüssel und JWT; Anwendungscode protokolliert keine Pfade mit Token, Codes oder Adressen.
- Abhängigkeiten: Vapor 4.122.3, swift-nio 2.104.0, swift-nio-ssl 2.37.5, swift-crypto 4.5.2, async-http-client 1.36.2, ZIPFoundation 0.9.20 (aktuell nach Stand der Fixes in der Handoff-Notiz); `Package.resolved` ist festgeschrieben. Eine Prüfung gegen Schwachstellenlisten wurde bewusst nicht ausgeführt (kein Netzwerk).

## Empfohlene Fix-Pakete

1. Paket SEC-A „Wiederherstellung und Sitzungen“ (SEC-02, SEC-03, SEC-04, SEC-08, SEC-15): Sitzungen/Tokens nach Wiederherstellung beenden, Benachrichtigungs-Mails, Cooldown je Konto, Versand asynchron, Passwortqualität, Leerlauf-Timeout. Größter Sicherheitsgewinn, Tests an `RecoveryService`/`WebAuthnService`.
2. Paket SEC-B „Proxy und Header“ (SEC-01, SEC-05, SEC-13): Doku und `stack.yaml` verschärfen, Startwarnung für zu weite Proxy-Netze, zentrale Sicherheitsheader (CSP, `frame-ancestors`, Referrer-Policy), Compose-Standard `127.0.0.1`.
3. Paket SEC-C „Kontingente und Last“ (SEC-06, SEC-07, SEC-11, SEC-12): Speicherkontingent, Export-Limit mit frischer Sitzung, Zähler vor `auth_lock`, DCR-Aufräumen und Zustimmungsseite.
4. Paket SEC-D „Härtung optional“ (SEC-09, SEC-10, SEC-14, SEC-16, SEC-17 und H-01): S3-/Pfad-Allow-List, Link-Token verschlüsseln, Revisionen und Action-SHAs pinnen, Fehlertyp-Logging, XML-Kodierung einschränken.

Nach jedem Paket: Regressionstests je Befund, Eintrag in `docs/STATUS.md` und `docs/ARBEITSPLAN.md`, Statusspalte hier nachführen.
