#!/usr/bin/env bash
# Generates THIRD-PARTY-NOTICES for the Timetrack backend (package L3, docs/LIZENZEN.md).
#
#   scripts/third-party-notices.sh [--swiftpm] [--dpkg] [-o FILE]
#
# --swiftpm  SwiftPM part: every pin of Package.resolved with its LICENSE/NOTICE files verbatim from the checkouts,
#            plus the vendored BoringSSL/XKCP revisions of swift-nio-ssl and swift-crypto.
# --dpkg     OS part: every installed dpkg package with its /usr/share/doc/<package>/copyright (run inside the image).
# Without a part flag both parts are produced (the dpkg part is skipped with a note when dpkg-query is missing).
#
# Environment: RESOLVED (default Package.resolved), CHECKOUTS (default .build/checkouts; run `swift package resolve` first),
# LICENSES (default scripts/licenses next to this script: verbatim BoringSSL LICENSE files per vendored revision).
# No network access: everything comes from Package.resolved, the checkouts and scripts/licenses. A checkout that does not
# match its pin (stale after a version bump) or a BoringSSL revision without a licence file stops the script with an error.
# The output is reproducible: sorted, no timestamps. This is a technical inventory, not legal advice.
set -euo pipefail

RESOLVED="${RESOLVED:-Package.resolved}"
CHECKOUTS="${CHECKOUTS:-.build/checkouts}"
LICENSES="${LICENSES:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/licenses}"
want_swiftpm=0; want_dpkg=0; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --swiftpm) want_swiftpm=1 ;;
    --dpkg) want_dpkg=1 ;;
    -o) shift; out="$1" ;;
    *) echo "usage: $0 [--swiftpm] [--dpkg] [-o FILE]" >&2; exit 2 ;;
  esac
  shift
done
if [ $((want_swiftpm + want_dpkg)) -eq 0 ]; then want_swiftpm=1; want_dpkg=1; fi
if [ -n "$out" ]; then exec >"$out"; fi

rule() { printf '\n%s\n' "================================================================================"; }

header() {
  cat <<'TXT'
THIRD-PARTY NOTICES - Timetrack backend

The Timetrack backend is licensed under AGPL-3.0-only (see LICENSE). The binary and the container image contain or
are built from the third-party components listed below. Their licence and notice texts follow verbatim.

Notes
- The SwiftPM part lists every pin of Package.resolved. swift-nio-ssl (CNIOBoringSSL) and swift-crypto
  (CCryptoBoringSSL, CXKCP) vendor C sources that are statically linked into the executable; their per-file licence
  headers apply in addition to the top-level LICENSE files, see docs/LIZENZEN.md in the source repository.
- Both BoringSSL copies are listed with the revision they were taken from and the verbatim BoringSSL LICENSE of exactly
  that revision (Apache-2.0). The NOTICE files of the two packages are reproduced unchanged; the note after each one
  explains where it differs from the vendored revision (the swift-nio-ssl NOTICE still names the older ISC/OpenSSL
  licence of earlier BoringSSL revisions).
- The Swift runtime libraries shipped in the image (Apache-2.0 with Runtime Library Exception) come from the official
  swift:*-slim base image; the OS part lists the Debian/Ubuntu packages installed in the image.
- The static PWA bundle (/srv/pwa) is built from a separate repository; its npm dependency licences are not part of
  this file.
- This file is a technical inventory, not legal advice.
TXT
}

swiftpm_part() {
  [ -f "$RESOLVED" ] || { echo "missing $RESOLVED" >&2; exit 1; }
  [ -d "$CHECKOUTS" ] || { echo "missing $CHECKOUTS (run: swift package resolve)" >&2; exit 1; }
  rule; echo "PART 1: Swift packages (Package.resolved)"; rule
  # identity|location|revision|version-or-branch, sorted by identity
  awk '
    /"identity"/ { gsub(/.*: *"|",?$/, ""); id=$0 }
    /"location"/ { gsub(/.*: *"|",?$/, ""); loc=$0 }
    /"branch"/   { gsub(/.*: *"|",?$/, ""); ver="branch " $0 }
    /"revision"/ { gsub(/.*: *"|",?$/, ""); rev=$0 }
    /"version"/  { gsub(/.*: *"|",?$/, ""); ver=$0 }
    /^    }/ && id != "" { print id "|" loc "|" rev "|" ver; id=""; loc=""; rev=""; ver="" }
  ' "$RESOLVED" | LC_ALL=C sort | while IFS='|' read -r id loc rev ver; do
    dir="$(basename "$loc")"; dir="${dir%.git}"
    # The checkout must be the pinned revision; SwiftPM keeps old checkouts around after a version bump.
    if [ -e "$CHECKOUTS/$dir/.git" ]; then
      have="$(git -C "$CHECKOUTS/$dir" rev-parse HEAD 2>/dev/null || true)"
      if [ -n "$have" ] && [ "$have" != "$rev" ]; then
        echo "checkout $CHECKOUTS/$dir is at $have but Package.resolved pins $rev (run: swift package resolve)" >&2; exit 1
      fi
    fi
    rule
    echo "Package: $id"; echo "Version: $ver"; echo "Revision: $rev"; echo "Source: $loc"
    found=0
    for name in LICENSE LICENSE.txt LICENSE.md UNLICENSE COPYING NOTICE NOTICE.txt NOTICES NOTICES.txt; do
      f="$CHECKOUTS/$dir/$name"
      [ -f "$f" ] || continue
      found=1; printf '\n--- %s ---\n' "$name"; cat "$f"
    done
    if [ "$found" -eq 0 ]; then echo "(no licence file found in checkout $dir)"; fi
    case "$id" in
      swift-nio-ssl) vend="Sources/CNIOBoringSSL/hash.txt" ;;
      swift-crypto) vend="Sources/CCryptoBoringSSL/hash.txt Sources/CXKCP/vendored-sources.txt" ;;
      *) vend="" ;;
    esac
    for v in $vend; do
      if [ -f "$CHECKOUTS/$dir/$v" ]; then
        printf '\n--- vendored sources: %s ---\n' "$v"; head -3 "$CHECKOUTS/$dir/$v"
      fi
    done
    case "$id" in
      swift-nio-ssl)
        boringssl_block "$dir" Sources/CNIOBoringSSL
        cat <<'TXT'

