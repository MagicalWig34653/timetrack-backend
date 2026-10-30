# ADR-0033: Gruppenmodul – öffentliche Umfragen und Gruppenbestellungen

Status: Umsetzungsentscheidung von Paket G1 (Backend); Lead-Prüfung offen. Beruht auf einer ausdrücklichen Nutzeranforderung (Terminumfragen wie Nuudel, allgemeine Umfragen, Bestellrunden wie „Dönerstag“, jeweils per Link ohne Anmeldung).

## Kontext

Bisher ist jede Funktion an ein angemeldetes Konto gebunden. Das Gruppenmodul braucht Teilnehmer ohne Konto: Wer den Link kennt, sieht die Umfrage oder Bestellrunde und trägt sich mit einem Anzeigenamen ein. Es ist die erste Oberfläche mit Schreibzugriff ohne Anmeldung und damit sicherheitsrelevant (ADR-0027 kennt nur Auslöse-Links mit sehr begrenzter Wirkung).

## Entscheidungen

### 1. Besitzer und Teilnehmer

Anlegen, Ändern, Beenden, Löschen, Linkerneuerung und Katalogverwaltung sind Besitzeraktionen unter `/api/v1/groups/…` (Sitzung + CSRF, Modul `groups`, nicht über Bearer/MCP; MCP bleibt bewusst ausgespart, damit keine KI unauthentifizierte Zugänge erzeugt, wie bei ADR-0027). Teilnehmer nutzen ausschließlich `/api/v1/public/groups/{token}/…`. Die PWA-Seite `/g/<token>` ist eine SPA-Route ohne Anmeldung.

### 2. Link-Token

- 32 Zufallsbytes (256 Bit, base64url, 43 Zeichen); nur der SHA-256-Hash liegt in der Datenbank (`token_hash`, eindeutig). Der Klartext steht in der Antwort des Anlegens und von `rotate-token`. **Nachtrag g1b (30.10.2026, Vertrag 0.37.1):** Damit der Besitzer den Link jederzeit erneut ansehen und kopieren kann, liegt das Token zusätzlich in `link_token` (Klartext, wie die Auslöse-Token nach ADR-0030 ohne Ausgabe in Listen, Exporten oder Protokollen) und erscheint in der Besitzer-Detailansicht; Listen, öffentliche Ansichten und Kontoexport enthalten es weiterhin nie. Die Suche läuft unverändert über den Hash. Zeilen von vor g1b haben kein `link_token`; dort zeigt die Detailansicht keinen Link, bis `rotate-token` aufgerufen wurde. Abwägung: Wer die Datenbank lesen kann, sieht damit auch die Links (und ohnehin Umfrageinhalt und Anzeigenamen); Bearbeitungsschlüssel bleiben Hashes.
- Suche über den Hash (kein Vergleich des Geheimnisses in der Datenbank), danach zusätzlich Vergleich mit konstantem Zeitaufwand (`Secrets.equal`). Falsche Länge oder Zeichen werden vor der Suche verworfen.
- `rotate-token` ersetzt den Hash: der alte Link gilt sofort nicht mehr (404), Stimmen, Einträge und Bearbeitungsschlüssel bleiben.
- Ein Token führt zu **einer** Umfrage oder Runde (Hash-Räume getrennt abgefragt). Unbekannt, erneuert, gelöscht, falscher Typ für den Endpunkt, deaktivierter Besitzer und abgeschaltetes Modul sind ununterscheidbar 404 (das Betreiber-Modul meldet zusätzlich `module_disabled`, weil die Sperre keine Konteninformation preisgibt).

### 3. Bearbeitungsschlüssel (edit secret)

Jede Stimme und jeder Bestelleintrag bekommt beim Anlegen einen eigenen 256-Bit-Schlüssel, der **einmal** in der Antwort steht (`editSecret`) und serverseitig nur als SHA-256-Hash gespeichert wird. Der Client (PWA: `localStorage` je Token) sendet ihn als Header `X-Edit-Secret` zum Ändern und Löschen der eigenen Stimme bzw. des eigenen Eintrags. Fehlender oder falscher Schlüssel: 403 `edit_secret_invalid` (Vergleich konstant). Wer den Schlüssel verliert, kann nicht mehr ändern; der Besitzer kann jede Stimme und jeden Eintrag entfernen. „Gericht übernehmen“ legt einen **neuen** Eintrag mit eigenem Namen und Schlüssel an (Kopie von Gericht, Preis, Notiz); der Quelleintrag bleibt unberührt.

