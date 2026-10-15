# Lizenzinventar C4

Stand: 15.10.2026 (Paket D1 hat Lockfile, Manifest und das npm-Lockfile erneut abgeglichen; die Texte der übrigen Pakete stammen aus C4, 14.10.2026). Projektlizenz: `AGPL-3.0-only`.

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
- **Offener Lizenzbefund: eingebettetes BoringSSL in `swift-nio-ssl`.** Die Hauptlizenz Apache-2.0 deckt keine pauschale Freigabe aller eingebetteten Quellen ab. `NOTICE.txt` nennt ISC und OpenSSL; `Sources/CNIOBoringSSL/crypto/crypto.cc` enthält ISC-Bedingungen, `Sources/CNIOBoringSSL/include/CNIOBoringSSL_base.h` verweist ausdrücklich auf die OpenSSL-Lizenz. Im Checkout fehlt eine separate BoringSSL-LICENSE-Datei. Die alte `OpenSSL`-Lizenz ist laut [GNU-Lizenzübersicht](https://www.gnu.org/licenses/license-list.html#OpenSSL) GPL-inkompatibel. Daher **keine vollständige AGPL-3.0-only-Veröffentlichungsfreigabe** aus diesem Inventar ableiten: genaue Lizenzabdeckung und eventuell erforderliche Ausnahme durch Rechteinhaber vor Release klären. C3 ändert die bestehende Projektlizenz nicht; NIOSSL war bereits transitiv enthalten.

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

Read-only geprüft: `../../timetrack-pwa/package-lock.json`, lockfileVersion `3`, SHA-256 `b1a4848f631d6d63032e58b7afc6870acc2fadb44fe8ea0be8a0a29b95f63fce`. Gezählt werden **201 Lockfile-Pfade**, einschließlich dev-/optionaler Plattformpakete und mehrfacher Versionen; Root-Projekt ausgeschlossen. Alle Einträge besitzen ein `license`-Feld; kein Fallback auf `node_modules` nötig, keine unbekannten Felder. Diese Metadaten sind keine vollständige Quellcode-Lizenzprüfung.

| SPDX | Anzahl Lockfile-Einträge |
| --- | ---: |
| `Apache-2.0` | 10 |
| `BSD-2-Clause` | 2 |
| `BSD-3-Clause` | 2 |
| `BlueOak-1.0.0` | 1 |
| `CC0-1.0` | 1 |
| `ISC` | 4 |
| `MIT` | 154 |
| `MIT-0` | 2 |
| `MPL-2.0` | 24 |
| `OFL-1.1` | 1 |

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

- Stand 15.10.2026 erneut abgeglichen (D1): Tabelle gegen `Package.resolved` (43 Pins, Versionen und Revisionen identisch), `ZIPFoundation`-Lizenztext (MIT, kein NOTICE) und npm-Lockfile (SHA-256 unverändert, 201 Einträge, gleiche Verteilung). Alles Übrige unten stammt aus C4.
- Verifiziert: sämtliche SwiftPM-Pins, Checkout-Revisionen und Hauptlizenztexte; lokale NOTICE-Dateien; Argon2-C-Duallizenz; sämtliche npm-Lizenzfelder und obige Zählung, einschließlich aller MPL-/OFL-Einträge.
- Offen: vollständiger Audit eingebetteter C-/Assembly-/Testanteile, BoringSSL/OpenSSL-Kompatibilitätsklärung, konkrete npm-Quelllizenzen jenseits der Metadaten und Inter-Lizenz, MPL-Marker, Fonts/Icons außerhalb des Lockfiles, Lizenzbeilagen und Attribution im tatsächlichen PWA-/Container-/Binary-Release.
- Betriebssystembibliotheken, Container-Basisimages und Swift-Toolchain sind nicht Teil von Package.resolved und hier nicht inventarisiert. Keine Abhängigkeiten oder PWA-Dateien für C4 verändert.
- Ergebnis: Hauptpakete weitgehend kompatibel; **Release-Prüfung bleibt wegen BoringSSL und der genannten Auslieferungspflichten offen**.
