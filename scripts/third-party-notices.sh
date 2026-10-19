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
# Environment: RESOLVED (default Package.resolved), CHECKOUTS (default .build/checkouts; run `swift package resolve` first).
# The output is reproducible: sorted, no timestamps. This is a technical inventory, not legal advice.
set -euo pipefail

RESOLVED="${RESOLVED:-Package.resolved}"
CHECKOUTS="${CHECKOUTS:-.build/checkouts}"
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
    # CXKCP/brg_endian.h (Brian Gladman): binary distributions must reproduce its copyright notice and conditions.
    gladman="$CHECKOUTS/$dir/Sources/CXKCP/FIPS202-opt64/brg_endian.h"
    if [ "$id" = "swift-crypto" ] && [ -f "$gladman" ]; then
      printf '\n--- Sources/CXKCP/FIPS202-opt64/brg_endian.h (notice) ---\n'; sed -n '1,/^\*\//p' "$gladman"
    fi
  done
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
