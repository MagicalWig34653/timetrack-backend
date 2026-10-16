# ADR-0015: Native Clients – Authentifizierung und API-Zugriff

Status: akzeptiert (Paket A1 vorgeschlagen, Nutzerentscheidungen und Backend-Paket A2 am 16.10.2026 eingearbeitet). Nutzerangaben: Apple Team ID `ABCDE12345`, Bundle-ID `com.example.timetrack` für iOS und macOS (Universal Purchase), künftige Watch-App `com.example.timetrack.watchkitapp`. Alles andere sind Annahmen und als solche markiert.

## Kontext

Die nativen Apps (macOS zuerst, danach iOS/iPadOS und watchOS) nutzen dieselbe REST-API wie die PWA (`contracts/openapi.yaml`). Persönliche Bearer-Tokens und OAuth gelten nur für `/mcp` (ADR-0009); REST kennt ausschließlich die Cookie-Sitzung (ADR-0003). Der Swift-Kern liegt im Apple-Repo unter `Packages/TimetrackCore`.

## Entscheidung

1. **REST mit Cookie-Sitzung und CSRF.** Native Clients verwenden `URLSession` mit eigenem Cookie-Speicher, Cookie `tt_session` und Header `X-CSRF-Token` (Wert aus `GET /api/v1/auth/session` bzw. jeder Login-Antwort) bei allen nicht-lesenden Requests. Bei `403 csrf_invalid` holt der Client das Token neu und wiederholt die Anfrage genau einmal (die Anfrage wurde nicht verarbeitet). Der Cookie-Wert wird im Keychain abgelegt und beim Start wiederhergestellt; Server-URL ebenfalls im Keychain. Keine Bearer-Tokens für REST.
2. **Passkeys über AuthenticationServices.** `ASAuthorizationPlatformPublicKeyCredentialProvider` mit der RP-ID des Servers. Die W3C-JSON-Optionen des Backends werden in AuthenticationServices-Anfragen übersetzt, die Antworten als `*ResponseJSON` (base64url) zurückgegeben; das Backend bleibt unverändert. Voraussetzungen:
   - Entitlement `com.apple.developer.associated-domains` mit `webcredentials:<Server-Host>` (iOS und macOS), und ein Provisioning-Profil, das Associated Domains erlaubt (Team `ABCDE12345`, Automatic Signing).
   - **Backend-Arbeit A2 (umgesetzt, Lead-Prüfung offen):** Endpunkt `GET /.well-known/apple-app-site-association` (JSON, `application/json`, ohne Weiterleitung, ohne Authentifizierung) mit `{"webcredentials":{"apps":["ABCDE12345.com.example.timetrack"]}}`. Konfigurierbar über `APPLE_APP_IDS` (kommagetrennt, Format `<TeamID>.<BundleID>`); leer = Endpunkt antwortet 404. Die WebAuthn-Konfiguration des Backends muss die RP-ID (Host) und für native Anfragen den erwarteten Origin akzeptieren (Apple-Clients senden `https://<rpId>` als Origin in `clientDataJSON`); Umsetzung: `WEBAUTHN_ORIGIN` bleibt der Web-Origin; zusätzlich gilt `https://<RP-ID>` als erlaubter Origin, nur wenn die RP-ID einen Punkt enthält (echte Domain). Der Abgleich ist eine exakte Allow-List aus genau diesen zwei Einträgen (kein Port, kein Pfad, keine Subdomain); Challenge-, RP-ID-Hash-, Signatur- und Zähler-Prüfung der WebAuthn-Bibliothek bleiben unverändert.
   - Die RP-ID muss eine echte Domain mit TLS sein; `localhost` funktioniert für native Passkeys nicht.
