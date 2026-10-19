# PROPOSAL: additional permission under AGPL-3.0 section 7 (OpenSSL linking exception)

**Status: PROPOSAL, not in force.** This file is a draft prepared in package L3. It takes effect only if the
copyright holder(s) of Timetrack decide to adopt it and say so explicitly (for example by moving the text below into
the licence notice of the source files and into the README). The `LICENSE` file is deliberately **not** changed.
This is a technical draft, **not legal advice**; have it reviewed by a lawyer before adopting it. Background and
alternatives: [docs/LIZENZEN.md](docs/LIZENZEN.md), section "Lösungswege für die OpenSSL-Altlizenz".

## Why this might be needed

`swift-nio-ssl` 2.37.5 (pinned in `Package.resolved`) vendors BoringSSL as `CNIOBoringSSL` and the backend binary
links it statically. 323 of its source files carry the header "Licensed under the OpenSSL license", i.e. the old
OpenSSL/SSLeay licence with its advertising clause. The GNU project lists that licence as incompatible with the GPL
family. The cleanest fix is to avoid the code (see the alternatives in `docs/LIZENZEN.md`); the exception below is the
fallback if a release must ship with the affected version.

## Proposed text

> **Additional permission under GNU AGPL version 3 section 7**
>
> If you modify this Program, or any covered work, by linking or combining it with the OpenSSL project's OpenSSL
> library (or a modified version of that library, including BoringSSL and derivatives that are distributed under the
> OpenSSL licence and the original SSLeay licence), containing parts covered by the terms of the OpenSSL or SSLeay
> licenses, the licensors of this Program grant you additional permission to convey the resulting work. Corresponding
> Source for a non-source form of such a combination shall include the source code for the parts of the OpenSSL
> library used as well as that of the covered work.
>
> If you modify this Program, you may extend this exception to your version of the Program, but you are not obligated
> to do so. If you do not wish to do so, delete this exception statement from your version.

Notes on the draft:

- The wording follows the widely used "OpenSSL exception" pattern of other GPL/AGPL projects; it was adapted to
  section 7 of AGPL-3.0 and to the BoringSSL case. Whether this exact wording is sufficient is a legal question.
- Section 7 lets the copyright holder add permissions to the AGPL. It must be granted by **all** holders of the
  copyright in the Timetrack code. Contributions by third parties would need their agreement (today: sole
  maintainer; no external contributions are accepted without prior agreement).
- It grants permission only for the Timetrack code. It does **not** remove the obligations of the OpenSSL/SSLeay
  licence itself (advertising clause, attribution); those stay with whoever conveys the binary. The attributions are
  covered by `THIRD-PARTY-NOTICES` (see `scripts/third-party-notices.sh`).
- Downstream recipients get the permission only for the combination described; they must still comply with the
  OpenSSL/SSLeay terms for that part.

## If adopted: steps for the copyright holder

1. Decide (copyright holder): adopt the exception, or use the alternative (upgrade `swift-nio-ssl` to a release whose
   BoringSSL is Apache-2.0, see `docs/LIZENZEN.md`).
2. Replace this "PROPOSAL" status block by a statement of adoption with the date and add the text to the README
   section "Lizenz" and, if wanted, to the file headers. Keep the `LICENSE` file (the unmodified AGPL text).
3. Update `docs/LIZENZEN.md` and the SPDX expression (for example `AGPL-3.0-only WITH
   <exception identifier>`; no standard SPDX identifier exists for this exact text, so a custom `LicenseRef` is
   needed).
