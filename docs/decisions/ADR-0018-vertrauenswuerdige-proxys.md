# ADR-0018: Vertrauenswürdige Proxys und Client-Adresse für Rate-Limits

Status: akzeptiert (Paket B4, Lead-Prüfung offen). Stand: 16.10.2026.

## Kontext

Rate-Limits (Auth-Middleware, OAuth, OIDC) nutzten `req.remoteAddress`. Hinter dem Reverse Proxy (BETRIEB.md) ist das immer der Proxy:
ein gemeinsamer Zähler für alle Clients, Anmeldesperre für alle durch einen Angreifer. Forwarded-Header blind zu lesen wäre schlimmer
(ein Angreifer wechselt die Adresse nach Belieben und umgeht jede Grenze).

## Entscheidung

- Neue Konfiguration `TRUSTED_PROXY_CIDRS` (kommagetrennte IPv4/IPv6-Adressen oder CIDR-Netze, Standard leer = niemand) und `TRUSTED_PROXY_HEADER` (`X-Forwarded-For` Standard, oder `X-Real-IP`). Ungültige Werte sind ein Startfehler mit Schlüsselnamen.
- Eine zentrale Auflösung `Request.clientAddress` bzw. `Request.clientRateLimitKey` (`TrustedProxies.swift`); alle vier Aufrufstellen (`AuthRateLimitMiddleware`, `OAuthRoutes`, `OIDCRoutes`) nutzen sie. Direkter Zugriff auf `remoteAddress` oder Forwarded-Header ist nicht mehr vorgesehen. Audit- oder Gerätetabellen speichern keine IP; weitere Verbraucher sind nicht vorhanden.
- Gegenstelle nicht vertrauenswürdig: Header ignorieren. Vertrauenswürdig: `X-Forwarded-For` von rechts lesen, vertrauenswürdige Hops überspringen, die erste nicht vertrauenswürdige Adresse nehmen. Fehlender, fehlerhafter oder nur aus vertrauenswürdigen Hops bestehender Header: Gegenstelle. Ein fehlerhafter Eintrag bricht die Auswertung ab (kein Raten).
- IPv4-gemappte IPv6 wird zu IPv4. Rate-Limit-Schlüssel: IPv6 nach /64, IPv4 pro Adresse. Der Schlüssel wird weiterhin gehasht gespeichert (`ip:<Hash>`); keine Schemaänderung.

## Alternativen

- `req.peerAddress` von Vapor: liest `X-Forwarded-For` von links ohne Vertrauensprüfung, spoofbar.
- Anzahl vertrauenswürdiger Hops statt CIDRs: bricht bei wechselnder Proxy-Kette und liefert bei zu kleiner Zahl vom Angreifer gesetzte Werte.
- /128-Schlüssel für IPv6: ein Anschluss mit /64 umgeht die Grenze trivial. Nachteil von /64: Nutzer im selben /64 teilen einen Zähler (selten, z. B. Rechenzentren).

## Folgen

- Betreiber müssen hinter einem Proxy `TRUSTED_PROXY_CIDRS` setzen, sonst bleibt der gemeinsame Zähler. Vertraut man ein zu weites Netz (z. B. ein Overlay, in dem andere Dienste Verbindungen aufbauen können), kann dort jeder Teilnehmer die Adresse fälschen. Der Proxy muss `X-Forwarded-For` anhängen oder überschreiben.
- Keine API-Änderung (Vertrag unverändert).
- Offen: Test gegen einen echten Proxy und Swarm-Overlay; CGNAT-Nutzer teilen weiterhin einen IPv4-Zähler.