3. **Entwicklungsanmeldung ohne signierte App.** Recovery-Pfade (Recovery-Code, Rückfallpasswort) sind im Client umgesetzt. **Befund:** Eine Recovery-Sitzung ist laut Backend auf `GET/DELETE /auth/session` und `POST /me/passkeys/{options,verify}` beschränkt (`recovery_session_restricted` sonst). Sie taugt deshalb nur zum Einrichten eines Passkeys, nicht zum Arbeiten. Für Entwicklung gegen einen Testserver bietet die Debug-Version zusätzlich das Übernehmen eines `tt_session`-Cookies aus einer Browser-Sitzung (nur `#if DEBUG`, nie in Release). Entscheidung (Lead): Der Cookie-Import bleibt ausschließlich in Debug-Builds; es gibt keinen serverseitigen Entwicklungs-Login.
4. **Offline-Schreibwarteschlange: optional und später.** Start/Stop sind über `clientEventId` idempotent; der Client wiederholt bei Netzfehlern mit derselben ID (maximal 3 Versuche). Eine dauerhafte Warteschlange mit Konfliktbehandlung (`segment_overlap`, `stale_version`) ist ein eigenes Paket.
5. **watchOS: über das iPhone-Relay als Ziel, direkter Serverzugriff als Rückfall.** Empfehlung: Die Watch-App spricht direkt mit dem Server (eigene `URLSession`, eigener Keychain-Eintrag), weil die Cookie-Sitzung unabhängig vom iPhone funktioniert und Start/Stop auch ohne gekoppeltes iPhone gebraucht werden; die Anmeldung erfolgt nicht auf der Uhr (Passkey-UI dort eingeschränkt), sondern durch Übergabe der Sitzung vom iPhone über `WatchConnectivity` (`updateApplicationContext`, nur der Cookie-Wert, abgelegt im Keychain der Uhr). Begründung: weniger bewegliche Teile als ein reines Relay, kein Ausfall bei fehlendem iPhone, Komplikationen können aktuelle Daten selbst laden. Nachteil: eine zweite Sitzung je Gerät (einzeln widerrufbar über `/me/sessions`). Vom Nutzer am 16.10.2026 bestätigt.
6. **Modulschalter** (ADR-0012) wirken im Client: `GET /modules` bestimmt Navigation; 404 `module_disabled` löst eine Aktualisierung aus. Abgeschaltete Module sind standardmäßig „an“, bis der Server etwas anderes meldet (ein Ausfall von `/modules` darf die App nicht leeren).
7. **Auswertung bleibt im Backend.** Die Apps zeigen Soll/Ist/Rundung/Saldo wie geliefert und rechnen nicht nach (ADR-0004).
8. **Signierung und CI-Builds.** Entwicklung mit Automatic Signing (Team `ABCDE12345`). Prüfläufe ohne Provisioning-Profil laufen mit `CODE_SIGNING_ALLOWED=NO` (`xcodebuild … CODE_SIGNING_ALLOWED=NO build`). Die Team ID ist kein Geheimnis. Das Associated-Domains-Entitlement wird erst aktiviert, wenn der AASA-Endpunkt und eine Produktionsdomain stehen, damit Builds ohne Profil nicht scheitern.

## Alternativen

- Bearer-Tokens für REST: würde Backend-Änderungen an allen Routen und eine zweite Rechteprüfung erfordern; verworfen.
- Eigene Passkey-Implementierung ohne Associated Domains: nicht möglich, Plattformvorgabe.
- OIDC über `ASWebAuthenticationSession`: möglich (Backend-Funktion vorhanden, ADR-0007), aber optional und nicht in A1.

## Entscheidungen des Nutzers vom 16.10.2026

- **Domains.** Die Produktionsdomain wird voraussichtlich `timetrack.example.org` sein, nicht die Testdomain. Passkeys sind an die RP-ID gebunden: Ein späterer Wechsel der RP-ID (z. B. von `test.example.org` auf `timetrack.example.org`) entwertet alle vorhandenen Passkeys; Konten müssen dann über Recovery einen neuen Passkey registrieren. Passkeys der Testinstanz sind daher nicht in die Produktion übertragbar. Die Testinstanz `test.example.org` ist nur im LAN erreichbar; Apples CDN kann ihre AASA-Datei deshalb nicht abrufen. Für Entwicklungs-Builds gilt die Associated-Domains-Angabe `webcredentials:<Host>?mode=developer` auf einem Gerät, das den Host erreicht (Entwicklermodus des Geräts erforderlich; der Client lädt die Datei dann direkt statt über die CDN). Für Produktion (`webcredentials:timetrack.example.org` ohne Modus) muss die Domain öffentlich erreichbar sein.
- **Debug-Cookie-Import** bleibt ausschließlich in Debug-Builds (`#if DEBUG`), nie in Release (Lead-Entscheidung).
- **watchOS** spricht direkt mit dem Server; die Sitzung wird vom iPhone über `WatchConnectivity` übergeben (Nutzer einverstanden, siehe Entscheidung 5).

## Offene Fragen

