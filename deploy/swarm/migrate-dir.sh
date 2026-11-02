#!/usr/bin/env bash
# Read-only helper for moving an existing Swarm directory to a clone of the `deploy` branch: compares the old,
# hand-edited stack file with the new stack.yaml and checks the old .env against the new stack. It changes NOTHING
# (no docker call, no file written). Language: code and comments are English, all output for the operator is German.
set -euo pipefail

usage() {
  cat <<'USAGE'
migrate-dir.sh: altes Swarm-Verzeichnis mit dem deploy-Branch vergleichen (nur lesend, ändert nichts)

Aufruf: migrate-dir.sh --old-stack DATEI --old-env DATEI [--new-stack DATEI] [--full-diff]
  --old-stack DATEI  bisherige, selbst veränderte Stack-Datei (z. B. timetrack-stack.yml)
  --old-env DATEI    bisherige .env
  --new-stack DATEI  neue Stack-Datei (Standard: stack.yaml neben dem Skript)
  --full-diff        zusätzlich das vollständige diff -u ausgeben
Ausgabe: lokale Umgebungsvariablen und Secrets der alten Datei, die die neue nicht kennt (Overlay-Kandidaten),
Pflichtvariablen der neuen Datei, die in der alten .env fehlen, und .env-Variablen, die die neue Datei nicht liest.
Exit 0 = nichts Auffälliges, Exit 1 = Unterschiede oder fehlende Pflichtvariablen (zur Prüfung, kein Fehler im Betrieb).
USAGE
}

OLD_STACK=""; OLD_ENV=""; NEW_STACK=""; FULL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --old-stack) OLD_STACK="${2:?Wert für --old-stack fehlt}"; shift 2 ;;
    --old-env) OLD_ENV="${2:?Wert für --old-env fehlt}"; shift 2 ;;
    --new-stack) NEW_STACK="${2:?Wert für --new-stack fehlt}"; shift 2 ;;
    --full-diff) FULL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 64 ;;
  esac
done
[ -n "$NEW_STACK" ] || NEW_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stack.yaml"
[ -n "$OLD_STACK" ] && [ -n "$OLD_ENV" ] || { usage >&2; exit 64; }
for f in "$OLD_STACK" "$OLD_ENV" "$NEW_STACK"; do [ -f "$f" ] || { echo "Datei nicht gefunden: $f" >&2; exit 1; }; done

PROBLEMS=0
# Uncommented environment keys (indented UPPER_CASE keys) of a stack file.
env_keys() { sed -n 's/^[[:space:]]\{1,\}\([A-Z][A-Z0-9_]*\):.*/\1/p' "$1" | sort -u; }
# Uncommented secret names of a stack file.
secret_names() { grep -v '^[[:space:]]*#' "$1" | grep -o 'tt_[a-z0-9_]*' | sort -u || true; }
# Variables referenced as ${NAME...}; with REQUIRED=1 only those with the :? (required) form.
var_refs() {
  if [ "${REQUIRED:-0}" = 1 ]; then grep -v '^[[:space:]]*#' "$1" | grep -o '\${[A-Z][A-Z0-9_]*:?' | tr -d '${:?' | sort -u || true
  else grep -v '^[[:space:]]*#' "$1" | grep -o '\${[A-Z][A-Z0-9_]*' | tr -d '${' | sort -u || true; fi
}
# Variables set (uncommented NAME=) in the env file.
env_vars() { sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$1" | sort -u; }
section() { printf '\n== %s\n' "$1"; }
list_or_none() { if [ -n "$1" ]; then printf '%s\n' "$1" | sed 's/^/  - /'; else echo "  (keine)"; fi; }

echo "Alt: ${OLD_STACK} / ${OLD_ENV}"
echo "Neu: ${NEW_STACK}"

section "Umgebungsvariablen nur in der ALTEN Stack-Datei (lokale Ergänzungen)"
only_old="$(comm -23 <(env_keys "$OLD_STACK") <(env_keys "$NEW_STACK"))"
list_or_none "$only_old"
if [ -n "$only_old" ]; then
  echo "  Hinweis: Optionale Blöcke (SMTP, OIDC, APNs) stehen in der neuen Datei auskommentiert; ist ein Eintrag dort"
  echo "  vorgesehen, reicht es, den Block im Klon zu aktivieren ODER ein Overlay zu verwenden (override.example.yaml)."
  PROBLEMS=1
fi

section "Umgebungsvariablen nur in der NEUEN Stack-Datei (neue Standardwerte beachten)"
list_or_none "$(comm -13 <(env_keys "$OLD_STACK") <(env_keys "$NEW_STACK"))"

section "Secrets nur in der ALTEN Stack-Datei"
only_old_s="$(comm -23 <(secret_names "$OLD_STACK") <(secret_names "$NEW_STACK"))"
list_or_none "$only_old_s"
[ -z "$only_old_s" ] || { echo "  Hinweis: ein Overlay muss das Secret in services.backend.secrets und im Top-Level secrets (external: true) nennen."; PROBLEMS=1; }

section "Pflichtvariablen der neuen Stack-Datei, die in der alten .env fehlen"
missing="$(comm -23 <(REQUIRED=1 var_refs "$NEW_STACK") <(env_vars "$OLD_ENV"))"
list_or_none "$missing"
[ -z "$missing" ] || PROBLEMS=1
if ! env_vars "$OLD_ENV" | grep -qx 'TIMETRACK_IMAGE'; then echo "  PROBLEM: TIMETRACK_IMAGE fehlt in der alten .env."; PROBLEMS=1; fi

section "Variablen der alten .env, die die neue Stack-Datei nicht liest"
unused="$(comm -23 <(env_vars "$OLD_ENV") <(var_refs "$NEW_STACK"))"
list_or_none "$unused"
[ -z "$unused" ] || echo "  Hinweis: harmlos, wenn sie nur für auskommentierte Blöcke oder ein Overlay gedacht sind; sonst entfernen."

section "Zeilen, in denen sich Ports, Placement, Replikas, Netzwerke und Volumes unterscheiden"
sel='ports:|published|target:|placement|constraints|replicas|networks:|volumes:|image:|external:|name:'
d="$(diff <(grep -v '^[[:space:]]*#' "$OLD_STACK" | grep -E "$sel" || true) <(grep -v '^[[:space:]]*#' "$NEW_STACK" | grep -E "$sel" || true) || true)"
if [ -n "$d" ]; then printf '%s\n' "$d" | sed 's/^/  /'; PROBLEMS=1; else echo "  (keine)"; fi

if [ "$FULL" = 1 ]; then
  section "Vollständiges diff -u (alt -> neu)"
  diff -u "$OLD_STACK" "$NEW_STACK" || true
else
  printf '\nVollständiger Vergleich: diff -u %q %q   (oder erneut mit --full-diff)\n' "$OLD_STACK" "$NEW_STACK"
fi
echo
if [ "$PROBLEMS" = 0 ]; then echo "Ergebnis: keine Auffälligkeiten."; else echo "Ergebnis: Unterschiede gefunden, bitte oben prüfen. Es wurde nichts geändert."; fi
exit "$PROBLEMS"
