# Lizenzinventar C4

Stand: 19.10.2026 (Paket L3: OpenSSL-Altlizenz eingegrenzt, Lösungswege und Ausnahme-Entwurf, XKCP geprüft, `THIRD-PARTY-NOTICES` im Image, Betriebssystempakete inventarisiert; Pins unverändert 43); Paket S1b: Abschnitt „Kette BoringSSL / swift-crypto / NIOSSL im Laufzeit-Image“ ergänzt, Pins unverändert); 17.10.2026 (Paket D3: SwiftPM-Pins gegen `Package.resolved` abgeglichen, 43 Pins unverändert; npm-Abschnitt neu ausgezählt, Website und Apple-Repo ergänzt; die Texte der übrigen Pakete stammen aus C4, 14.10.2026, und D1, 15.10.2026). Projektlizenz: `AGPL-3.0-only`. Paket P14 (26.10.2026, APNs-Push): keine neue Abhängigkeit; der HTTP/2-Client nutzt das bereits eingebundene AsyncHTTPClient (Apache-2.0) und swift-crypto, Pins unverändert.

## SwiftPM

Alle 43 Pins aus `Package.resolved` (42 aus C4 plus `zipfoundation` seit C11); Lizenztexte aus den lokalen Checkouts vollständig eingelesen, identische Texte verglichen. Die Spalte Quelle ist relativ zu `.build/checkouts/`. Versionen und Revisionen stammen aus dem Lockfile; Checkout-HEADs wurden dagegen geprüft. „Direkt“ bezieht sich auf `Package.swift` (neun direkte Pakete: `swift-nio`, `swift-nio-ssl`, `vapor`, `fluent`, `fluent-mysql-driver`, `fluent-sqlite-driver`, `webauthn-swift`, `Argon2Swift`, `ZIPFoundation`); NIO und NIOSSL sind seit C3 direkt eingebunden (SMTP), waren aber schon vorher transitiv vorhanden. `ZIPFoundation` kam mit C11 (ADR-0006) hinzu; die Zeile ist anhand des lokalen Checkouts (`LICENSE`, HEAD gleich Lockfile-Revision) am 15.10.2026 ergänzt.

