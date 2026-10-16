# ADR-0015: Native Clients – Authentifizierung und API-Zugriff

Status: vorgeschlagen (Paket A1, 16.10.2026; Lead bestätigt/ändert). Nutzerangaben: Apple Team ID `ABCDE12345`, Bundle-ID `com.example.timetrack` für iOS und macOS (Universal Purchase), künftige Watch-App `com.example.timetrack.watchkitapp`. Alles andere sind Annahmen und als solche markiert.

## Kontext

Die nativen Apps (macOS zuerst, danach iOS/iPadOS und watchOS) nutzen dieselbe REST-API wie die PWA (`contracts/openapi.yaml`). Persönliche Bearer-Tokens und OAuth gelten nur für `/mcp` (ADR-0009); REST kennt ausschließlich die Cookie-Sitzung (ADR-0003). Der Swift-Kern liegt im Apple-Repo unter `Packages/TimetrackCore`.

## Entscheidung

1. **REST mit Cookie-Sitzung und CSRF.** Native Clients verwenden `URLSession` mit eigenem Cookie-Speicher, Cookie `tt_session` und Header `X-CSRF-Token` (Wert aus `GET /api/v1/auth/session` bzw. jeder Login-Antwort) bei allen nicht-lesenden Requests. Bei `403 csrf_invalid` holt der Client das Token neu und wiederholt die Anfrage genau einmal (die Anfrage wurde nicht verarbeitet). Der Cookie-Wert wird im Keychain abgelegt und beim Start wiederhergestellt; Server-URL ebenfalls im Keychain. Keine Bearer-Tokens für REST.
2. **Passkeys über AuthenticationServices.** `ASAuthorizationPlatformPublicKeyCredentialProvider` mit der RP-ID des Servers. Die W3C-JSON-Optionen des Backends werden in AuthenticationServices-Anfragen übersetzt, die Antworten als `*ResponseJSON` (base64url) zurückgegeben; das Backend bleibt unverändert. Voraussetzungen:
   - Entitlement `com.apple.developer.associated-domains` mit `webcredentials:<Server-Host>` (iOS und macOS), und ein Provisioning-Profil, das Associated Domains erlaubt (Team `ABCDE12345`, Automatic Signing).
   - **Backend-Arbeit A2 (zu planen):** Endpunkt `GET /.well-known/apple-app-site-association` (JSON, `application/json`, ohne Weiterleitung, ohne Authentifizierung) mit `{"webcredentials":{"apps":["ABCDE12345.com.example.timetrack"]}}`. Konfigurierbar über `APPLE_APP_IDS` (kommagetrennt, Format `<TeamID>.<BundleID>`); leer = Endpunkt antwortet 404. Die WebAuthn-Konfiguration des Backends muss die RP-ID (Host) und für native Anfragen den erwarteten Origin akzeptieren (Apple-Clients senden `https://<rpId>` als Origin in `clientDataJSON`); das ist in A2 zu prüfen.
   - Die RP-ID muss eine echte Domain mit TLS sein; `localhost` funktioniert für native Passkeys nicht.
