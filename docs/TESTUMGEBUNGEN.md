# Lokale Testumgebungen

Stand: 14.10.2026 (Paket L10), Abschnitt zur Testadresse am 17.10.2026 ergänzt. Alle Dienste gehören zum Compose-Projekt `timetrack-dev`, laufen nur über
`scripts/dev-env.sh` und sind **nur Testdoubles für die Entwicklung**, nicht für den Produktivbetrieb.
Zugangsdaten stehen nie im Repository: `scripts/dev-env.sh init` erzeugt `.env` (gitignoriert) aus `.env.example`.

## Übersicht

| Profil | Dienst | Zweck | Host-Ports (alle `127.0.0.1`) | Befehl |
|---|---|---|---|---|
| (immer) | MariaDB 12.3 | Datenbank-Tests | 13306 | `up` |
| `app` / `sqlite` | Backend-Container | Betrieb im Container | 18080 | `up-app` / `up-sqlite` |
| `mail` | Mailpit v1.29 | E-Mail-Wiederherstellung, Postfach-UI | UI 18025, SMTP 11025 | `up-mail` |
| `s3` | Adobe S3Mock 5.2.3 | S3-Speicherziel (Admin-Formular) | HTTP 19090, HTTPS 19191 | `up-s3` |
| `oidc` | Dex v2.41.1 | spätere OIDC-Adapter-Tests | 15556 | `up-oidc` |

`scripts/dev-env.sh down` stoppt alle Profile (ohne `-v`, Volumes bleiben). Es stoppt auch die DB; einzelne Dienste besser mit
`docker compose --project-name timetrack-dev --profile <p> stop <dienst>` stoppen. `status` zeigt Container und Volumes.

## Bind-Adressen und Veröffentlichung des Backends

Jeder veröffentlichte Port hat eine eigene Bind-Adresse mit Standard `127.0.0.1`:
`BACKEND_BIND_ADDR`, `DB_BIND_ADDR`, `MAIL_BIND_ADDR`, `S3_BIND_ADDR`, `OIDC_BIND_ADDR`.
Datenbank, Mailpit, S3Mock und Dex sollten nie auf `0.0.0.0` gestellt werden (S3Mock akzeptiert beliebige Zugangsdaten,
Dex enthält Testpasswörter, Mailpit hat keine Anmeldung).

Backend hinter einem vorhandenen Reverse Proxy (Domain, TLS und Proxy werden hier nicht eingerichtet):

1. In `.env` setzen, `example.org` durch die echte Domain ersetzen:
   ```
   BACKEND_BIND_ADDR=0.0.0.0        # oder die LAN-IP des Docker-Hosts; Standardport 18080 über BACKEND_HOST_PORT
   PUBLIC_BASE_URL=https://zeit.example.org
   WEBAUTHN_ORIGIN=https://zeit.example.org
   WEBAUTHN_RP_ID=zeit.example.org
   ```
   `WEBAUTHN_ORIGIN` und `PUBLIC_BASE_URL` müssen exakt die öffentliche `https://`-Adresse sein (ohne Pfad, ohne Slash am Ende),
   `WEBAUTHN_RP_ID` der Hostname daraus. Bereits registrierte Passkeys gehören zur alten RP-ID und gelten danach nicht mehr.
   Das Secure-Flag der Cookies folgt dem `https`-Schema der öffentlichen URL (siehe ADR/Handoffs zu Auth).
2. Backend neu starten (`up-app` bzw. `up-sqlite`).
3. Im Proxy die Domain auf `http://<docker-host>:18080` abbilden und `Host`, `X-Forwarded-Proto` und `X-Forwarded-For` durchreichen.
4. Firewall: Port 18080 nur für den Proxy erreichbar machen.

## Mailpit (`mail`)

- Postfach-UI und API: `http://localhost:18025` (`/api/v1/messages`). SMTP für Host-Prozesse: `127.0.0.1:11025`, ohne TLS und Anmeldung.
- Backend auf dem Host: `SMTP_HOST=127.0.0.1 SMTP_PORT=11025 SMTP_TLS=off SMTP_FROM=noreply@example.test`.
- Backend im Container: `SMTP_HOST=mailpit`, `SMTP_PORT=1025`, `SMTP_TLS=off`, `SMTP_FROM` (Standardwerte in `compose.yaml`).
- Geprüft wurde der komplette Ablauf mit `scripts/mail-recovery.e2e.spec.ts` (siehe Handoff).
- Grenze: kein TLS/AUTH-Test. Mailpit ist kein echter Zustelldienst.

## S3Mock (`s3`)

- Adobe S3Mock akzeptiert **beliebige** Zugangsdaten und prüft keine Signaturen. Es testet die S3-Anbindung, nicht Rechteverhalten.
- Bucket `timetrack-dev` wird beim Start angelegt; Daten bleiben im Volume `timetrack-dev-s3mock` erhalten (Neustart geprüft).
  Der Container läuft als root, weil ein frisches Volume sonst nicht beschreibbar ist (nur Entwicklung).
- Werte fürs Admin-Speicherformular: `scripts/dev-env.sh s3-env` gibt Endpoint `http://127.0.0.1:19090`, Region `us-east-1`,
  Bucket `timetrack-dev`, Path-Style `true` und Dummy-Schlüssel aus. HTTPS (self-signed) auf 19191 nur für Clients, die das Zertifikat ignorieren.
- Ein Backend im Container erreicht S3Mock unter `http://s3mock:9090` (gleiches Compose-Netz).
- Das separate Projekt mit Volume `compose_s3mock-dev` bleibt unberührt.
- Hinweis: Das offizielle MinIO-Image ist nicht mehr auf Docker Hub verfügbar; deshalb S3Mock.

