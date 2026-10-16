#!/usr/bin/env bash
# One-command local CI: build, tests (SQLite, optionally MariaDB), contract/YAML parse, shell checks, compose/stack config.
# Prints a PASS/FAIL/SKIP summary; exit code 1 if any step failed. Details of failed steps are printed from the step logs.
#
#   scripts/check-all.sh                  all steps (needs Swift; Docker for the compose/stack steps)
#   scripts/check-all.sh --fast           skip the Swift build and tests (static checks only)
#   scripts/check-all.sh --with-restore   additionally run scripts/test-restore.sh (needs the dev MariaDB container)
# MariaDB tests run only if MARIADB_TEST_HOST is set (eval "$(scripts/dev-env.sh test-db | grep ^export)" and create the
# database $MARIADB_TEST_DB first, see EINRICHTUNG.md). Without it the SQLite run covers the suite and the MariaDB step is SKIP.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FAST=0; WITH_RESTORE=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    --with-restore) WITH_RESTORE=1 ;;
    -h|--help) sed -n 2,10p "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT
NAMES=(); STATES=(); TIMES=()

run_step() { # run_step "name" command...
  local name="$1" log start rc; shift
  log="$LOGS/$((${#NAMES[@]} + 1)).log"
  printf '>> %s\n' "$name" >&2
  start=$SECONDS
  "$@" >"$log" 2>&1; rc=$?
  NAMES+=("$name"); TIMES+=("$((SECONDS - start))s")
  if [ $rc -eq 0 ]; then STATES+=(PASS); else
    STATES+=(FAIL); echo "---- $name (exit $rc), failure lines and last lines:" >&2
    grep -E "error:|: error|failed \(|with [1-9][0-9]* failure|FAIL" "$log" | head -15 >&2
    tail -15 "$log" >&2; echo "----" >&2
  fi
}
skip_step() { NAMES+=("$1"); STATES+=("SKIP"); TIMES+=("-"); printf '>> %s: SKIP (%s)\n' "$1" "$2" >&2; }

# --- steps ----------------------------------------------------------------------------------------------------------
yaml_parse() {
  python3 - "$@" <<'PY'
import sys
try:
    import yaml
except ImportError:
    print("PyYAML missing"); sys.exit(3)
bad = 0
for path in sys.argv[1:]:
    try:
        doc = yaml.safe_load(open(path))
    except Exception as exc:
        print(f"{path}: {exc}"); bad += 1; continue
    if path.endswith("openapi.yaml"):
        if not str(doc.get("openapi", "")).startswith("3."): print(f"{path}: no openapi 3.x marker"); bad += 1
        if not doc.get("info", {}).get("version"): print(f"{path}: info.version missing"); bad += 1
        ops = [op["operationId"] for item in doc["paths"].values() for m, op in item.items()
               if isinstance(op, dict) and "operationId" in op]
        dup = {o for o in ops if ops.count(o) > 1}
        if dup: print(f"{path}: duplicate operationIds {sorted(dup)}"); bad += 1
        print(f"{path}: {len(doc['paths'])} paths, {len(ops)} operations, version {doc['info']['version']}")
    else:
        print(f"{path}: ok")
sys.exit(1 if bad else 0)
PY
}

shell_syntax() {
  local f rc=0
  for f in scripts/*.sh scripts/lib/*.sh; do bash -n "$f" || rc=1; done
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x -P SCRIPTDIR -S warning scripts/*.sh scripts/lib/*.sh || rc=1
  else
    echo "shellcheck not installed: only bash -n was run"
  fi
  return $rc
}

compose_config() {
  # Dummy values only to satisfy the required-variable checks; nothing is started.
  DB_ROOT_PASSWORD=x DB_PASSWORD=x docker compose --project-name timetrack-dev -f compose.yaml \
    --profile app --profile sqlite --profile mail --profile s3 --profile oidc config -q
}

stack_config() {
  (set -a; . deploy/swarm/stack.env.example; set +a; docker stack config -c deploy/swarm/stack.yaml >/dev/null)
}

# --- run ------------------------------------------------------------------------------------------------------------
if [ $FAST -eq 1 ]; then
  skip_step "swift build" "--fast"; skip_step "swift test (SQLite)" "--fast"; skip_step "swift test (MariaDB)" "--fast"
elif ! command -v swift >/dev/null 2>&1; then
  skip_step "swift build" "swift not installed"; skip_step "swift test (SQLite)" "swift not installed"; skip_step "swift test (MariaDB)" "swift not installed"
else
  run_step "swift build (native build system)" swift build --build-system native
  run_step "swift test, SQLite (MariaDB variants skipped)" env -u MARIADB_TEST_HOST swift test --build-system native
  if [ -n "${MARIADB_TEST_HOST:-}" ]; then run_step "swift test, MariaDB at $MARIADB_TEST_HOST" swift test --build-system native
  else skip_step "swift test, MariaDB" "MARIADB_TEST_HOST not set"; fi
fi

if command -v python3 >/dev/null 2>&1; then
  run_step "contract and YAML parse (openapi, stack, dex)" yaml_parse contracts/openapi.yaml deploy/swarm/stack.yaml deploy/dex/config.yaml
else skip_step "contract and YAML parse" "python3 not installed"; fi

run_step "shell syntax (bash -n) and shellcheck" shell_syntax

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  run_step "docker compose config (dev compose, all profiles)" compose_config
  run_step "docker stack config (deploy/swarm/stack.yaml)" stack_config
else
  skip_step "docker compose config" "docker not reachable"; skip_step "docker stack config" "docker not reachable"
fi

if [ $WITH_RESTORE -eq 1 ]; then run_step "backup/restore proof (scripts/test-restore.sh)" scripts/test-restore.sh
else skip_step "backup/restore proof" "use --with-restore"; fi

# --- summary --------------------------------------------------------------------------------------------------------
echo
echo "== check-all summary =="
FAILS=0
for i in "${!NAMES[@]}"; do
  printf '%-5s %-6s %s\n' "${STATES[$i]}" "${TIMES[$i]}" "${NAMES[$i]}"
  [ "${STATES[$i]}" = FAIL ] && FAILS=$((FAILS + 1))
done
if [ $FAILS -gt 0 ]; then echo "RESULT: FAIL ($FAILS step(s) failed)"; exit 1; fi
echo "RESULT: PASS"