--- note on the NOTICE above (Timetrack) ---
The NOTICE of swift-nio-ssl is reproduced unchanged. Its BoringSSL entry ("Combination ISC and OpenSSL license")
describes earlier BoringSSL revisions (for example 817ab07e in swift-nio-ssl 2.37.5). The revision vendored here is
the one named above; its LICENSE is Apache-2.0 and the count above shows no source file left under the OpenSSL
licence header.
TXT
        ;;
      swift-crypto)
        boringssl_block "$dir" Sources/CCryptoBoringSSL
        cat <<'TXT'

--- note on the NOTICE above (Timetrack) ---
The NOTICE of swift-crypto is reproduced unchanged and has no BoringSSL entry. The BoringSSL copy statically linked
through swift-crypto (CCryptoBoringSSL) is licensed as shown above (Apache-2.0, revision named above).
TXT
        ;;
    esac
    # CXKCP/brg_endian.h (Brian Gladman): binary distributions must reproduce its copyright notice and conditions.
    gladman="$CHECKOUTS/$dir/Sources/CXKCP/FIPS202-opt64/brg_endian.h"
    if [ "$id" = "swift-crypto" ] && [ -f "$gladman" ]; then
      printf '\n--- Sources/CXKCP/FIPS202-opt64/brg_endian.h (notice) ---\n'; sed -n '1,/^\*\//p' "$gladman"
    fi
  done
}

# Prints the BoringSSL licence for the revision vendored in <checkout dir>/<subdir> (taken from its hash.txt).
boringssl_block() {
  local dir="$1" sub="$2" hash tree rev lic n
  tree="$CHECKOUTS/$dir/$sub"; hash="$tree/hash.txt"
  [ -f "$hash" ] || { echo "missing $hash" >&2; exit 1; }
  rev="$(head -1 "$hash" | awk '{print $NF}')"
  lic="$LICENSES/boringssl-${rev:0:8}.LICENSE"
  [ -f "$lic" ] || { echo "no BoringSSL licence text for revision $rev ($lic); see scripts/licenses/README.md" >&2; exit 1; }
  n="$({ grep -rl 'OpenSSL license' "$tree" || true; } | wc -l | tr -d ' ')"
  printf '\n--- BoringSSL licence, revision %s (vendored in %s/%s) ---\n' "$rev" "$dir" "$sub"
  echo "Verbatim BoringSSL LICENSE of this revision (https://boringssl.googlesource.com/boringssl/+/$rev/LICENSE)."
  echo "Source files in the vendored tree whose header names the OpenSSL licence: $n"
  if [ "$n" != 0 ]; then
    echo "WARNING: the vendored tree still contains OpenSSL-licensed files; the Apache-2.0 text below does not cover them."
  fi
  echo
  cat "$lic"
}

dpkg_part() {
  rule; echo "PART 2: operating system packages (dpkg)"; rule
  if ! command -v dpkg-query >/dev/null 2>&1; then
    echo "(dpkg-query not available on this host; run this script inside the image to produce this part)"
    return 0
  fi
  dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' | LC_ALL=C sort | while IFS=$'\t' read -r pkg ver arch; do
    rule; echo "Package: $pkg"; echo "Version: $ver ($arch)"
    base="${pkg%%:*}"; f="/usr/share/doc/$base/copyright"
    if [ -f "$f" ]; then printf '\n--- %s ---\n' "$f"; cat "$f"; else echo "(no $f in this image)"; fi
  done
}

# The explanatory header belongs to the first part; a dpkg-only run (appended to an existing file) omits it.
if [ "$want_swiftpm" -eq 1 ]; then header; swiftpm_part; fi
if [ "$want_dpkg" -eq 1 ]; then dpkg_part; fi
