# ADR-0011: C19 – Speicherbindung, OAuth und Push-Härtung

Status: akzeptiert gemäß Reparaturauftrag vom 15.10.2026. Ergänzt ADR-0006, ADR-0009 und ADR-0010;
Prüfstand und Einschränkungen in [C19](../handoffs/C19.md). Vertrag v0.8.0 bleibt unverändert.

## Entscheidungen

- Jede Datei erhält `storage_location`: `db`, kanonischer lokaler Wurzelpfad oder S3-Endpoint plus Bucket.
  Die Migration bindet vorhandene Dateien an die zum Migrationszeitpunkt konfigurierte Location.
  Ein lokaler ursprünglicher Pfad bleibt unabhängig von späteren Einstellungen verwendbar. Bei S3 muss
  die aktuelle Konfiguration dieselbe Location identifizieren; alte Zugangsdaten werden nicht zusätzlich archiviert.
  Ein Konfigurationswechsel bleibt erlaubt. Nicht erreichbare bzw. nicht mehr konfigurierte Originale liefern
  503 `storage_unavailable`; fehlgeschlagenes Löschen bewahrt Metadaten, Zustand `deleting` und Retry-Marker.
  Wiederherstellen der Originalkonfiguration ermöglicht den vorhandenen Cleanup. Es gibt keine automatische Umlagerung.
- OAuth-Codeaustausch prüft Ablauf, Client, Redirect, Resource und PKCE vor jeder Zustandsänderung.
  Auch ein falscher Verifier beim richtigen öffentlichen Client verbraucht den Code nicht: eine Client-ID allein
  beweist keine Client-Bindung. Nur ein unexpired, vollständig gebundener Replay widerruft den Grant.
  Die gegenteilige C16-Handoff-Regel ist damit ersetzt.
- `/oauth/token` hat einen prozesslokalen Sliding-Window-Limiter vor `auth_lock`: 120 Anfragen pro Client
  und IP/Client-Paar in fünf Minuten, 1200 pro Peer-IP. Letzteres berücksichtigt geteilte Connector-IPs.
  Malformed Bodies zählen zum IP-Budget. Unbekannte bzw. formal ungültige Codes/Refresh-Tokens erreichen die
  globale Transaktion nicht; bekannte Tokens werden in der Transaktion erneut geprüft.
- Push-Endpunkte: HTTPS, Port 443, Host-Allowlist. Standard: `fcm.googleapis.com`,
  `*.push.services.mozilla.com`, `*.notify.windows.com`, `web.push.apple.com`, `*.push.apple.com`.
  `PUSH_ALLOWED_HOSTS` ersetzt die Liste (kommagetrennt; `*.` erlaubt Subdomains).
  IP-Literale und lokale/reservierte Namen sind unzulässig. Vor jeder echten HTTP-Zustellung werden alle
  DNS-Antworten auf öffentliche Adressen geprüft. AsyncHTTPClient verbindet über `dnsOverride` mit einer
  geprüften numerischen Adresse und behält TLS-SNI, Zertifikatsprüfung und Host des ursprünglichen Endpunkts;
  Redirects bleiben verboten. HTTP-Loopback ist nur über das nicht umgebungssteuerbare Testfeld
  `NotificationOptions.pushAllowInsecureLoopback` erlaubt.
- Der Push-Runner erneuert seine Lease während der gesamten Arbeit. Vor jeder weiteren Zustellung prüft er
  die Eigentümerschaft. Jede Outbox-Zeile wird zusätzlich atomar mit einem zufälligen Claim-Token übernommen;
  Statusänderungen sind an dieses Token gebunden. Claims werden während langer Zustellungen erneuert;
  fünf Minuten alte Claims sind wieder übernehmbar. Ein Prozessabsturz nach externer Zustellung und vor
  Status-Commit kann weiterhin eine Wiederholung erzeugen (kein Exactly-once-Versprechen gegenüber HTTP).
- Vor jedem Zustellversuch werden aktives Konto, aktuelle Kategorie, aktuelle Modellzeitzone und Ruhezeit
  erneut gelesen. Deaktivierte Pushes werden als fehlgeschlagen verworfen; Ruhezeiten verschieben erneut.
- Pro Tick werden höchstens 200 abgeschlossene/fehlgeschlagene Outbox-Zeilen gelöscht, deren Abschluss
  mehr als 14 Tage zurückliegt. Pro Konto bleiben höchstens 200 wartende Zeilen; älteste unbeanspruchte
  Zeilen werden zuerst entfernt. Notification-Dedup-Schlüssel bleiben bestehen.

## Alternativen und Folgen

Konfigurationswechsel zu blockieren würde die Vorgabe des Reparaturauftrags verletzen. Alte S3-Secrets
zu archivieren wäre eine zusätzliche Schlüsselverwaltung und wird vermieden. Die konservative 503-Antwort
bei wechselndem S3-Ziel bewahrt das Original und erlaubt einen nachvollziehbaren Retry.

Globale DB-Limits vor jedem Tokenversuch würden die angegriffene Auth-Serialisierung selbst belasten;
der Prozess-Limiter begrenzt diese Last vorher. Er ist nicht instanzübergreifend und wird bei Neustart zurückgesetzt.

Neue Migrationen: `BindStorageLocations`, `HardenPushOutbox`; keine Änderungen bestehender Migrationen
oder neue Abhängigkeiten. SQLite-Spaltenänderungen erfolgen einzeln.
