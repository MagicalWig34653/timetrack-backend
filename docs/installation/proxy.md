# Reverse Proxy und TLS

- **Wofür:** HTTPS vor Timetrack, richtige Weitergabe der Client-Adresse, Durchreichen der Apple-Datei.
- **Voraussetzungen:** laufender Stack ([Compose](compose.md) oder [Swarm](swarm.md)), eine Domain, die auf den Server zeigt.
- **Dauer:** 5 bis 15 Minuten. Der Proxy gehört dir; das Projekt provisioniert keinen.

Das Backend spricht intern nur HTTP und liefert API und Web-App aus. Der Proxy terminiert TLS und leitet **alles** weiter. Zwei Regeln sind wichtig: `/.well-known/apple-app-site-association` unverändert durchreichen (nur für die Apple-Apps nötig) und `TRUSTED_PROXY_CIDRS` setzen, damit nicht alle Nutzer ein gemeinsames Anmelde-Limit teilen.

## Caddy (kürzeste Variante)

Caddy holt das Zertifikat selbst und reicht alles unverändert durch:

```
timetrack.example.org {
    reverse_proxy 127.0.0.1:18080
}
```

Für große Uploads ist bei Caddy nichts nötig (kein Standardlimit). Die folgenden Abschnitte nennen die Anforderungen genauer und zeigen nginx und Traefik.

## Anforderungen und Beispiele

Der Proxy terminiert TLS und leitet **alles** an das Backend (es liefert auch die PWA aus). Ziel: `http://127.0.0.1:18080` (Compose, Proxy auf demselben Server) bzw. `http://<Knoten-IP>:18080` (Swarm; der veröffentlichte Port, `PUBLISHED_PORT`).
Der Name `backend` ist ebenfalls als Alias vorhanden, kann aber mit Diensten anderer Stacks kollidieren; der volle Name `timetrack_backend` ist eindeutig.

Anforderungen (aus Code und [Betrieb](../BETRIEB.md), Abschnitt 6):

| Thema | Anforderung |
| --- | --- |
| TLS/HTTP | HTTPS für `timetrack.example.org`, HTTP/2 empfohlen, HTTP→HTTPS-Umleitung, HSTS (`max-age=31536000`). Auf dem Weg zum Backend darf HTTP/1.1 genutzt werden. |
| Header | `Host`, `X-Forwarded-For` (anhängen), `X-Forwarded-Proto`. Das Backend baut URLs aus `PUBLIC_BASE_URL`, nicht aus dem Host-Header. |
| `/.well-known/apple-app-site-association` | **Unverändert durchreichen**: kein Redirect, keine Authentifizierung, kein Umschreiben, `Content-Type: application/json` (setzt das Backend selbst; nicht überschreiben), HTTP 200 direkt. Auch `/.well-known/oauth-*` (MCP/OAuth) durchreichen. |
| Caching | `/api/` nicht cachen (kein Proxy-Cache). Das Backend setzt für die PWA selbst `Cache-Control` (hashierte Dateien `immutable`, sonst `no-cache`); nicht überschreiben. Keine Komprimierung ist erforderlich. |
| Upload | Dateien bis 64 MiB plus 64 KiB Multipart-Aufschlag: Körpergrenze **mindestens 65 MiB** (hier 70m), Lese-/Sendezeitüberschreitung ≥ 120 s. |
| `/mcp` | Streamable HTTP nur per `POST` mit JSON-Antwort: kein SSE, kein WebSocket, keine Upgrade-Header, kein Streaming-Puffer nötig. `GET /mcp` liefert absichtlich 405. Körper ≤ 256 KiB. |
| `/health`, `/ready` | Nicht öffentlich weiterreichen (Informationen über Datenbankzustand). Der Docker-Healthcheck braucht sie nicht über den Proxy. |
| Rate-Limit | Zusätzlich am Proxy für `/api/v1/auth/`, `/api/v1/me/recovery/`, `/oauth/` (z. B. 10 Anfragen/s je IP). |
| Echte Client-IP | Siehe „TRUSTED_PROXY_CIDRS bestimmen“ unten: im Swarm den Proxy-Port im **Host-Modus** veröffentlichen (nicht über das Routing Mesh), sonst sieht der Proxy eine Mesh-Adresse. |