1. Sitzungsdauer und Gültigkeit für native Apps: gleiche Dauer wie Browser oder länger?
2. Umgang mit „frischer Sitzung“ (`reauth_required`): Neuanmeldung per Passkey in der App oder Verweis auf die PWA?
3. Echter Test eines Plattform-Passkeys auf Apple-Gerät (A2 prüft Origin-Logik nur mit einem virtuellen Authenticator; die Aufnahme von `https://<rpId>` als echter Origin ist ungeprüft).

## Folgen

Backend-Paket A2 (AASA, `APPLE_APP_IDS`, Origin-Prüfung, Vertrag v0.10.4) ist umgesetzt; echte Passkey-Anmeldungen in den Apps hängen noch an Domain mit TLS, Deployment mit gesetztem `APPLE_APP_IDS` und Associated-Domains-Entitlement. Der Lead pflegt den ADR-Index.

## Nachtrag A3 (16.10.2026): Personal Team

Das Team `ABCDE12345` ist ein **persönliches** Entwicklungsteam. Apple erlaubt dort die Capability *Associated Domains* nicht („Personal development teams … do not support the Associated Domains capability"); ein signierter Build damit scheitert. Folgen: Echte Passkeys in den Apps brauchen die bezahlte Apple Developer Program-Mitgliedschaft. Bis dahin: Debug-Konfiguration von iOS ohne Associated Domains (signiert mit Personal Team, Anmeldung per Debug-Cookie-Import; Recovery-Sitzungen sind backendseitig auf Passkey-Einrichtung beschränkt). Release und `TimetrackDebug.entitlements` enthalten die Domains (`timetrack.example.org`, Testdomain mit `?mode=developer`) für den Betrieb mit bezahltem Team. Entscheidung über die Mitgliedschaft liegt beim Nutzer.

## Nachtrag A4 (16.10.2026): Übergabe an die Uhr

- Nutzlast genau `v`, `stamp` (streng steigend), `server`, `cookie`, per `WCSession.updateApplicationContext`; die Uhr speichert sie im eigenen Keychain und ignoriert alte/doppelte Kontexte, damit kein rotiertes Cookie überschrieben wird.
- iPhone abgemeldet oder nur Recovery-Sitzung: Uhr löscht lokal (ohne Server-Logout). 401 auf der Uhr: Sitzung verwerfen, Hinweis „Bitte am iPhone anmelden". Solange das iPhone noch wiederherstellt/offline ist, wird nichts gesendet.
- `WKRunsIndependentlyOfCompanionApp = true`. iPhone und Uhr teilen **eine** Serversitzung: Abmelden am iPhone beendet auch die der Uhr.
- Offen: Komplikation (eigenes Widget-Target), Art-Auswahl (Arbeit/Fahrt/Schule) auf der Uhr, Button „Sitzung an Uhr senden" am iPhone.

## Nachtrag A5 (16.10.2026): Komplikation

Die Komplikation (Widget-Erweiterung `TimetrackWidget`) liest einen **nicht geheimen** Anzeigestand aus der App Group `group.com.example.timetrack` (Laufzustand, Art, Startzeit, Tagessumme, Tag, Zeitzone, Aktualisierung). Der Session-Cookie bleibt im Keychain der Uhr. Ob das persönliche Entwicklerteam App Groups provisionieren kann, ist ungeklärt (signierter Watch-Build scheitert lokal an fehlenden Profilen; Associated Domains sind bei Personal Teams nachweislich gesperrt). Notlösung ohne App Group: `CODE_SIGN_ENTITLEMENTS` der beiden Ziele entfernen, die Komplikation zeigt dann „Aus". Der manuelle Knopf „Sitzung an Uhr senden" ändert das Übergabeformat nicht.

## Nachtrag (16.10.2026, Lead-Versuch): App Groups mit dem Personal Team

Mit Erlaubnis des Nutzers: `xcodebuild -allowProvisioningUpdates` mit Team `ABCDE12345` baut `TimetrackWatch` (generic watchOS) **signiert** und die Entitlements von App und Widget-Erweiterung enthalten `com.apple.security.application-groups = group.com.example.timetrack`; ebenso baut `TimetrackIOS` (Debug, ohne Associated Domains) signiert. **App Groups gehen also mit dem Personal Team; nur Associated Domains (Passkeys) nicht.** Folge: Komplikationen und Widgets (A7) sind auf echten Geräten möglich; die Notlösung ohne App Group entfällt. Dabei wurden vom Xcode-Dienst Profile/App-IDs im Entwicklerkonto angelegt. Auf einem echten Gerät nicht geprüft (nur Build und Entitlements).
