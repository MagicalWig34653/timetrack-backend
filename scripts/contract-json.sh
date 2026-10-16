#!/usr/bin/env bash
# Regenerates the JSON copy of contracts/openapi.yaml used by the contract tests
# (Tests/TimetrackKitTests/Contract/openapi.contract.json). Run after every contract change.
# Needs python3 with PyYAML; the test suite fails with a clear message while the copy is stale.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import hashlib, json, yaml
src = open("contracts/openapi.yaml", "rb").read()
doc = yaml.safe_load(src)
doc["x-source-sha256"] = hashlib.sha256(src).hexdigest()
with open("Tests/TimetrackKitTests/Contract/openapi.contract.json", "w") as out:
    json.dump(doc, out, ensure_ascii=False, sort_keys=True, indent=1)
    out.write("\n")
print("wrote Tests/TimetrackKitTests/Contract/openapi.contract.json", doc["info"]["version"], len(doc["paths"]), "paths")
PY