## nginx

Variante A: nginx **im Swarm** am selben Overlay-Netz (Ziel `timetrack_backend:8080`; die `resolver`-Zeile von Docker nötig, damit Neustarts des Backends nicht an alten IPs hängen).
Variante B: nginx auf dem Host: Dann ist das Overlay-Netz nicht erreichbar; Sie müssen in `stack.yaml` den auskommentierten `ports:`-Block (Host-Modus, z. B. `18080`) aktivieren und den Port per Firewall auf den Proxy begrenzen; Ziel dann `127.0.0.1:18080` bzw. die Host-Adresse. Nicht erprobt.

```nginx
# /etc/nginx/conf.d/timetrack.conf (Zertifikatspfade anpassen)
server {
    listen 80;
    listen [::]:80;
    server_name timetrack.example.org;
    return 301 https://$host$request_uri;       # gilt NICHT für ACME-Challenges, falls Sie HTTP-01 nutzen: dort ausnehmen
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name timetrack.example.org;

    ssl_certificate     /etc/letsencrypt/live/timetrack.example.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/timetrack.example.org/privkey.pem;
    add_header Strict-Transport-Security "max-age=31536000" always;

    client_max_body_size 70m;                   # 64 MiB Datei + Multipart-Aufschlag
    proxy_request_buffering off;                # Uploads nicht erst auf Platte puffern
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    resolver 127.0.0.11 valid=10s;              # Docker-DNS (nur nginx IM Swarm); auf dem Host weglassen
    set $upstream http://192.0.2.10:18080;     # Knoten-IP und PUBLISHED_PORT

    location = /health { return 404; }
    location = /ready  { return 404; }

    # Apple-Datei: unverändert durchreichen, kein Redirect, kein Auth, kein Cache-Header-Umbau.
    location = /.well-known/apple-app-site-association {
        proxy_pass $upstream;
        proxy_set_header Host $host;
    }

    location /api/ {
        proxy_pass $upstream;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_no_cache 1;
        proxy_cache_bypass 1;
    }

    location / {
        proxy_pass $upstream;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection        "";
    }
}
```

`X-Forwarded-For` mit `$proxy_add_x_forwarded_for` **anhängt** die Client-Adresse an einen vom Client mitgesendeten Wert; das Backend liest den Header von rechts und ignoriert vorangestellte Fälschungen, sofern `TRUSTED_PROXY_CIDRS` genau Ihren Proxy umfasst.
Steht ein weiterer Proxy (z. B. Cloudflare) davor, gehört dessen Netz ebenfalls in `TRUSTED_PROXY_CIDRS`.
Anmerkung: Der `location /`-Block liefert auch `/oauth/*`, `/mcp` und `/.well-known/oauth-*`; kein weiterer Block nötig.

## Traefik (v3, Swarm-Provider)

**Hinweis:** Die Label-Variante unten setzt voraus, dass Traefik im selben Swarm läuft und mit dem Backend ein Netz teilt (nicht Teil dieses Stacks). Mit dem veröffentlichten Port ist die dynamische Datei-Konfiguration einfacher: Router `Host(`timetrack.example.org`)` und ein Service mit `servers: - url: "http://192.0.2.10:18080"` (mehrere Knoten: mehrere `url`-Einträge).

Traefik liest Labels aus dem **Dienst** (im Swarm unter `deploy.labels`). Ergänzen Sie im Dienst `backend` in `stack.yaml` den vorhandenen `deploy:`-Block um `labels:` (Entrypoint- und Resolver-Namen an Ihre Traefik-Konfiguration anpassen):

```yaml
    deploy:
      labels:
        - traefik.enable=true
        - traefik.http.services.timetrack.loadbalancer.server.port=8080
        - traefik.http.routers.timetrack.rule=Host(`timetrack.example.org`) && !Path(`/health`) && !Path(`/ready`)
        - traefik.http.routers.timetrack.entrypoints=websecure
        - traefik.http.routers.timetrack.tls.certresolver=letsencrypt
        - traefik.http.routers.timetrack.middlewares=timetrack-headers
        - traefik.http.middlewares.timetrack-headers.headers.stsSeconds=31536000
```

