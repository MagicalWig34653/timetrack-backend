#!/usr/bin/env bash
# Rebuilds the orphan branch `deploy` from main: only what an operator needs on the Swarm manager
# (stack, scripts, operation docs), no source code. Usage: scripts/sync-deploy-branch.sh [--push]
# Operators: git clone --branch deploy --single-branch --depth 1 <repo-url> timetrack-deploy
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$(git rev-parse --verify main)"
FILES=(
  deploy/swarm/stack.yaml deploy/swarm/create-secrets.sh deploy/swarm/update.sh
  docs/DEPLOYMENT.md docs/UPDATE.md docs/BETRIEB.md docs/installation LICENSE
)
TMP="$(mktemp -d)"; IDX="$(mktemp -u)"; trap 'rm -rf "$TMP" "$IDX" "$IDX.lock"' EXIT
git archive "$SRC" "${FILES[@]}" | tar -x -C "$TMP"
cat > "$TMP/README.md" <<'MD'
# Timetrack – Deploy

Dieser Branch enthält nur Stack-Datei, Skripte und Betriebsdokumentation für Docker Swarm, keinen Quellcode.
Er wird automatisch aus `main` erzeugt (`scripts/sync-deploy-branch.sh`); Änderungen bitte dort vornehmen.

- Anleitung: `docs/DEPLOYMENT.md`, Updates: `docs/UPDATE.md`
- Secrets: `deploy/swarm/create-secrets.sh` (bei bestehendem Stack `--add-only`)
- Update: `deploy/swarm/update.sh`
MD
GIT_INDEX_FILE="$IDX" git --work-tree="$TMP" add -A
TREE="$(GIT_INDEX_FILE="$IDX" git --work-tree="$TMP" write-tree)"
PARENT="$(git rev-parse --verify -q refs/heads/deploy || true)"
if [ -n "$PARENT" ] && [ "$(git rev-parse "$PARENT^{tree}")" = "$TREE" ]; then echo "deploy is up to date"; exit 0; fi
COMMIT="$(git commit-tree "$TREE" ${PARENT:+-p "$PARENT"} -m "Deploy files from main ${SRC:0:7}")"
git update-ref refs/heads/deploy "$COMMIT"
echo "deploy -> ${COMMIT:0:7}"
[ "${1:-}" != "--push" ] || git push origin deploy
