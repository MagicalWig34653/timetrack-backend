# scripts/licenses

Verbatim `LICENSE` files of the BoringSSL revisions vendored by the SwiftPM pins, read by
`scripts/third-party-notices.sh` (no network access at generation time). One file per revision, named
`boringssl-<first 8 characters of the revision>.LICENSE`, taken unchanged from
`https://boringssl.googlesource.com/boringssl/+/<revision>/LICENSE`.

| File | Revision | Vendored by |
| --- | --- | --- |
| `boringssl-8eb25be6.LICENSE` | `8eb25be6fa18d475291122887a7bccd3762ff236` | `swift-nio-ssl` 2.37.6 (`CNIOBoringSSL`) |
| `boringssl-0226f304.LICENSE` | `0226f30467f540a3f62ef48d453f93927da199b6` | `swift-crypto` 4.5.2 (`CCryptoBoringSSL`) |

Both files are currently byte-identical (Apache-2.0 plus the "Licenses for support code" section). When a pin
moves to another BoringSSL revision the generator stops with an error until the matching file is added here;
compare the new text with the previous one before adding it.