3. **Entwicklungsanmeldung ohne signierte App.** Recovery-Pfade (Recovery-Code, Rückfallpasswort) sind im Client umgesetzt. **Befund:** Eine Recovery-Sitzung ist laut Backend auf `GET/DELETE /auth/session` und `POST /me/passkeys/{options,verify}` beschränkt (`recovery_session_restricted` sonst). Sie taugt deshalb nur zum Einrichten eines Passkeys, nicht zum Arbeiten. Für Entwicklung gegen einen Testserver bietet die Debug-Version zusätzlich das Übernehmen eines `tt_session`-Cookies aus einer Browser-Sitzung (nur `#if DEBUG`, nie in Release). Vorschlag für das Backend (A2, optional): kein Sonderpfad, solange Passkeys auf einem Testserver mit echter Domain möglich sind.
4. **Offline-Schreibwarteschlange: optional und später.** Start/Stop sind über `clientEventId` idempotent; der Client wiederholt bei Netzfehlern mit derselben ID (maximal 3 Versuche). Eine dauerhafte Warteschlange mit Konfliktbehandlung (`segment_overlap`, `stale_version`) ist ein eigenes Paket.
5. **watchOS: über das iPhone-Relay als Ziel, direkter Serverzugriff als Rückfall.** Empfehlung: Die Watch-App spricht direkt mit dem Server (eigene `URLSession`, eigener Keychain-Eintrag), weil die Cookie-Sitzung unabhängig vom iPhone funktioniert und Start/Stop auch ohne gekoppeltes iPhone gebraucht werden; die Anmeldung erfolgt nicht auf der Uhr (Passkey-UI dort eingeschränkt), sondern durch Übergabe der Sitzung vom iPhone über `WatchConnectivity` (`updateApplicationContext`, nur der Cookie-Wert, abgelegt im Keychain der Uhr). Begründung: weniger bewegliche Teile als ein reines Relay, kein Ausfall bei fehlendem iPhone, Komplikationen können aktuelle Daten selbst laden. Nachteil: eine zweite Sitzung je Gerät (einzeln widerrufbar über `/me/sessions`). Annahme, vom Nutzer nicht bestätigt.
6. **Modulschalter** (ADR-0012) wirken im Client: `GET /modules` bestimmt Navigation; 404 `module_disabled` löst eine Aktualisierung aus. Abgeschaltete Module sind standardmäßig „an“, bis der Server etwas anderes meldet (ein Ausfall von `/modules` darf die App nicht leeren).
7. **Auswertung bleibt im Backend.** Die Apps zeigen Soll/Ist/Rundung/Saldo wie geliefert und rechnen nicht nach (ADR-0004).
8. **Signierung und CI-Builds.** Entwicklung mit Automatic Signing (Team `ABCDE12345`). Prüfläufe ohne Provisioning-Profil laufen mit `CODE_SIGNING_ALLOWED=NO` (`xcodebuild … CODE_SIGNING_ALLOWED=NO build`). Die Team ID ist kein Geheimnis. Das Associated-Domains-Entitlement wird erst aktiviert, wenn der AASA-Endpunkt und eine Produktionsdomain stehen, damit Builds ohne Profil nicht scheitern.

## Alternativen

- Bearer-Tokens für REST: würde Backend-Änderungen an allen Routen und eine zweite Rechteprüfung erfordern; verworfen.
- Eigene Passkey-Implementierung ohne Associated Domains: nicht möglich, Plattformvorgabe.
- OIDC über `ASWebAuthenticationSession`: möglich (Backend-Funktion vorhanden, ADR-0007), aber optional und nicht in A1.

## Offene Fragen

1. Produktionsdomain bzw. Testdomain mit TLS für Passkeys (Voraussetzung für jeden echten Anmeldetest)?
2. Soll der Debug-Cookie-Import dauerhaft bleiben oder gibt es einen serverseitigen Entwicklungs-Login auf Testinstanzen?
3. Watch: direkter Zugriff mit Sitzungsübergabe (Empfehlung) oder reines iPhone-Relay?
4. Origin-Prüfung der WebAuthn-Verifikation im Backend für native Clients (siehe 2.): Wird `https://<rpId>` akzeptiert, oder gibt es eine Origin-Liste?
5. Sitzungsdauer und Gültigkeit für native Apps: gleiche Dauer wie Browser oder länger?
6. Umgang mit „frischer Sitzung“ (`reauth_required`): Neuanmeldung per Passkey in der App oder Verweis auf die PWA?

## Folgen

Backend-Paket A2 (AASA, `APPLE_APP_IDS`, Origin-Prüfung) ist zu planen; bis dahin sind echte Passkey-Anmeldungen in den Apps nicht testbar. Der Lead pflegt den ADR-Index.
