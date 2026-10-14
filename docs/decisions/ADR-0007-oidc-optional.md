# ADR-0007: Optionales OpenID Connect

Status: akzeptiert (Lead-Entscheidung 14.10.2026 gemäß bestätigter Richtung in ARCHITEKTUR.md Abschnitt 2; Details sind Annahmen).

- OIDC ist optional und standardmäßig aus (`OIDC_ISSUER` + `OIDC_CLIENT_ID` nötig). Authorization Code Flow mit PKCE (S256), `state` und `nonce` serverseitig (Tabelle, 10 min, einmalig). Öffentlicher Client ohne Pflicht-Secret; `OIDC_CLIENT_SECRET` optional (confidential).
- Identität = (`issuer`, `sub`). **Nie** automatisches Verknüpfen oder Anlegen über E-Mail. Neue Verknüpfung nur durch ein eingeloggtes Konto (frische Sitzung) oder durch Einlösen einer Einladung (`register`).
- **Registrierung bleibt einladungspflichtig**: unbekannte Identität beim Login → `oidc_not_linked`, kein Konto. Einladung + Identität werden atomar verbraucht; Konten ohne Passkey sind erlaubt, die PWA bietet Passkey-Einrichtung an (Passkeys bleiben primär).
- id_token-Validierung: Signatur (RS256/ES256 über JWKS mit Cache und kid-Rotation), `iss`, `aud` (= client id), `azp`, `exp`/`iat`/`nbf` mit kleiner Toleranz, `nonce`; `alg=none` und HS* abgelehnt; Discovery nur über `OIDC_ISSUER` (Issuer-URL muss exakt übereinstimmen); Tokens werden nicht gespeichert oder geloggt, kein Refresh.
- Sitzung und Rechte wie nach Passkey-Login (HttpOnly-Cookie, CSRF); Recovery-Methoden bleiben unabhängig. Letzte Anmeldemethode kann nicht entfernt werden.
- Lokaler Test: Dex-Profil `oidc` aus `docs/TESTUMGEBUNGEN.md` (Issuer `http://localhost:15556/dex`, Client `timetrack-dev`). Authentik o. Ä. nur optional anbindbar, nicht Voraussetzung.
- Pakete: C14 Backend (Claude-Agent wegen Codex-Limit), L11 PWA + E2E gegen Dex.
