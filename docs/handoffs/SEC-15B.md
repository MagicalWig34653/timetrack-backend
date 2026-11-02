# Übergabe SEC-15b: `__Host-`-Cookiepräfix (Sicherheitsreview SEC-15)

Branch `sec-15b`, Vertrag **0.43.0** (nur Beschreibung/Cookiename, keine neuen Felder), keine Migration. Nutzerentscheidung 02.11.2026: einführen, einmaliger Sitzungsverlust akzeptiert.

## Änderungen

- `SessionCookie` (`Sources/TimetrackKit/SessionService.swift`) bestimmt den Namen zentral: `__Host-tt_session`, wenn `PUBLIC_BASE_URL` mit `https` beginnt, sonst `tt_session`. `AuthService` setzt (`setSessionCookie`), löscht (`clearSessionCookies`) und liest (`sessionToken`) das Cookie; alle früheren Stellen (Middleware, Routen, OIDC, Kontolöschung, Modulwächter, Geräte-Token-Middleware) nutzen diese Funktionen.
- Gelesen wird nur der aktuelle Name. Eine Sitzung unter `tt_session` wird bei HTTPS nicht akzeptiert (Standard: Sitzungsverlust; kein Übernahmepfad, Begründung ADR-0003 Nachtrag).
- Jede Antwort, die ein Sitzungscookie setzt, läuft den alten Namen ab; Abmelden und Kontolöschung laufen beide Namen ab (Path=/, Secure, ohne Domain).
- Bearer-Routen (Automatisierung/Geräte-Token) lehnen Anfragen mit einem Sitzungscookie beider Namen ab. MCP/OAuth ist cookielos.
- `tt_oidc` unverändert (Pfad `/api/v1/auth/oidc`, mit `__Host-` unvereinbar). CSRF ist ein Header, kein Cookie.
- Tests: `SessionCookieTests` (Name nur bei https, Attribute inkl. kein Domain, Abmelden löscht beide, altes Cookie ungültig, Gegenprobe HTTP) sowie `AuthHTTPTests`.
- Doku: ADR-0003 Nachtrag, Review (SEC-15), BETRIEB, DEPLOYMENT, UPDATE, CHANGELOG, STATUS.

## Betreiberhinweis

Beim Update melden sich alle Nutzer einmalig neu an (kein Datenverlust). Proxy darf `Set-Cookie` nicht umschreiben (`Domain`/`Path`).

## Anpassungen in den Clients

- **PWA (`timetrack-pwa`)**: keine. Der Browser verwaltet das Cookie; `src/` kennt den Namen nicht, der Service Worker greift nicht auf Cookies zu. Nur der Entwicklungs-Mock (`mock/`) benutzt `tt_session` über HTTP und ist unverändert korrekt.
- **Apple (`timetrack-apple`)**: Der Name ist fest verdrahtet in `Packages/TimetrackCore/Sources/TimetrackCore/Networking/Transport.swift` (`public let sessionCookieName = "tt_session"`; verwendet in `sessionCookieValue`, `setSessionCookie`, `clearSessionCookie`). Die App liest den Wert aus dem Cookie-Speicher, legt ihn im Schlüsselbund ab und setzt ihn beim Start zurück; gegen einen HTTPS-Server mit neuem Backend findet sie `tt_session` nie, speichert keine Sitzung und setzt eine gespeicherte Sitzung unter falschem Namen ein (401). Anpassung: Name aus dem Schema der Server-URL ableiten (`baseURL.scheme == "https" ? "__Host-tt_session" : "tt_session"`), beim Setzen `Path=/` und `secure` beibehalten, beim Löschen beide Namen entfernen. Gespeicherte Schlüsselbund-Werte sind nach dem Update ungültig (Server lehnt sie ab) und führen zur normalen Neuanmeldung. Weitere Stellen: Entwicklungsanmeldung mit kopiertem Cookie (`AuthService.swift`, `AppModel.swift`, Texte „Sitzungs-Cookie tt_session“ in den `Localizable.xcstrings` von iOS/Mac), `TT_DEV_COOKIE` (nur HTTP, bleibt `tt_session`), Skripte `scripts/seed-*.py` und `IntegrationTests.swift` (HTTP gegen Wegwerf-Server, unverändert). WatchConnectivity-Übertragung des Werts: Wert unverändert, nur der Name muss auf der Uhr aus der Server-URL abgeleitet werden.
- Skripte im Backend (`scripts/test-restore.sh`): laufen über HTTP, bleiben `tt_session`.

## Prüfung

- Linux-Container (swift:6.3-noble), `swift test --build-system native -j 3`, SQLite: 532 Tests bis zum Ende; die einzigen 6 Fehlschläge lagen im neuen `SessionCookieTests` (Testhelfer: Origin/RP-ID der Software-Authentifikatoren bei https), danach behoben; `SessionCookieTests`, `AuthHTTPTests` und Vertragstests grün (9/9). Der übrige Bestand lief ohne Fehler.
- Playwright (Chromium, virtueller Passkey) gegen das gebaute Backend über einen lokalen TLS-Proxy mit Selbstzertifikat (`X-Forwarded-Proto: https`, `PUBLIC_BASE_URL` https): Registrierung, Neuladen mit eingestreutem Alt-Cookie, CSRF-Schreibzugriff, Abmelden (beide Namen weg, danach 401), erneute Passkey-Anmeldung. Cookie `__Host-tt_session`: Secure, HttpOnly, SameSite=Lax, Path=/.