Der Anzeigename ist kein Konto: er ist je Umfrage eindeutig (ohne Beachtung von Groß-/Kleinschreibung und Leerraum), damit sich niemand unbemerkt als eine andere Person ausgibt; bei Bestelleinträgen darf derselbe Name mehrere Einträge haben (mehrere Gerichte pro Person).

### 4. Öffentliche Angriffsfläche und Missbrauchsschutz

- Nur JSON, CSV und `text/plain`; keine Auslieferung von Nutzereingaben als HTML. Eingaben: getrimmt, ohne Steuerzeichen und bidirektionale Überschreibungszeichen; Längen in Unicode-Skalaren (Spalten sind VARCHAR/utf8mb4).
- Grenzen: Name ≤ 60, Text/Gericht/Notiz/Option ≤ 200, Titel ≤ 120, Beschreibung ≤ 2000, ≤ 50 Optionen, ≤ 500 Stimmen je Umfrage (409 `group_full`), ≤ 200 Einträge je Runde, Menge 1–99, Preis 0–1.000.000 Cent, ≤ 200 Umfragen/Runden und 30 Kataloge (200 Gerichte) je Konto. Anfragekörper: Vapor-Standard 16 kB für öffentliche Routen (128 kB für Anlegen von Umfragen und Katalogen).
- Ratenbegrenzung über `rate_limit_events` (Aufräumjob vorhanden): je Client-Adresse (nach Trusted-Proxy-Regeln, IPv6 als /64) 300 Zugriffe und 40 Schreibzugriffe je 5 Minuten, je Link 150 Schreibzugriffe je 5 Minuten, 30 Fehlversuche (unbekannter Link, falscher Bearbeitungsschlüssel) je Client und 5 Minuten, danach 429 mit `Retry-After`. Schreibzugriffe laufen in der serialisierten Transaktion (`AuthService.transaction`), damit Grenzen und Namensprüfung nicht per Wettlauf umgangen werden. Der Durchsatz ist damit durch die globale `auth_lock` begrenzt (ADR-0017), für Gruppenlasten (Dutzende Teilnehmer) ausreichend.
- Antworten (auch Fehler) tragen `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow` und `Referrer-Policy: no-referrer`; das gilt auch für die SPA-Route `/g/…`. Der Konsolen-Log-Schwärzer ersetzt Token in `/g/<token>` und `/api/v1/public/groups/<token>` (Zweitsicherung; die Anwendung protokolliert keine Pfade). Proxy-Zugriffsprotokolle des Betreibers müssen diese Pfade schwärzen (Hinweis in `installation/proxy.md`).
- Keine Kontodaten: die öffentliche Ansicht enthält weder Besitzername, Handle noch IDs des Besitzers; `id`/`catalogId`/Zeitstempel erscheinen nur in der Besitzeransicht. Teilnehmer sehen Anzeigenamen der anderen Teilnehmer (so ist Umfrage und Bestellliste gemeint).
- CSRF entfällt für die öffentlichen Routen (kein Cookie, Token im Pfad, Schlüssel im Header); ein mitgesendetes Sitzungs-Cookie wird dort ignoriert. Besitzerrouten verlangen Sitzung und CSRF wie alle `/me`-Routen.

### 5. Abstimmungsregeln

- `single`: genau ein `yes`, kein `maybe`. `multi` bei Textumfragen: mindestens ein `yes`. Terminumfragen (`kind=date`): je Option `yes`/`maybe`/`no`, `multi` darf alles `no` sein; `single` verlangt genau ein `yes`. Unbekannte oder doppelte Optionen sind 400 `answers_invalid`. „no“ wird als fehlende Zeile gespeichert.
- Beendet (manuell oder Frist verstrichen) sind Stimmen und Einträge nicht mehr änderbar (409 `group_closed`); der Besitzer kann weiter entfernen. `reopen` hebt das Beenden auf und entfernt eine bereits verstrichene Frist. Die Optionen einer Umfrage sind nach dem Anlegen unveränderlich (keine nachträglich entwertete Stimme).
- `hideResults`: Solange offen, enthält die öffentliche Ansicht nur `voteCount`; nach dem Beenden erscheinen Stimmen und Auszählung. Der Besitzer sieht immer alles. (Stimmen werden nicht verschlüsselt: der Server kennt sie; der Schalter verbirgt sie vor Teilnehmern.)
- Der Besitzer kann eine endgültige Option festlegen (beendet die Umfrage) und zurücknehmen.

