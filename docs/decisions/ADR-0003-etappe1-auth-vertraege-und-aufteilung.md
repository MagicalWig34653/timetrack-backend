# ADR-0003: Etappe 1 – Auth-Verträge, Annahmen und Paketaufteilung

Status: akzeptiert (Lead-Entscheidung 14.10.2026; Annahmen unten sind keine Nutzerentscheidungen).

## Kontext

Etappe 0/1 aus `UMSETZUNG.md` braucht einen gemeinsamen Vertrag, damit Backend (Codex),
PWA und Compose (Claude-Agents) parallel arbeiten können. Maßgeblich: `contracts/openapi.yaml`.

## Entscheidung (Annahmen, kenntlich gemacht)

- API unter `/api/v1`, JSON, Fehler `{error:{code,message}}` (Codes Englisch, UI übersetzt auf Deutsch).
- Sitzung: opaker Zufallstoken im HttpOnly-Cookie `tt_session` (SameSite=Lax, Secure außer lokal HTTP);
  serverseitig nur Hash gespeichert. CSRF: Token pro Sitzung, Header `X-CSRF-Token` bei schreibenden Requests.
- Konto-Kennung `handle` (eindeutig, Kleinbuchstaben) dient als Recovery-Identifier; E-Mail optional.
- Registrierung nur mit Einladungstoken (Hash gespeichert, einmalig, Ablauf). Erster Admin über CLI-Befehl
  `App bootstrap-admin` (gibt einmaligen Einladungslink für Admin-Rolle aus; nur wenn noch kein Konto existiert).
- Passkeys: WebAuthn mit geprüfter Swift-Bibliothek (Kandidat `swift-server/webauthn-swift`); Wahl durch C2,
  Lizenz/Reife dokumentieren. Discoverable Credentials, mehrere Passkeys pro Konto, einzelner Widerruf.
- Recovery: Recovery-Codes, Rückfallpasswort, E-Mail-Code, einzeln aktivierbar. Recovery erzeugt nur eine
  eingeschränkte Sitzung (`recovery=true`), die nur Passkey-Einrichtung und Sitzungswiderruf erlaubt.
- Rückfallpasswort: speicherharte Hashfunktion (Argon2id bevorzugt; fällt die Swift-Bibliothekswahl aus,
  dokumentierte Alternative). Nicht für Normalanmeldung.
- DB: Fluent; `DATABASE_DRIVER=mariadb|sqlite`, Migrationen für beide identisch (nur portable Typen);
  Zeitpunkte UTC, IDs UUID, Dauern ganzzahlig.
- Lokale Ports (Host-Ports 3306/3310/5432 sind durch andere Projekte belegt): MariaDB 127.0.0.1:13306,
  Backend 127.0.0.1:18080, PWA-Dev 127.0.0.1:5173. WebAuthn lokal: RP-ID `localhost`, Origin `http://localhost:18080`
  (produktionsähnlich, PWA statisch vom Backend ausgeliefert) bzw. `http://localhost:5173` im Dev-Profil.

## Paketaufteilung

C1 (Codex): Konfiguration, DB-Auswahl, Migrationen, Modelle, /ready, Testgrundlage (MariaDB+SQLite).
C2 (Codex): Einladungen, Konten, Sitzungen/CSRF, WebAuthn-Verifikation, alle drei Recovery-Dienste, Admin-Einladungs-API, Integrationstests.
L1 (Claude-Agent): Svelte-Oberfläche (Einladung/Registrierung, Login, Passkey-Verwaltung, Recovery, Admin-Einladungen).
L2 (Claude-Agent): Dockerfile, Compose (dev + prod-ähnlich), MariaDB-Dev, Browser-Durchstich, amd64-Build.
Verträge ändert nur der Lead. Migrationsdateien: nur C1/C2 (seriell).

## Alternativen

Auth-Dienste zwischen Teams teilen: verworfen, Verantwortung wäre unklar. JWT-Sitzungen: verworfen
(Widerruf/Rotation schwerer). Token im localStorage: verworfen (XSS-Exposition).

## Folgen

PWA muss Cookie + CSRF-Header verwenden; Vite-Dev-Proxy oder gleiche Origin nötig. Änderungen am
Vertrag während Etappe 1 über den Lead, mit Hinweis in `ARBEITSPLAN.md`.

## Nachtrag SEC-15b (02.11.2026): `__Host-`-Präfix

Nutzerentscheidung 02.11.2026 (Sicherheitsreview SEC-15): Das Sitzungscookie heißt bei einer HTTPS-`PUBLIC_BASE_URL` `__Host-tt_session`. Browser erzwingen damit Secure, `Path=/` und kein `Domain`-Attribut; eine Schwesterdomain kann das Cookie weder setzen noch überschreiben. Bei HTTP (lokale Entwicklung, Tests) bleibt es `tt_session`, weil Browser das Präfix ohne HTTPS verwerfen. Der Name wird an einer Stelle bestimmt (`SessionCookie` in `SessionService.swift`) und hängt nur am Schema der Basis-URL, nicht an `X-Forwarded-Proto`.

- Alte Sitzungen unter `tt_session` werden bewusst nicht übernommen (einmaliger Sitzungsverlust); eine Umsetzung auf den neuen Namen wäre ein Übernahmepfad für ein Cookie, das eine Schwesterdomain gesetzt haben könnte, und widerspräche dem Zweck. Antworten, die ein Sitzungscookie setzen, löschen den alten Namen; Abmelden und Kontolöschung löschen beide.
- Bearer-only-Routen (Automatisierung, MCP) lehnen weiterhin jede Anfrage ab, die ein Sitzungscookie unter einem der beiden Namen trägt.
- Das Bindungscookie `tt_oidc` bleibt unverändert: Sein Pfad `/api/v1/auth/oidc` ist mit `__Host-` unvereinbar; es lebt zehn Minuten und schützt nur den Login-Ablauf.
- Der CSRF-Wert ist kein Cookie (Header `X-CSRF-Token`), er braucht kein Präfix.
- Clients dürfen den Namen nicht fest verdrahten: Browser (PWA) sind unberührt, die Apple-App leitet ihn aus dem Schema der Server-URL ab.