(Die Labels gehören unter `deploy.labels`, nicht unter `labels:`: nur dort sieht sie der Swarm-Provider. Die Regel schließt `/health` und `/ready` von der Weiterleitung aus.)

Statische Traefik-Konfiguration (Auszug, beim Traefik-Dienst selbst):

```yaml
entryPoints:
  websecure:
    address: ":443"
    http:
      tls: {}
    transport:
      respondingTimeouts:
        readTimeout: 300s        # Uploads bis 64 MiB; Traefik v3 begrenzt das Lesen standardmäßig (Wert in Ihrer Version prüfen)
        writeTimeout: 300s
        idleTimeout: 180s
    forwardedHeaders:
      trustedIPs: []             # nur eintragen, wenn davor ein weiterer Proxy steht (dann dessen Netz)
```

Traefik setzt `X-Forwarded-For` und `X-Forwarded-Proto` selbst, begrenzt die Anfragegröße **nicht** (keine `buffering`-Middleware verwenden, außer mit `maxRequestBodyBytes` ≥ 70 MiB) und leitet `/.well-known/*` ohne Umschreiben weiter. HTTP/2 ist an TLS-Entrypoints standardmäßig an.
Das Traefik-Beispiel wurde **nicht** gegen eine laufende Traefik-Instanz getestet.

Damit Traefik die echte Client-IP sieht: Ports 80/443 des Traefik-Dienstes im **Host-Modus** veröffentlichen (`mode: host`), nicht über das Routing Mesh.

## Eigene Ratenbegrenzung am Proxy

Setzt du am Proxy eine Begrenzung (nginx `limit_req`/`limit_conn`, Traefik `rateLimit`, Cloudflare o. Ä.), plane großzügig:

- Eine geöffnete Seite löst **viele Anfragen in kurzer Zeit** aus (Oberfläche, Sitzung, Zeitabschnitte, Zeitkonto, Hinweise, Widgets und mehrere Geräte desselben Nutzers kommen von derselben Adresse).
- Ein zu niedriges Limit zeigt sich in der App als „**Zu viele Versuche. Bitte warte einen Moment.**" (HTTP 429 vom Proxy) oder als Seite, die sporadisch nicht lädt. Diese Meldung kann also vom Proxy stammen und nicht vom Backend. Das Backend begrenzt nur Anmelde-, Registrierungs- und Wiederherstellungsaufrufe (Konto 15, Adresse 60 je 5 Minuten) und schreibt dazu eine Warnung `rate limit …` ins Log; steht dort nichts, kam das 429 vom Proxy.
- Faustregel für nginx: `limit_req` mit `burst=100 nodelay` auf `/api/` statt eines harten Limits pro Verbindung. Ein Limit von mehreren hundert Anfragen pro Sekunde und Adresse ist für einen Einzelnutzer-Betrieb unproblematisch, die strengere Grenze gehört auf `/api/v1/auth/`.
- Das Backend sieht die echte Adresse nur mit `TRUSTED_PROXY_CIDRS` (siehe unten).

## TRUSTED_PROXY_CIDRS bestimmen

1. **Swarm:** Subnetz des `ingress`-Netzes (das Backend sieht hinter dem Routing Mesh diese Adresse als Verbindungspartner): `docker network inspect ingress --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'` (z. B. `10.0.0.0/24`).
2. **Compose:** Subnetz des Compose-Netzes (`docker network inspect timetrack_default --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'`; der Name folgt dem Projektnamen `timetrack`). Prüfe nach dem Start mit dem Rate-Limit-Test aus dem Betrieb-Dokument, ob die Client-Adresse ankommt.
3. Zugriffsrechte beachten: Vertrauen Sie nur dem Netz, in dem **ausschließlich der Proxy** Verbindungen zum Backend aufbauen kann. Hängen weitere Dienste im selben Netz, legen Sie ein eigenes Netz nur für Proxy und Backend an, oder tragen Sie die feste Proxy-Adresse als `/32` ein.
4. In `.env` bzw. `.env`: `TRUSTED_PROXY_CIDRS=10.0.0.0/24`, `TRUSTED_PROXY_HEADER=X-Forwarded-For`, neu ausrollen (siehe [Aktualisieren](../UPDATE.md)).
5. Prüfen: Rate-Limit-Verhalten, siehe [Betrieb](../BETRIEB.md), Abschnitt 6, Schritt 3. Ohne die Einstellung teilen sich **alle** Clients einen Zähler (60 Ereignisse je 5 Minuten): ein Angreifer sperrt die Anmeldung für alle. Pro Konto gilt zusätzlich eine eigene Grenze (15 je 5 Minuten).