### 6. Bestellrunden, Katalog, Export

Einträge: Name, Gericht, optional Notiz, Menge, Preis in Cent. Die Zusammenfassung gruppiert gleiche Gerichte (Text, Notiz und Preis ohne Beachtung von Groß-/Kleinschreibung und Leerraum), summiert die Menge und nennt die Namen. Summen: Menge mal Preis der bepreisten Einträge, Stückzahl ohne Preis getrennt. Kataloge gehören dem Konto; die Gerichte des gewählten Katalogs erscheinen in der Runde als Vorschläge (öffentliche Ansicht ohne `catalogId`). Löschen eines Katalogs löst nur die Zuordnung. „Frühere Gerichte merken“ ist als Besitzer-Vorschlag umgesetzt (`GET /groups/orders/suggestions`, häufigste Gerichte der letzten 50 Runden); teilnehmerbezogene Erinnerung bleibt clientseitig.
Export (`csv`/`txt`, Besitzer und Teilnehmer): CSV nach RFC 4180 über den gemeinsamen `CSVWriter`; Zellen, die mit `=`, `+`, `-`, `@`, Tab oder CR beginnen, erhalten ein Apostroph (ADR-0006), Antwort mit `Content-Disposition: attachment` und `nosniff`.

### 7. Aufbewahrung

Beendete oder abgelaufene Umfragen und Runden löscht der bestehende Aufräumjob (`MaintenanceService`, Lease `maintenance`, Schritte `group_polls`, `group_orders`) `GROUPS_RETENTION_DAYS` Tage (Standard 90, 1–3650) nach `closed_at` bzw. nach der Frist (bei manuell beendeten nach dem Beenden), samt Optionen, Stimmen, Antworten und Einträgen. Offene Elemente ohne Frist werden nie automatisch gelöscht; erneutes Öffnen setzt die Uhr zurück. Der Besitzer kann jederzeit löschen.

### 8. Modulschalter, Export, Löschung

Neuer Modulschlüssel `groups` (ADR-0012): Betreiber-Override `MODULES_DISABLED=groups`, Serverschalter und Kontoschalter. Abgeschaltet sind die Besitzer-API **und** die öffentlichen Links des Besitzers (Kontoschalter) bzw. der ganzen Instanz (Server). Kontoexport enthält `polls.json`, `orders.json`, `catalogs.json` (Teilnehmernamen als eingegebene Anzeigenamen, nie Token, Hashes oder Schlüssel); Kontolöschung entfernt alle Bäume (`AccountEraser`, Reihenfolge Kinder zuerst, zusätzlich zu `ON DELETE CASCADE`); Sperren eines Kontos macht seine Links sofort wirkungslos (Besitzerprüfung bei jedem Zugriff).

## Alternativen

- Token im Query-Parameter (landet häufiger in Protokollen; verworfen, wie ADR-0027). Ein einziges Token für Ansicht und Bearbeitung (jeder Teilnehmer könnte fremde Einträge ändern; verworfen). Bearbeitungsschlüssel als Cookie (nicht über Geräte tragbar, Cookies auf der API-Domain wären mit der Sitzung vermischt; Header + `localStorage` gewählt). Schreibzugriffe ohne Serialisierung (Grenzen und Namenseindeutigkeit wären per Wettlauf umgehbar). Captcha (zu viel Reibung, kein Drittanbieter gewünscht; Ratenbegrenzung + Token-Geheimnis genügen für den Zweck, Restrisiko siehe unten).

## Folgen und Restrisiken

Vertrag 0.37.0, Migration `g1.create_groups`. Wer den Link kennt, kann Namen eintragen (Spam bis zu den Grenzen); Gegenmittel: Ratenbegrenzung, Stimme entfernen, Link erneuern, beenden. Der Link steht in Verlauf und Chats seiner Empfänger. Anzeigenamen sind frei wählbar und nicht verifiziert. Details und PWA-Anforderungen: `docs/handoffs/G1-backend.md`. Betroffen: `docs/ARCHITEKTUR.md` (Abschnitt Gruppenmodul), `docs/installation/proxy.md`, `CHANGELOG.md`.
