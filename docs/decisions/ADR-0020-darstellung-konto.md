# ADR-0020: Darstellung (Akzentfarbe, Farbschema) je Konto

Status: akzeptiert als Umsetzungsentscheidung von Paket P2 (Nutzerentscheidung 16.10.2026: Akzent und Farbschema gehören zum Konto, damit PWA und native Apple-Apps sie teilen); Lead-Prüfung offen. Alles unten, was nicht aus dieser Entscheidung folgt, sind Annahmen des Pakets.

## Kontext

Die PWA speicherte Akzentfarbe, Farbschema und Transparenz nur im Browser (ADR-0014, DESIGN.md „Akzentfarbe“ nannte „zusätzlich optional im Konto“). Die nativen Apps speichern Akzent und Schema lokal je Gerät (`appearance.accent`, `appearance.customHex`, `appearance.scheme`, DESIGN-NATIVE.md „Akzent-System“). Der Nutzer will eine Auswahl, die auf allen Geräten gilt. Das App-Symbol bleibt eine Gerätewahl, ebenso die Transparenz (sie folgt dem System bzw. einem Gerätemerker).

## Entscheidungen

1. **Eigene Endpunkte statt Erweiterung von `/me/profile`** (Vertrag v0.14.0, additiv): `GET /me/preferences` und `PATCH /me/preferences`. Das Profil (ADR-0019) beschreibt Identität (Name, Handle, Adresse, Einrichtungsmerker); Darstellung ist anderer Art, wird von Clients häufiger und unabhängig geschrieben und soll später weitere Schlüssel aufnehmen, ohne das Profil-DTO und dessen Validierung zu berühren. Nicht modulgebunden (ADR-0012: Kern), nur normale Sitzungen (Recovery-Sitzung 403, ohne Sitzung 401). Kein Konto-Bezug in Pfad oder Body.
2. **Felder**: `accent` (`blue|teal|violet|green|orange|pink|graphite|custom`), `accentCustomHex` (`#RRGGBB`, nur bei `custom`, sonst `null`), `colorScheme` (`system|light|dark`), `updatedAt` (Zeitpunkt der letzten Änderung, fehlt solange die Standardwerte gelten). Standardwerte ohne gespeicherte Daten: `blue`, `system`. Es gibt keine Zeile pro Konto, die angelegt werden müsste.
3. **Speicherung**: eine validierte JSON-Spalte `accounts.preferences` (Fluent `.json`, SQLite und MariaDB), `NULL` = Standardwerte. Die Spalte liegt am Konto: die Sitzungsantwort lädt das Konto ohnehin, die Kaskade beim Löschen (`AccountEraser`) braucht keinen neuen Eintrag (keine neue Tabelle mit Konto-Bezug, der B1-Schematest bleibt unverändert grün). Vorhandene Konten behalten `NULL`; die Migration `p2.add_account_preferences` schreibt keine Zeilen um. Künftige Schlüssel kommen als weitere optionale Felder des Swift-Typs `AccountPreferences` und der Whitelist hinzu, nie als freie Daten.
4. **PATCH ist ein Merge-Patch**: nur gesendete Schlüssel ändern sich. Erlaubt sind genau `accent`, `accentCustomHex`, `colorScheme`; jeder andere Schlüssel, ein leerer Body, falsche Typen oder unbekannte Werte ergeben 400 `bad_request` (strikt, nichts wird still ignoriert; anders als `PATCH /me/profile`, das unbekannte Felder ignoriert). Ein Body über 1 KiB ergibt 413 `payload_too_large`. Regeln für die Farbe: `accent=custom` verlangt nach dem Zusammenführen einen gültigen `accentCustomHex` (genau `#` plus sechs Hexziffern, Groß-/Kleinschreibung egal, gespeichert und geliefert in Großbuchstaben); bei jedem anderen Akzent ist der Wert `null`. Ein Wechsel auf eine Voreinstellung löscht ihn; ihn zusammen mit einer Voreinstellung zu senden oder allein, solange der Akzent nicht `custom` ist, ist 400. Ein fehlgeschlagener PATCH ändert nichts.
5. **Sitzungsantwort**: `GET /auth/session` enthält `account.preferences` (gleiche Form), damit Clients beim Start keinen zusätzlichen Aufruf brauchen. `GET /me/preferences` bleibt für gezieltes Neulesen (z. B. beim Öffnen der Darstellungsseite).
6. **Keine frische Sitzung, kein Audit**: geringes Risiko, reine Darstellung. Ein besonderes Rate-Limit gibt es nicht (wie `PATCH /me/profile`); der Body ist auf 1 KiB begrenzt, ein PATCH schreibt eine Zeile unter der Transaktion der Sitzungsprüfung.
7. **Export**: `GET /me/export` enthält `preferences.json` (Standardwerte, solange nichts gespeichert ist).
8. **Abgleich (Konfliktregel)**: letzter Schreiber gewinnt, serverseitig ohne Versionsprüfung. Clients halten einen lokalen Cache (PWA: localStorage, Apps: UserDefaults) zum sofortigen Anwenden und für den Offline-Fall. Genaue Regeln für Clients: `docs/handoffs/P2.md`, Abschnitt „Vertrag für native Clients“.
9. **Voreinstellungs-IDs sind Vertragsnamen, keine Farbwerte**: Jeder Client ordnet sie seinen eigenen Farbtönen zu (PWA: Blau #2563EB, Türkis #0D9488, Violett #7C3AED, Grün #16A34A, Orange #D97706, Rosa #DB2777, Graphit #52525B). Die PWA-Voreinstellungen „Bernstein“, „Rosé“ und „Schiefer“ wurden dafür zu `orange`, `pink` und `graphite` (Farbton von Rosé und Schiefer ändert sich, Bernstein bleibt); eine frühere lokale Wahl wird beim ersten Abgleich übernommen (siehe PWA-Handoff).

## Alternativen

- Felder in `/me/profile` und `account.preferences` nur dort: verworfen (Entscheidung 1).
- Eigene Tabelle `account_preferences` (eine Zeile je Konto, Schlüssel-Wert oder typisierte Spalten): verworfen; zusätzlicher Eintrag in `AccountEraser`, zusätzliches Laden in der Sitzungsantwort, kein Vorteil bei drei Feldern. Typisierte Spalten am Konto (`accent`, `accent_custom_hex`, `color_scheme`): verworfen, weil jeder künftige Schlüssel eine Migration bräuchte; das validierte JSON hat dieselbe Strenge über den Swift-Typ.
- Serverseitige Farbwerte für Voreinstellungen: verworfen; die Hex-Werte sind Gestaltung der Clients (Kontrastableitung je Plattform).
- ETag/If-Match für Konfliktfreiheit: nicht nötig für Darstellung; `updatedAt` genügt Clients als Abgleichshilfe.

## Folgen und offene Punkte

- Native Apps: Umstellung auf diese Endpunkte ist ein späteres Paket (Vertrag in `docs/handoffs/P2.md`); bis dahin bleiben ihre lokalen Werte unabhängig vom Konto.
- Wer die PWA mit einem älteren Server nutzt (ohne `account.preferences`), behält das alte, rein lokale Verhalten.
- Das Gerät, das zuerst nach dem Update anmeldet, überträgt seine bisherige lokale Wahl ins Konto, falls das Konto noch nie gesetzt wurde (nur wenn der lokale Cache nicht für ein anderes Konto geschrieben wurde). Mehrere Geräte mit unterschiedlichen lokalen Altwerten: das erste gewinnt, die übrigen übernehmen das Kontoergebnis.