## TRUSTED_PROXY_HEADER: X-Forwarded-For oder X-Real-IP

Standard ist `X-Forwarded-For`. Das Backend liest die Liste **von rechts** und übernimmt den ersten Eintrag, der nicht zu einem vertrauenswürdigen Proxy gehört. Vom Client mitgeschickte Einträge links davon werden nie gelesen. Der Proxy darf den Header anhängen (nginx `$proxy_add_x_forwarded_for`, Traefik, Caddy) oder ersetzen.

`X-Real-IP` ist nur sicher, wenn der Proxy den Header **bei jeder Anfrage überschreibt**. Das Backend übernimmt den einen Wert von einem vertrauenswürdigen Verbindungspartner unverändert. Reicht der Proxy einen vom Client gesendeten `X-Real-IP` durch (oder setzt ihn nur, wenn er fehlt), kann jeder Client seine Adresse frei wählen und damit die Ratenbegrenzung je Adresse umgehen.

- nginx: `proxy_set_header X-Real-IP $remote_addr;` (überschreibt immer).
- Traefik und Caddy setzen `X-Real-IP` nicht von sich aus zuverlässig; verwende dort `X-Forwarded-For`.
- Steht davor ein weiterer Proxy (z. B. ein CDN), muss **jeder** vertrauenswürdige Hop den Header überschreiben oder `X-Forwarded-For` genutzt werden.

### Gruppen-Links (`/g/…`, `/api/v1/public/groups/…`)

Freigabelinks des Gruppenmoduls (ADR-0033) tragen ihr Geheimnis im Pfad `/g/<token>` (Seite) und `/api/v1/public/groups/<token>/…` (API). Wie bei den Auslöse-Links gilt: Zugriffsprotokolle des Proxys dürfen diese Pfade nicht im Klartext enthalten. Ein geleakter Link erlaubt Namenseinträge bis zu den Grenzen, aber keinen Zugriff auf Konten; der Besitzer kann den Link jederzeit erneuern.

### Auslöse-Links (`/t/…`) und Zugriffsprotokolle

Auslöse-Links (ADR-0027) tragen ihr Geheimnis im Pfad `GET /t/<token>/<aktion>`. Das Backend protokolliert diesen Pfad nicht, ein Reverse Proxy normalerweise schon. Schwärzen Sie den Pfad `/t/` im Zugriffsprotokoll des Proxys oder protokollieren Sie ihn nicht (z. B. Traefik: `accessLog.filters`/Feldschwärzung für `RequestPath`; nginx: eigenes `log_format` ohne `$request_uri` für diesen `location /t/`). Wer Zugriff auf solche Protokolle hat, könnte sonst Links benutzen; ein Link lässt sich im Profil sofort widerrufen.

Ist `TRUSTED_PROXY_HEADER=X-Real-IP` mit `TRUSTED_PROXY_CIDRS` gesetzt, schreibt das Backend beim Start einmal eine Warnung mit diesem Hinweis ins Log. Im Zweifel `X-Forwarded-For` verwenden.

## Apple App Site Association

Für Passkeys in den Apple-Apps muss `APPLE_APP_IDS` gesetzt sein und der Proxy die Datei unverändert durchreichen. Erzeugung, Prüfbefehle (inklusive Apples CDN) und Fehlerbilder: [Deployment-Anleitung](../DEPLOYMENT.md), Abschnitt 11.