## Dex (`oidc`)

- Issuer `http://localhost:15556/dex`, Discovery: `/.well-known/openid-configuration`. Konfiguration: `deploy/dex/config.yaml`.
- Öffentlicher Client `timetrack-dev` (kein Secret, PKCE `S256`), Redirect-URIs `http://localhost:18080/api/v1/auth/oidc/callback` und
  `http://localhost:5173/api/v1/auth/oidc/callback`.
- Testnutzer (nur Testdaten): `alice@example.test` / `alice-dev-pass`, `bob@example.test` / `bob-dev-pass`.
- Prüfung: `python3 -I scripts/oidc-pkce-check.py` führt Discovery, Autorisierung, Login, Code-Austausch mit PKCE aus (ohne Tokenwerte auszugeben).
- Grenze: Dex-Speicher ist `memory`, Neustart verwirft Sitzungen. Nur HTTP. Der OIDC-Adapter im Backend ist seit C14 implementiert (ADR-0007).

## Offene Punkte

- Anmeldung per Dex gegen das Backend: von C14 gegen echtes Dex gelaufen (Handoff C14); gegen andere Provider ungeprüft.
- SMTP mit TLS/AUTH, echte S3-Signaturen und Rechte: nicht abgedeckt.


## Öffentliche Testadresse (eingerichtet 14.10.2026)

Domain `test.example.org` → Reverse Proxy des Nutzers (TLS dort) → `192.0.2.10:18080` (dieser Mac). Nichts davon wird vom Projekt provisioniert. Domain und Adresse sind hier Platzhalter; die echten Werte stehen nur in der privaten `.env` des Betreibers. Stand 17.10.2026: Die Instanz läuft mit Backend und PWA im Stand P2 (ausgerollt 16.10. abends); die Apple-App-Site-Association ist dort aus (`APPLE_APP_IDS` nicht gesetzt). Die Produktionsinstanz ist davon getrennt (`DEPLOYMENT.md`).

Lokale `.env` (nicht versioniert): `BACKEND_BIND_ADDR=0.0.0.0`, `PUBLIC_BASE_URL=https://test.example.org`, `WEBAUTHN_ORIGIN` identisch, `WEBAUTHN_RP_ID=test.example.org`,
`PWA_STATIC_HOST_DIR=./deploy/pwa-static` (Kopie des PWA-Builds, ignoriert), `DATABASE_DRIVER=mariadb`, `AUTO_MIGRATE=true`; Start `scripts/dev-env.sh up-app`.

Wichtig (Colima): Der Docker-Daemon läuft in einer VM, die die LAN-Adresse des Mac nicht kennt. `BACKEND_BIND_ADDR=192.0.2.10` scheitert deshalb mit „cannot assign requested address“; `0.0.0.0` funktioniert, Colima leitet den Port am Mac weiter (`*:18080`).
Der Port ist damit im lokalen Netz offen – Zugriff nur über das eigene Netz/den Proxy zulassen. DB, Mailpit, S3Mock und Dex bleiben auf 127.0.0.1.

Erster Admin: `docker compose --profile app run --rm -T backend bootstrap-admin` (Link `https://test.example.org/invite/<token>`, 72 h gültig, einmalig; nur Hash gespeichert).
PWA aktualisieren: neuen Build nach `deploy/pwa-static/` kopieren (kein Neustart nötig); Backend aktualisieren: `scripts/dev-env.sh up-app` (baut das Image neu).

Geprüft am 14.10.2026 (Lead, von außen über HTTPS): `https://test.example.org` liefert `/health` und `/ready` mit 200, die PWA samt SPA-Fallback und die API (401 ohne Sitzung). Der Nutzer erlaubt die Domain als Testziel.
Konvention: Auf dieser Instanz keine automatisierten Registrierungen mit virtuellen Passkeys (der erste Admin soll der echte Nutzer mit echtem Passkey sein); automatisierte Tests laufen weiter gegen eigene Wegwerf-Backends (E2E-Ports 18090 ff.). Lesende Prüfungen sind erlaubt.

## Speicherplatz in Colima (Stand 15.10.2026)

Die Docker-Datenpartition der Colima-VM (40 GB) war am 15.10. wieder zu 100 % belegt (Images ~35 GB, Build-Cache ~14,6 GB, davon ~3,8 GB freigebbar). Folge: MariaDB meldete beim Anlegen neuer Tabellen „No space left on device“, das Backend startete in einer Schleife neu.
Behelf: eigene, ungenutzte Image-Tags entfernen (`docker rmi timetrack-dev-backend:<tag>`). Dauerhaft: Build-Cache bereinigen (`docker builder prune`, betrifft alle Projekte in dieser Colima-VM nur als Cache) oder die Platte vergrößern (`colima stop && colima start --disk 80`).
Prüfen mit `colima ssh -- df -h /var/lib/docker`. Das Projekt löscht nie fremde Images, Container oder Volumes.

Vorfall 15.10.2026 (Platte voll): Bei 0 Byte freiem Platz auf `/var/lib/docker` fiel die Dev-MariaDB aus (InnoDB startet nicht, Container in Neustartschleife); Testdomain lieferte keine Daten. Nach `docker builder prune -f` (3,8 GB frei, vom Nutzer freigegeben) und `docker restart timetrack-dev-db-1`
startete MariaDB nach automatischer InnoDB-Wiederherstellung wieder. Freier Platz danach ~3,6 GB (91 %) – für stabilen Betrieb Platte vergrößern (`colima stop && colima start --disk 80`) oder weitere fremde Images entfernen (nicht Aufgabe dieses Projekts).