| Package | Art | Version / Branch | Revision | SPDX aus Lizenzdatei | Quelle |
| --- | --- | --- | --- | --- | --- |
| `argon2swift` | direkt | `main` | `53543623fefe68461b7eeea03d7f96677c2fd76d` | `MIT` | `Argon2Swift/LICENSE` |
| `async-http-client` | transitiv | `1.36.2` | `4c005f955e83f888d5616e579717a36d2dfc6301` | `Apache-2.0` | `async-http-client/LICENSE.txt` |
| `async-kit` | transitiv | `1.22.0` | `6bbb83cbf9d886623a967a965c8fb1b73e6566f9` | `MIT` | `async-kit/LICENSE` |
| `console-kit` | transitiv | `4.16.1` | `15121e1ec44a0a2064e43545d1390f02cc19b07d` | `MIT` | `console-kit/LICENSE` |
| `fluent` | direkt | `4.13.0` | `2fe9e36daf4bdb5edcf193e0d0806ba2074d2864` | `MIT` | `fluent/LICENSE` |
| `fluent-kit` | transitiv | `1.57.0` | `ca609b2132bde05f9a2d7561e2864587c24fa7b9` | `MIT` | `fluent-kit/LICENSE` |
| `fluent-mysql-driver` | direkt | `4.8.0` | `4d8f31af2a84bdbb69fbf9f4acc12cbf2f47814b` | `MIT` | `fluent-mysql-driver/LICENSE` |
| `fluent-sqlite-driver` | direkt | `4.9.0` | `e227d94dc3fe7099a096ac2ca28cad1f69bd8d5b` | `MIT` | `fluent-sqlite-driver/LICENSE` |
| `multipart-kit` | transitiv | `4.7.1` | `3498e60218e6003894ff95192d756e238c01f44e` | `MIT` | `multipart-kit/LICENSE` |
| `mysql-kit` | transitiv | `4.10.1` | `ff5687172ffe348a974f6db1a61925b33ce8684b` | `MIT` | `mysql-kit/LICENSE` |
| `mysql-nio` | transitiv | `1.9.1` | `7fa853040169b604a16b963f23b481772f4ac181` | `MIT` | `mysql-nio/LICENSE` |
| `phc-winner-argon2` | transitiv | `master` | `f57e61e19229e23c4445b85494dbf7c07de721cb` | `CC0-1.0 OR Apache-2.0` | `phc-winner-argon2/LICENSE` |
| `routing-kit` | transitiv | `4.9.3` | `1a10ccea61e4248effd23b6e814999ce7bdf0ee0` | `MIT` | `routing-kit/LICENSE` |
| `sql-kit` | transitiv | `3.36.0` | `3779cedb44b1f374f2cca261c6d28f206024a582` | `MIT` | `sql-kit/LICENSE` |
| `sqlite-kit` | transitiv | `4.5.2` | `f35a863ecc2da5d563b836a9a696b148b0f4169f` | `MIT` | `sqlite-kit/LICENSE` |
| `sqlite-nio` | transitiv | `1.13.1` | `c1756f42cbc03c13f191cb44730757a313149410` | `MIT` | `sqlite-nio/LICENSE` |
| `swift-algorithms` | transitiv | `1.2.1` | `87e50f483c54e6efd60e885f7f5aa946cee68023` | `Apache-2.0 WITH Swift-exception` | `swift-algorithms/LICENSE.txt` |
| `swift-asn1` | transitiv | `1.7.3` | `3b6410f7dee09eb33cdd26260c5fd47fda19b0e2` | `Apache-2.0` | `swift-asn1/LICENSE.txt` |
| `swift-async-algorithms` | transitiv | `1.1.7` | `13713a4ffdee8abd929f92568ee9462a46ae26e0` | `Apache-2.0 WITH Swift-exception` | `swift-async-algorithms/LICENSE.txt` |
| `swift-atomics` | transitiv | `1.3.1` | `0442cb5a3f98ab802acb777929fdb446bda11a34` | `Apache-2.0 WITH Swift-exception` | `swift-atomics/LICENSE.txt` |
| `swift-certificates` | transitiv | `1.21.0` | `ff86b924ead66f853b8baf91f3c41926a8f36177` | `Apache-2.0` | `swift-certificates/LICENSE.txt` |
| `swift-collections` | transitiv | `1.7.3` | `35a1edcb8ebd2bfe251d587f0b69e62af28f508c` | `Apache-2.0 WITH Swift-exception` | `swift-collections/LICENSE.txt` |
| `swift-configuration` | transitiv | `1.2.2` | `8bae88f79dbddec793390c5bf3e2abb4ac2ece42` | `Apache-2.0` | `swift-configuration/LICENSE.txt` |
| `swift-crypto` | transitiv | `4.5.2` | `da9d28d69ebe3894b18376c8f2395c2f37b8448f` | `Apache-2.0` | `swift-crypto/LICENSE.txt` |
| `swift-distributed-tracing` | transitiv | `1.7.0` | `c64975080075bff170b728704a7e151f15f541c0` | `Apache-2.0` | `swift-distributed-tracing/LICENSE.txt` |
| `swift-http-structured-headers` | transitiv | `1.7.0` | `933538faa42c432d385f02e07df0ace7c5ecfc47` | `Apache-2.0` | `swift-http-structured-headers/LICENSE.txt` |
| `swift-http-types` | transitiv | `1.8.0` | `bff4b6903cdc99dda49649dd52f46c11cfd3ed50` | `Apache-2.0` | `swift-http-types/LICENSE.txt` |
| `swift-log` | transitiv | `1.16.1` | `4038b6a4f74a1426f47eb1dd5b4bb5628a15d597` | `Apache-2.0` | `swift-log/LICENSE.txt` |
| `swift-metrics` | transitiv | `2.12.0` | `9467f9cc3c32b4386fad1ecc4618328887ef5758` | `Apache-2.0` | `swift-metrics/LICENSE.txt` |
| `swift-nio` | direkt | `2.104.0` | `6db9d9abd92ad7399b8a564cafbb87d3507245fa` | `Apache-2.0` | `swift-nio/LICENSE.txt` |
| `swift-nio-extras` | transitiv | `1.35.1` | `41449336c8ecfadac6b4b5be75f9c3c306e61ced` | `Apache-2.0` | `swift-nio-extras/LICENSE.txt` |
| `swift-nio-http2` | transitiv | `1.46.0` | `0f3e54e29c944c2e835ad52159da7d9e1c94ac69` | `Apache-2.0` | `swift-nio-http2/LICENSE.txt` |
| `swift-nio-ssl` | direkt | `2.37.5` | `322f3c2a4a21df31c84ca416bf65ee5e9059e440` | `Apache-2.0` | `swift-nio-ssl/LICENSE.txt` |
| `swift-nio-transport-services` | transitiv | `1.28.0` | `67787bb645a5e67d2edcdfbe48a216cc549222d5` | `Apache-2.0` | `swift-nio-transport-services/LICENSE.txt` |
| `swift-numerics` | transitiv | `1.1.1` | `0c0290ff6b24942dadb83a929ffaaa1481df04a2` | `Apache-2.0 WITH Swift-exception` | `swift-numerics/LICENSE.txt` |
| `swift-service-context` | transitiv | `1.5.0` | `014d2485dc62d6258521db1adcf12baceb2c136a` | `Apache-2.0` | `swift-service-context/LICENSE.txt` |
| `swift-service-lifecycle` | transitiv | `2.12.1` | `c55297914e26ce3085b73ca88c521ef99136f6ad` | `Apache-2.0` | `swift-service-lifecycle/LICENSE.txt` |
| `swift-system` | transitiv | `1.8.1` | `869129b7bf4ecc57b97d0193ad29690ca2134750` | `Apache-2.0 WITH Swift-exception` | `swift-system/LICENSE.txt` |
| `swiftcbor` | transitiv | `0.6.0` | `fd929a6d8f7651ce0f63fc99397fd5762358cc29` | `Unlicense` | `SwiftCBOR/UNLICENSE` |
| `vapor` | direkt | `4.122.2` | `33e61d0a02a9ddc9f025f8398a0dc24774f6cbe1` | `MIT` | `vapor/LICENSE` |
| `webauthn-swift` | direkt | `1.0.0-beta.1` | `909cf4193cde7d64196553c4245ab647a68aaaca` | `Apache-2.0` | `webauthn-swift/LICENSE` |
| `websocket-kit` | transitiv | `2.16.2` | `90bbbdab3ede12c803cfbe91646f291c092517a3` | `MIT` | `websocket-kit/LICENSE` |
| `zipfoundation` | direkt | `0.9.20` | `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` | `MIT` | `ZIPFoundation/LICENSE` |

