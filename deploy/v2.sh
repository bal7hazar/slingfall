#!/usr/bin/env bash
# Builds contract v2's `Slingfall` class as deployed on Sepolia (lot W3, docs/e2e.md "Upgrade"):
# the tree of commit V2_COMMIT (lot D2, the deployment of `deploy/sepolia.json`) is extracted to
# deploy/out/v2/ (`git archive`; the commit is fetched when a shallow clone lacks it), its
# `deploy/contract` package is built, and the class hash must equal `deploy/sepolia.json`'s
# `class_hash`. Prints the artifacts prefix `deploy/slingfall.ts --artifacts` takes.
#
#   deploy/v2.sh            V2_COMMIT (default 6bcd1aab, D2) V2_OUT (default deploy/out/v2)
set -euo pipefail
# Sierra is not deterministic across compiler threads (docs/proving.md "Deterministic builds").
export RAYON_NUM_THREADS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMIT="${V2_COMMIT:-6bcd1aab70c13b50b5655280c4f0aaf68cabdba9}"
OUT="${V2_OUT:-$ROOT/deploy/out/v2}"
PREFIX="$OUT/deploy/contract/target/dev/slingfall_deploy_Slingfall"

if [ ! -f "$PREFIX.contract_class.json" ]; then
  if ! git -C "$ROOT" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
    echo "v2: fetching $COMMIT" >&2
    git -C "$ROOT" fetch --quiet --depth 1 origin "$COMMIT"
  fi
  rm -rf "$OUT"
  mkdir -p "$OUT"
  git -C "$ROOT" archive "$COMMIT" | tar -x -C "$OUT"
  echo "v2: building $COMMIT's deploy/contract" >&2
  scarb --manifest-path "$OUT/deploy/contract/Scarb.toml" build >&2
fi

got="$(node "$ROOT/deploy/slingfall.ts" class-hash --artifacts "$PREFIX")"
want="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['class_hash'])" "$ROOT/deploy/sepolia.json")"
if [ "$(python3 -c "import sys; print(int(sys.argv[1], 16) == int(sys.argv[2], 16))" "$got" "$want")" != True ]; then
  echo "v2: class hash $got is not deploy/sepolia.json's $want" >&2
  exit 1
fi
echo "v2: class $got (= deploy/sepolia.json's)" >&2
echo "$PREFIX"