### Bewertung und Sonderfälle

Die erfassten Hauptlizenzen `MIT` und `Apache-2.0` sind mit dem AGPLv3-Projekt vereinbar; BSD-2-/3-Clause und ISC ebenfalls. Die sechs Apache-Lizenzen mit `Swift-exception` enthalten zusätzlich eine Runtime-Ausnahme, keine zusätzliche Einschränkung. Lizenz- und Copyright-Pflichten bleiben bei der Weitergabe zu beachten. Grundlage: [GNU-Lizenzübersicht](https://www.gnu.org/licenses/license-list.html).

- `SwiftCBOR`: **Sonderfall `Unlicense`**, anhand `UNLICENSE` bestätigt; laut GNU GPL-kompatibel, keine unbekannte Lizenz.
- `Argon2Swift`: **unstabile Branch-Abhängigkeit `main`**, im Lockfile auf obige Revision fixiert. Updates können API und transitive Revisionen verändern. Vor Updates gezielt testen und Inventar erneuern.
- `phc-winner-argon2`: Branch `master`, ebenfalls revisionsfixiert. `LICENSE` erlaubt ausdrücklich `CC0-1.0 OR Apache-2.0`. Für die Bewertung kann Apache-2.0 gewählt werden. Auch `Argon2Swift/Sources/Argon2/LICENSE` enthält diesen dualen C-Lizenztext.
- **Offener Lizenzbefund: eingebettetes BoringSSL in `swift-nio-ssl`.** Die Hauptlizenz Apache-2.0 deckt keine pauschale Freigabe aller eingebetteten Quellen ab. `NOTICE.txt` nennt ISC und OpenSSL; `Sources/CNIOBoringSSL/crypto/crypto.cc` enthält ISC-Bedingungen, `Sources/CNIOBoringSSL/include/CNIOBoringSSL_base.h` verweist ausdrücklich auf die OpenSSL-Lizenz. Im Checkout fehlt eine separate BoringSSL-LICENSE-Datei. Die alte `OpenSSL`-Lizenz ist laut [GNU-Lizenzübersicht](https://www.gnu.org/licenses/license-list.html#OpenSSL) GPL-inkompatibel. Daher **keine vollständige AGPL-3.0-only-Veröffentlichungsfreigabe** aus diesem Inventar ableiten: genaue Lizenzabdeckung und eventuell erforderliche Ausnahme durch Rechteinhaber vor Release klären. C3 ändert die bestehende Projektlizenz nicht; NIOSSL war bereits transitiv enthalten. **Stand L3:** siehe Abschnitt „Lösungswege für die OpenSSL-Altlizenz“ unten; das Upstream-`main` von `swift-nio-ssl` enthält bereits eine BoringSSL-Revision ohne diese Altlizenz, nur noch nicht als Release.

### Kette BoringSSL / swift-crypto / NIOSSL im Laufzeit-Image (Paket S1b, 19.10.2026)

Geprüft anhand `Package.resolved` (43 Pins, unverändert gegenüber D3), der lokalen Checkouts von `swift-nio-ssl` 2.37.5 und `swift-crypto` 4.5.2 sowie des `Dockerfile`. Es gibt **zwei getrennte, eingebettete BoringSSL-Kopien** und eine Keccak-Kopie; die frühere Fassung dieses Inventars nannte nur die erste.

| Bestandteil | Eingebettet in | Lizenzköpfe der Quelldateien (gezählt, Quelltext `.c/.cc/.h/.S`) | Bewertung |
| --- | --- | --- | --- |
| `CNIOBoringSSL` | `swift-nio-ssl` (`type: .static`, direkt eingebunden für TLS/SMTP; zusätzlich über Vapor und AsyncHTTPClient) | 323 Dateien „Licensed under the OpenSSL license“ (OpenSSL/SSLeay-Altlizenz), 200 ISC, 1 CC0/Public Domain (`poly1305_arm_asm.S`), 119 ohne Kopf (überwiegend generierte Header) | **Offener Befund bleibt:** Die Altlizenz „OpenSSL“ ist laut GNU GPL-inkompatibel. Eine eigene BoringSSL-`LICENSE`-Datei liegt im Checkout nicht bei; `NOTICE.txt` verweist auf „Combination ISC and OpenSSL license“. |
| `CCryptoBoringSSL` | `swift-crypto` (auf Linux die Implementierung von `Crypto`; Abhängigkeit von Vapor, `webauthn-swift`, `swift-certificates`) | 491 Dateien „Licensed under the Apache License, Version 2.0“, 1 CC0 (`poly1305_arm_asm.S`), 129 ohne Kopf (`.inc`-Prüfwerte u. a.), **keine** Datei mit OpenSSL-Altlizenz oder Eric-Young-Hinweis (0 Treffer). Neuere BoringSSL-Revision (`0226f304…`) | Apache-2.0, mit AGPL-3.0 vereinbar. Bisher im Inventar nicht aufgeführt; `NOTICE.txt` und `README.md` von `swift-crypto` nennen BoringSSL und XKCP als Drittanteile. |
| `CXKCP` (Keccak, FIPS 202) | `swift-crypto` | 16 Dateien unter `Sources/CXKCP/FIPS202-opt64` (Herkunft XKCP `master`, `vendored-sources.txt`), Köpfe im Checkout gelesen (L3, 19.10.2026): 13 mit dem XKCP-Hinweis „To the extent possible under law, the implementer has waived all copyright“ (CC0-Verzicht), `brg_endian.h` mit dem Gladman-Kopf (Brian Gladman, 1998-2008; BSD-artig: Quellcode- **und Binärverteilungen müssen Copyright-Hinweis, Bedingungen und Haftungsausschluss in der Dokumentation wiedergeben**), `config.h` und `KeccakP-1600-opt64-config.h` ohne Kopf; `include/CXKCP.h` Apache-2.0 (SwiftCrypto) | CC0 und BSD-artig, mit AGPL-3.0 vereinbar. Die Gladman-Binärpflicht wird durch den Abschnitt „vendored sources“ von `swift-crypto` in `THIRD-PARTY-NOTICES` erfüllt (Skript hängt den Kopf von `brg_endian.h` an). Die beiden Dateien ohne Kopf stammen laut `vendored-sources.txt` aus XKCP (ungeprüft gegen Upstream). |

Im Image landen beide BoringSSL-Kopien als **statisch gelinkter Bestandteil** der Binärdatei `App` (Build-Stufe `swift build -c release --product App`, Laufzeit-Stufe `swift:6.3-noble-slim`, kein Node und kein separater OpenSSL-Bezug des Backends). Konsequenzen:

- Mit dem Image wird Binärcode mit der OpenSSL-Altlizenz ausgeliefert (über `CNIOBoringSSL`). Deren Werbeklausel und Attributionspflichten verlangen Beilage der Texte (siehe unten) und sind der Grund, warum die Aussage „AGPL-3.0-only ohne Einschränkung“ weiterhin nicht belegt ist. Das Projekt ändert seine Lizenz deswegen nicht; die Klärung (Einschätzung von `swift-nio-ssl`/Apple oder eine rechtliche Prüfung) bleibt vor einem Release mit Binärverteilung offen.
- `swift-crypto` als Apache-2.0-BoringSSL-Kopie ist unkritisch, braucht aber Lizenzbeilage und Hinweis auf BoringSSL/XKCP in `NOTICE`-Form.
- Die Beilage (L3, 19.10.2026): Das Image enthält `/usr/share/doc/timetrack/LICENSE` und `/usr/share/doc/timetrack/THIRD-PARTY-NOTICES` (Lizenz- und NOTICE-Texte aller 43 Pins wörtlich, Revisionen der vendorten BoringSSL-Kopien, Auszug `copyright` aller dpkg-Pakete). Erzeugt von `scripts/third-party-notices.sh` im `Dockerfile` (Build-Stufe für SwiftPM, Laufzeit-Stufe für dpkg), außerdem als Release-Asset (`release.yml`). Die Per-Datei-Köpfe der 323 OpenSSL-lizenzierten BoringSSL-Dateien bleiben im Quellcode-Angebot.
- Betriebssystempakete des Laufzeit-Images (Basis `swift:6.3-noble-slim` plus `ca-certificates`, `libsqlite3-0`, `tzdata`, `curl` samt Abhängigkeiten) sind seit L3 inventarisiert: Das Image-Build schreibt die `copyright`-Dateien aller dpkg-Pakete in `THIRD-PARTY-NOTICES` (Teil 2). Es sind Debian/Ubuntu-Pakete unter überwiegend GPL/LGPL/BSD/MIT/Public-Domain-Lizenzen; sie sind nicht in `App` gelinkt (außer `libsqlite3-0`, `libc`, Swift-Laufzeit dynamisch; keine Kopplung mit dem Projektcode im Sinne eines Derivats), das Image ist eine Aggregation. Beim Weitergeben des Images gelten für GPL/LGPL-Pakete deren Quellcode-Angebote (Ubuntu-Quellpakete); `curl` ist nur Healthcheck. Die Swift-Laufzeitbibliotheken (Apache-2.0 mit Runtime Library Exception) stammen aus der Basis und werden nicht einzeln aufgelistet.

### Lösungswege für die OpenSSL-Altlizenz (Paket L3, 19.10.2026)

Keine Rechtsberatung; die Entscheidung liegt beim Rechteinhaber. Geprüft anhand der Quellen, nicht geraten:

- **Befund bestätigt (Checkout `swift-nio-ssl` 2.37.5):** `Sources/CNIOBoringSSL` (BoringSSL-Revision `817ab07e…`, `hash.txt`) enthält 323 Quelldateien mit „Licensed under the OpenSSL license“ (Header „Copyright 1995-2016 The OpenSSL Project Authors“, Verweis auf `openssl.org/source/license.html`), 0 mit Apache-Kopf und 0 mit „Eric Young“-Text. Die Altlizenz (OpenSSL plus SSLeay, mit Werbeklausel) gilt laut GNU als GPL-inkompatibel. `swift-nio-ssl` 2.37.5 ist zugleich das **neueste Release** (17.09.2026).
- **Upstream hat das Problem bereits behoben, aber nicht freigegeben:** `apple/swift-nio-ssl` `main` (Stand 12.10.2026, drei Commits nach 2.37.5; „Update BoringSSL to 8eb25be6…“, #607) enthält 534 Dateien mit „Licensed under the Apache License, Version 2.0“, 0 mit „OpenSSL license“, 0 mit „Eric Young“ (flacher Klon des `main`-Stands gezählt). Auch die `swift-crypto`-Kopie (Revision `0226f304…`) hat schon im Pin 4.5.2 keine Altlizenzdateien. BoringSSL/OpenSSL stehen demnach seit einer neueren Revision durchgängig unter Apache-2.0 (OpenSSL 3.x ist Apache-2.0; AGPL-3.0 ist damit vereinbar).
- **Weg A (empfohlen): Abhängigkeit aktualisieren.** Sobald `swift-nio-ssl` ein Release nach 2.37.5 mit BoringSSL `8eb25be6…` oder neuer veröffentlicht, `Package.resolved` aktualisieren, `scripts/third-party-notices.sh` neu laufen lassen, in diesem Inventar nachzählen (`grep -rl "OpenSSL license" Sources/CNIOBoringSSL` muss 0 ergeben) und den Befund schließen. Überbrückung bis dahin: `Package.swift` auf die Revision von `main` pinnen (`.package(url:…, revision: "<sha>")`); das ist eine instabile Quelle und nur nach Abwägung des Rechteinhabers vor einem Release sinnvoll. Nicht umgesetzt (Abhängigkeitsänderung ist nicht Teil von L3).
- **Weg B: gegen ein System-OpenSSL 3 bauen.** `swift-nio-ssl` bringt sein BoringSSL fest mit; ein Wechsel auf ein Systempaket (`libssl3`, Apache-2.0) hieße, TLS/SMTP auf eine andere Bibliothek umzustellen oder `swift-nio-ssl` zu forken. Aufwand und Risiko hoch; nur wenn Weg A nicht verfügbar ist.
- **Weg C: Ausnahme nach AGPL §7.** Entwurf in [`LICENSE-EXCEPTION.md`](../LICENSE-EXCEPTION.md) (**Vorschlag, nicht in Kraft**, `LICENSE` unverändert). Sie erlaubt das Verlinken mit OpenSSL-lizenziertem Code für das Projekt, entbindet aber nicht von den Pflichten der OpenSSL-Lizenz (Werbeklausel, Attribution; abgedeckt durch `THIRD-PARTY-NOTICES`). Braucht Zustimmung aller Urheberrechtsinhaber und eine juristische Prüfung.
- **Entscheidung des Rechteinhabers:** A (Warten oder `main`-Pin), C (Ausnahme übernehmen) oder beides; solange nichts entschieden ist, ist die Veröffentlichung von Binärdateien/Images mit 2.37.5 nicht freigegeben.

### NOTICE und Attribution

Apache-2.0 verlangt insbesondere Lizenzbeilage, Erhalt relevanter Copyright-/Patent-/Attributionshinweise, Kennzeichnung geänderter Dateien und Übernahme relevanter NOTICE-Inhalte in lesbarer Form. MIT/BSD/ISC-Hinweise ebenfalls mitliefern. Eine Tabelle ersetzt die Originaltexte nicht. Die Swift-Ausnahme nur dort anwenden, wo ihre Voraussetzungen tatsächlich erfüllt sind.

Folgende NOTICE-Dateien wurden lokal eingelesen (einschließlich Verweisen auf eingebettete Drittanteile):

- `async-http-client/NOTICE.txt`
- `sqlite-nio/NOTICES.txt`
- `swift-asn1/NOTICE.txt`
- `swift-certificates/NOTICE.txt`
- `swift-configuration/NOTICE.txt`
- `swift-crypto/NOTICE.txt`
- `swift-http-types/NOTICE.txt`
- `swift-log/NOTICE.txt`
- `swift-metrics/NOTICE.txt`
- `swift-nio/NOTICE.txt`
- `swift-nio-extras/NOTICE.txt`
- `swift-nio-http2/NOTICE.txt`
- `swift-nio-ssl/NOTICE.txt`
- `swift-service-context/NOTICE.txt`
- `swift-service-lifecycle/NOTICE.txt`
- `vapor/NOTICES.txt`
- `webauthn-swift/NOTICE.txt`
- `websocket-kit/NOTICES.txt`

Besonders beachten: NIO-/TLS-NOTICE verweist auf Netty und weitere Ableitungen; NIOSSL zusätzlich auf BoringSSL; SwiftCrypto auf Wycheproof/SwiftNIO; SwiftCertificates auf Webpki, ASN.1, pyca/cryptography und musl. Die jeweiligen Texte einschließlich der zutreffenden Drittanteile in die spätere Auslieferung übernehmen. Nicht jeder Test-/Generatoranteil landet im Binary; die tatsächliche Artefaktzuordnung ist noch offen.

## PWA / npm

Stand 17.10.2026 (Paket D3, maschinell aus dem Lockfile ausgezählt, nicht erneut manuell geprüft): `timetrack-pwa/package-lock.json`, lockfileVersion `3`, SHA-256 `822d01885c7a590b03d6c00936a845133c74c8f1fe6569f363c4d3e616349bc9`. Gezählt werden **393 Lockfile-Pfade** (ohne Root-Projekt), einschließlich Plattformpakete und mehrfacher Versionen; alle Abhängigkeiten sind Entwicklungs-/Build-Abhängigkeiten (`devDependencies`: SvelteKit, Svelte, Vite, Tailwind, Vitest, Playwright, Testing Library, `exceljs` für Test-Leser, Schriftpaket Inter, Icons `@lucide/svelte` u. a.). Ausgeliefert wird nur der statische Build. Gegenüber dem Stand 15.10. (201 Pfade) kamen u. a. `exceljs` samt Abhängigkeiten und Playwright-Ausbau hinzu. Das `license`-Feld fehlt bei einem Eintrag (`buffers` 0.1.1, ungeprüft). Diese Metadaten sind keine vollständige Quellcode-Lizenzprüfung.

| SPDX (Lockfile-Angabe) | Anzahl Lockfile-Einträge |
| --- | ---: |
| `MIT` | 325 |
| `MPL-2.0` | 24 |
| `ISC` | 16 |
| `Apache-2.0` | 12 |
| `BSD-3-Clause` | 4 |
| `BSD-2-Clause` | 2 |
| `MIT-0` | 2 |
| `BlueOak-1.0.0` | 1 |
| `CC0-1.0` | 1 |
| `OFL-1.1` | 1 |
| `Unlicense` (`big-integer`) | 1 |
| `MIT/X11` (`chainsaw`) | 1 |
| `(MIT OR GPL-3.0-or-later)` (`jszip`) | 1 |
| `(MIT AND Zlib)` (`pako`) | 1 |
| kein Feld (`buffers`) | 1 |

`jszip` (Dual-Lizenz, MIT wählbar) und `pako` sind Abhängigkeiten von `exceljs` und nur in Tests der PWA verwendet; nicht in der Auslieferung (ungeprüft, dass sie nicht gebündelt werden).

### Laufzeit-Abhängigkeiten der PWA: Urlaubsantrag (Pakete P6/P8, 19.10.2026)

Anders als der Rest der PWA-Abhängigkeiten gehören diese beiden Pakete zu den `dependencies` und landen **im ausgelieferten Bundle** (als eigene, erst bei Bedarf geladene Chunks; der Service Worker legt sie vor):

| Paket | Version | Lizenz | Verwendung | Hinweis |
| --- | --- | --- | --- | --- |
| `pdf-lib` | 1.17.1 | MIT | PDF-Felder lesen und ausfüllen, Textpositionen setzen, Flatten, im Browser | **Seit Jahren nicht mehr gepflegt** (letzte Version 2021). Risiko: keine Sicherheits- oder Kompatibilitätskorrekturen für neue PDF-Varianten; es verarbeitet nur das eigene, vom Nutzer hochgeladene Formular im Browser (nichts geht an Dritte), das Risiko beschränkt sich damit auf Fehlfunktion bei ungewöhnlichen PDFs und auf die transitiven Pakete. Ersatz bei Bedarf: der gepflegte Fork `@cantoo/pdf-lib` (MIT, gleiche API). Transitiv: `@pdf-lib/standard-fonts` 1.0.0 (MIT), `@pdf-lib/upng` 1.0.1 (MIT), `pako` 1.0.11 (MIT AND Zlib), `tslib` 1.14.1 (0BSD). |
| `pdfjs-dist` | 6.4.299 | Apache-2.0 | Seitenvorschau im Browser (Haupt-Chunk und Worker) | Gepflegt (Mozilla). Optionale Abhängigkeit `@napi-rs/canvas` wird im Browser nicht benötigt. Das Paket enthält Datenverzeichnisse (`standard_fonts`, `cmaps`, `iccs`) mit eigenen Schrift-/Datenlizenzen (u. a. Foxit, Liberation); die App verweist nicht darauf, ob sie im Build landen, ist vor dem Release zu prüfen. Apache-2.0 verlangt die Beilage von Lizenztext und NOTICE im Bundle. |

Beide sind mit AGPL-3.0-only vereinbar (permissive Lizenzen). Die Lockfile-Zählung oben (393 Pfade, Stand D3) enthält diese Pakete noch nicht; bei der nächsten Neuauszählung sind sie als Laufzeit- statt Build-Abhängigkeiten zu führen. Die echte Arbeitgeber-Vorlage ist kein Teil des Repositories; Tests verwenden synthetische PDFs.

### Nicht-permissive Einträge (vollständig)

| Lockfile-Pfad | Version | SPDX |
| --- | --- | --- |
| `node_modules/@fontsource-variable/inter` | `5.3.0` | `OFL-1.1` |
| `node_modules/lightningcss` | `1.32.0` | `MPL-2.0` |
| `node_modules/lightningcss-android-arm64` | `1.32.0` | `MPL-2.0` |
| `node_modules/lightningcss-darwin-arm64` | `1.32.0` | `MPL-2.0` |
| `node_modules/lightningcss-darwin-x64` | `1.32.0` | `MPL-2.0` |
| `node_modules/lightningcss-freebsd-x64` | `1.32.0` | `MPL-2.0` |
| `node_modules/lightningcss-linux-arm-gnueabihf` | `1.32.0` | `MPL-2.0` |
| `node_modules/lightningcss-linux-arm64-gnu` | `1.32.0` | `MPL-2.0` |
| `node_modules/lightningcss-linux-arm64-musl` | `1.32.0` | `MPL-2.0` |
| `node_modules/lightningcss-linux-x64-gnu` | `1.32.0` | `MPL-2.0` |
| `node_modules/lightningcss-linux-x64-musl` | `1.32.0` | `MPL-2.0` |
| `node_modules/lightningcss-win32-arm64-msvc` | `1.32.0` | `MPL-2.0` |
| `node_modules/lightningcss-win32-x64-msvc` | `1.32.0` | `MPL-2.0` |
| `node_modules/vite/node_modules/lightningcss` | `1.33.0` | `MPL-2.0` |
| `node_modules/vite/node_modules/lightningcss-android-arm64` | `1.33.0` | `MPL-2.0` |
| `node_modules/vite/node_modules/lightningcss-darwin-arm64` | `1.33.0` | `MPL-2.0` |
| `node_modules/vite/node_modules/lightningcss-darwin-x64` | `1.33.0` | `MPL-2.0` |
| `node_modules/vite/node_modules/lightningcss-freebsd-x64` | `1.33.0` | `MPL-2.0` |
| `node_modules/vite/node_modules/lightningcss-linux-arm-gnueabihf` | `1.33.0` | `MPL-2.0` |
| `node_modules/vite/node_modules/lightningcss-linux-arm64-gnu` | `1.33.0` | `MPL-2.0` |
| `node_modules/vite/node_modules/lightningcss-linux-arm64-musl` | `1.33.0` | `MPL-2.0` |
| `node_modules/vite/node_modules/lightningcss-linux-x64-gnu` | `1.33.0` | `MPL-2.0` |
| `node_modules/vite/node_modules/lightningcss-linux-x64-musl` | `1.33.0` | `MPL-2.0` |
| `node_modules/vite/node_modules/lightningcss-win32-arm64-msvc` | `1.33.0` | `MPL-2.0` |
| `node_modules/vite/node_modules/lightningcss-win32-x64-msvc` | `1.33.0` | `MPL-2.0` |

`MPL-2.0` ist dateibezogenes Copyleft. Die 24 Einträge sind Lightning CSS 1.32.0/1.33.0 einschließlich Plattformvarianten. Kombination unter AGPLv3 ist unter den Bedingungen von §3.3 möglich, sofern keine Kennzeichnung „Incompatible With Secondary Licenses“ greift. Die Lockfile-Angabe allein prüft diese Voraussetzung nicht; Quellangebot, konkrete Quellen/Marker und Verteilung der Buildwerkzeuge bleiben vor Release zu prüfen. [Mozilla MPL-FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/), [MPL 2.0](https://www.mozilla.org/en-US/MPL/2.0/).

`@fontsource-variable/inter` ist eine OFL-1.1-Schrift. Die vorhandene `node_modules/@fontsource-variable/inter/LICENSE` wurde zusätzlich gelesen und bestätigt Inter-Copyright/OFL. Bündelung mit der PWA ist möglich; Schrift behält OFL, Copyright und Lizenz müssen mitgeliefert werden. Änderungen/Reserved Font Names separat beachten; keine pauschale Umlizenzierung der Schrift auf AGPL. [Offizielle OFL-FAQ](https://openfontlicense.org/ofl-faq/).

Weitere Sonderkennungen: `MIT-0` (zwei @csstools-Pakete) ist permissiv ohne MIT-Attributionspflicht; `BlueOak-1.0.0` (`lru-cache` 11.5.3) ist eine permissive Lizenz; `CC0-1.0` (`mdn-data` 2.27.1) ist eine Public-Domain-Freigabe mit Auffanglizenz. Diese Angaben wurden aus dem Lockfile übernommen, die vollständigen Paketquellen nicht geprüft.

### Verifiziert und offen

- Stand 15.10.2026 abgeglichen (D1): Tabelle gegen `Package.resolved` (43 Pins, Versionen und Revisionen identisch), `ZIPFoundation`-Lizenztext (MIT, kein NOTICE). Stand 17.10.2026 (D3): Pin-Namen und -Versionen erneut gegen `Package.resolved` abgeglichen (43, unverändert); npm-Lockfile der PWA hat sich verändert (393 Einträge), neu ausgezählt. Alles Übrige unten stammt aus C4.
- Verifiziert: sämtliche SwiftPM-Pins, Checkout-Revisionen und Hauptlizenztexte; lokale NOTICE-Dateien; Argon2-C-Duallizenz; sämtliche npm-Lizenzfelder und obige Zählung, einschließlich aller MPL-/OFL-Einträge.
- Offen: vollständiger Audit eingebetteter C-/Assembly-/Testanteile, BoringSSL/OpenSSL-Kompatibilitätsklärung, konkrete npm-Quelllizenzen jenseits der Metadaten und Inter-Lizenz, MPL-Marker, Fonts/Icons außerhalb des Lockfiles, Lizenzbeilagen und Attribution im tatsächlichen PWA-/Container-/Binary-Release.
- Betriebssystembibliotheken, Container-Basisimages und Swift-Toolchain sind nicht Teil von Package.resolved und hier nicht inventarisiert. Keine Abhängigkeiten oder PWA-Dateien für C4 verändert.
- Ergebnis: Hauptpakete weitgehend kompatibel; **Release-Prüfung bleibt wegen BoringSSL und der genannten Auslieferungspflichten offen**.

## Website (`site/`, nur Entwicklungswerkzeug)

`site/package-lock.json` (VitePress 1.6.4, Vue 3.5.44, `@redocly/cli` 1.34.5 als Dev-Werkzeuge; lockfileVersion `3`): **426 Lockfile-Pfade**, maschinell ausgezählt am 17.10.2026: `MIT` 357, `BSD-3-Clause` 21, `Apache-2.0` 19, `ISC` 19, `BSD-2-Clause` 4, `CC0-1.0` 1 (`@iconify-json/simple-icons`), `Python-2.0` 1 (`argparse`), `BSD` 1 (`url-template`), `(MPL-2.0 OR Apache-2.0)` 1 (`dompurify`), ohne `license`-Feld 2 (`decko`, `stickyfill`; ungeprüft). Die Website wird zur Build-Zeit erzeugt und als statisches HTML auf GitHub Pages veröffentlicht; die Werkzeuge werden nicht ausgeliefert. Die API-Referenz wird mit Redocly erzeugt (`site/scripts/build-api.mjs`); ob und welche Redocly-Teile in die erzeugte Seite gelangen, ist nicht geprüft. Dependabot schlägt Updates vor (Redocly 2.x, Vue u. a.), nicht ungeprüft übernehmen.

## Apple-Repo

`timetrack-apple` hat **keine externen Swift-Abhängigkeiten**: die lokalen Pakete `TimetrackCore` und `TimetrackDesign` (eigener Code, AGPL-3.0-only) hängen nur voneinander und von Apple-Frameworks ab; es gibt kein `Package.resolved`. Schriften: Systemschriften. XcodeGen (lokales Werkzeug, 2.46.0) ist kein Bestandteil des Produkts. App-Symbole sind eigene Gestaltung. Prüfung der Lizenz von Apple-SDK-Bestandteilen und der App-Store-Bedingungen im Zusammenspiel mit AGPL-3.0: **offen** (vor einer App-Store-Veröffentlichung rechtlich klären; keine Rechtsberatung in diesem Dokument).

## Release-Prüfung

Stand L3 (19.10.2026). Checkliste vor jedem Release mit Binärverteilung (Image, Binary):

- [ ] **OpenSSL-Altlizenz:** Entscheidung des Rechteinhabers (Weg A/B/C oben). Nachweis: `grep -rl "OpenSSL license" .build/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL | wc -l` ergibt 0 (Weg A), oder `LICENSE-EXCEPTION.md` ist als in Kraft gesetzt dokumentiert (Weg C). **Derzeit offen: 323.**
- [ ] `Package.resolved` gegen dieses Inventar abgleichen (Pins, Versionen); bei Änderungen Tabelle und Zählungen erneuern.
- [x] XKCP-Dateiköpfe in `swift-crypto` geprüft (CC0, Gladman-BSD-artig, Apache); Gladman-Hinweis wird in `THIRD-PARTY-NOTICES` mitgeliefert.
- [x] `THIRD-PARTY-NOTICES` im Image (`/usr/share/doc/timetrack/`) und als Release-Asset; vor dem Release prüfen, dass das Asset 43 Pakete enthält (`grep -c '^Package:'`).
- [x] Betriebssystempakete des Images im Notices-Teil 2 (dpkg `copyright`); bei Änderung der Basis-Image-Version Stichprobe auf GPL/LGPL-Pakete und Quellcode-Angebot.
- [ ] PWA-Build: Lizenztexte von `pdf-lib` (MIT), `pdfjs-dist` (Apache-2.0, inkl. NOTICE) und ihren transitiven Paketen sowie prüfen, ob pdf.js-Datenverzeichnisse im Build liegen (neu P8); npm-Lizenztexte und die OFL-Schrift (Inter) im ausgelieferten Bundle beilegen (liegt im PWA-Repo; hier nicht umgesetzt). Lockfile-Zählung vom 19.10.2026 stimmt mit der Tabelle oben überein (393 Pfade, gleiche Verteilung; Lockfile-Hash hat sich seit 17.10. geändert).
- [ ] Apple-Apps: keine externen Swift-Abhängigkeiten laut Inventar; Repo war bei L3 lokal nicht auffindbar, Stand nicht erneut verifiziert.
- [ ] MPL-Marker (Lightning CSS, nur Build-Werkzeug), Quellcode-Lizenzprüfung der npm-Pakete über die Metadaten hinaus (unverändert offen).

## Entscheidung zur OpenSSL-Lizenz von swift-nio-ssl (19.10.2026)

Nutzerentscheidung: **Weg A**. Auf ein `swift-nio-ssl`-Release warten, das BoringSSL ab Revision `8eb25be6` enthält (Apache-2.0 statt alter OpenSSL-Lizenz), dann `Package.resolved` aktualisieren und die Dateien neu zählen. Kein Pinning eines `main`-Standes, keine Ausnahmeerklärung (`LICENSE-EXCEPTION.md` bleibt ein ungenutzter Entwurf).

Stand 19.10.2026: Neueste Version 2.37.5 (17.09.2026) enthält noch die alte Lizenz. Auf `main` ist BoringSSL seit Commit #607 (09.10.2026) aktualisiert, ein Release fehlt noch. Vor jedem Release prüfen: `gh api repos/apple/swift-nio-ssl/releases --jq '.[0].tag_name'`. Bis dahin sind Binär-Releases und Images mit 2.37.5 lizenzrechtlich nicht freigegeben.
