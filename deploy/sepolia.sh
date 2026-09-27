#!/usr/bin/env bash
# Slingfall on Starknet Sepolia (docs/e2e.md "Sepolia"), lot E3b: the settled tier on Herodotus's
# Satellite. Spends the owner's STRK; the keys come from the environment, never a command line:
#
#   STARKNET_RPC_URL (or STARKNET_RPC)                       a Sepolia RPC 0.8+ endpoint
#   STARKNET_ACCOUNT_ADDRESS (or SLINGFALL_ACCOUNT_ADDRESS)  the admin account (deployed, funded)
#   STARKNET_PRIVATE_KEY (or SLINGFALL_PRIVATE_KEY)          its key
#   SLINGFALL_ATTESTATION_KEY   optional: the PUBLIC key of an attestation service (attest.py pubkey)
#   SLINGFALL_VERIFIER          satellite (default) or stub (needs the attestation key)
#   SLINGFALL_CHILD_HASH        optional: c1main's program hash (default: the pinned one, deploy/slingfall.ts)
#
#   deploy/sepolia.sh deploy      declare + deploy Slingfall, set the verifier and the Satellite
#                                 constants, register the six levels -> deploy/sepolia.json
#   deploy/sepolia.sh set-config CHILD_HASH [--yes]  re-pin `child_program_hash` on the
#                                 already-deployed Slingfall (a rapier2d / c1main bump, lot B3): one
#                                 set_satellite_config call, the other constants unchanged ->
#                                 deploy/sepolia.json (satellite.child_program_hash, transactions,
#                                 gas). Warns and refuses (M7) when services/prove/out holds jobs
#                                 that are not yet known to be settled, since a re-pin can strand
#                                 their proofs (docs/proving.md "Program hash history"); --yes skips
#                                 the warning.
#   deploy/sepolia.sh settle JOB  the first settled submit: prover-service job JOB (services/prove,
#                                 its fact on the Satellite) -> submit_settled, best, leaderboard,
#                                 all recorded in deploy/sepolia.json (the Poseidon path when the
#                                 fact is translated, else the keccak one)
#   deploy/sepolia.sh translate JOB  lot E3c: translateFactHash for job JOB's bridged keccak fact
#                                 (one transaction, permissionless; the cheap path of `settle`)
#
# deploy/sepolia.env gets the client's VITE_* variables (addresses only, no key, no private RPC).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STARKNET_RPC="${STARKNET_RPC:-${STARKNET_RPC_URL:-}}"
export SLINGFALL_ACCOUNT_ADDRESS="${SLINGFALL_ACCOUNT_ADDRESS:-${STARKNET_ACCOUNT_ADDRESS:-}}"
export SLINGFALL_PRIVATE_KEY="${SLINGFALL_PRIVATE_KEY:-${STARKNET_PRIVATE_KEY:-}}"
: "${STARKNET_RPC:?set STARKNET_RPC_URL to a Sepolia RPC URL}"
: "${SLINGFALL_ACCOUNT_ADDRESS:?set STARKNET_ACCOUNT_ADDRESS}"
: "${SLINGFALL_PRIVATE_KEY:?set STARKNET_PRIVATE_KEY}"
OUT="$ROOT/deploy/sepolia.json"
RUN="$ROOT/deploy/out/sepolia"
mkdir -p "$RUN"
cli() { node "$ROOT/deploy/slingfall.ts" "$@" --rpc "$STARKNET_RPC"; }

deploy() {
  [ -d "$ROOT/client/node_modules/starknet" ] || npm --prefix "$ROOT/client" ci --no-audit --no-fund
  scarb --manifest-path "$ROOT/deploy/contract/Scarb.toml" build
  local extra=(--verifier "${SLINGFALL_VERIFIER:-satellite}")
  [ -n "${SLINGFALL_ATTESTATION_KEY:-}" ] && extra+=(--attestation-key "$SLINGFALL_ATTESTATION_KEY")
  [ -n "${SLINGFALL_CHILD_HASH:-}" ] && extra+=(--child-hash "$SLINGFALL_CHILD_HASH")
  cli deploy --network sepolia "${extra[@]}" --out "$OUT"
  python3 - "$OUT" >"$ROOT/deploy/sepolia.env" <<'EOF'
import json, sys
config = json.load(open(sys.argv[1]))
print(f"VITE_SLINGFALL_ADDRESS={config['address']}")
print("VITE_RPC_URL=  # a Sepolia RPC 0.8+ endpoint (the deployer's is not recorded)")
print("VITE_ATTEST_URL=  # an attestation service, when the verifier is Stub")
print("VITE_PROVE_URL=  # the prover service (services/prove/prove_service.py serve)")
EOF
  echo "sepolia: wrote $OUT and deploy/sepolia.env" >&2
}

settle() {
  local job="${1:?settle JOB: a services/prove job id}"
  local store="${PROVE_STORE:-$ROOT/services/prove/out}"
  python3 "$ROOT/services/prove/prove_service.py" status "$job" --store "$store" >"$RUN/job.json"
  python3 - "$RUN/job.json" "$RUN" "$SLINGFALL_ACCOUNT_ADDRESS" <<'EOF'
import json, sys
job, run, player = json.load(open(sys.argv[1])), sys.argv[2], int(sys.argv[3], 16)
assert job["settleable"], f"job {job['id']}: the fact is not on the Satellite yet ({job.get('chain')})"
print(f"sepolia: settling on the {'Poseidon (translated, cheap)' if job['settleable_poseidon'] else 'keccak'} path", file=sys.stderr)
assert int(job["outputs"][3], 16) == player, "the job's player is not the account"
json.dump({"outputs": job["outputs"]}, open(f"{run}/outputs.json", "w"))
json.dump({"level_hash": job["level_hash"], "inputs": job["inputs"]}, open(f"{run}/args.json", "w"))
EOF
  cli submit-settled --config "$OUT" --outputs "$RUN/outputs.json" --args "$RUN/args.json" >"$RUN/settle.json"
  local level
  level="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['level_hash'])" "$RUN/job.json")"
  cli best --config "$OUT" --player "$SLINGFALL_ACCOUNT_ADDRESS" --level "$level" >"$RUN/best.json"
  cli leaderboard --config "$OUT" --level "$level" >"$RUN/leaderboard.json"
  python3 - "$OUT" "$RUN" <<'EOF'
import json, sys
path, run = sys.argv[1], sys.argv[2]
config = json.load(open(path))
job, settle = json.load(open(f"{run}/job.json")), json.load(open(f"{run}/settle.json"))
best, board = json.load(open(f"{run}/best.json")), json.load(open(f"{run}/leaderboard.json"))
assert best["settled"], best
config["settled_submit"] = {
    "job": job["id"], "atlantic_query": job["atlantic"]["query_id"], "level": job["level"],
    "integrity_fact_hash": job["run"]["integrity_fact_hash"], "sharp_fact_hash": job["run"]["sharp_fact_hash"],
    "satellite": job["chain"], "transaction_hash": settle["transaction_hash"],
    "level_validated": settle["level_validated"], "gas": settle["gas"], "best": best, "leaderboard": board,
}
config["transactions"]["submit_settled"] = settle["transaction_hash"]
config["gas"]["submit_settled"] = settle["gas"]
open(path, "w").write(json.dumps(config, indent=2) + "\n")
print(f"sepolia: settled {settle['transaction_hash']}; best {best}; leaderboard {board}", file=sys.stderr)
EOF
}

translate() {
  local job="${1:?translate JOB: a services/prove job id}"
  python3 "$ROOT/services/prove/prove_service.py" translate "$job" --store "${PROVE_STORE:-$ROOT/services/prove/out}"
}

set_config() {
  local child_hash="${1:?set-config CHILD_HASH: the new c1main program hash}"
  local yes="${2:-}"
  local store="${PROVE_STORE:-$ROOT/services/prove/out}"
  python3 - "$store" "$yes" <<'EOF'
import json, sys
from pathlib import Path
store, yes = Path(sys.argv[1]), sys.argv[2] == "--yes"
unsettled = []
for path in sorted(store.glob("*/job.json")):
    job = json.loads(path.read_text())
    if job.get("state") in ("queued", "running", "built", "submitted"):
        unsettled.append(job)
if unsettled:
    print(f"sepolia: WARNING: {len(unsettled)} job(s) under {store} are not known to be settled yet; "
          f"re-pinning child_program_hash invalidates every proof made against the current one "
          f"(docs/proving.md \"Program hash history\"):", file=sys.stderr)
    for job in unsettled:
        print(f"  - {job['id']} ({job.get('level')}, state {job['state']})", file=sys.stderr)
    if not yes:
        print("sepolia: pass --yes to set-config to continue anyway", file=sys.stderr)
        sys.exit(1)
EOF
  cli set-config --config "$OUT" --child-hash "$child_hash" >"$RUN/set-config.json"
  python3 - "$OUT" "$RUN/set-config.json" <<'EOF'
import json, sys
path, result_path = sys.argv[1], sys.argv[2]
config = json.load(open(path))
result = json.load(open(result_path))
config["satellite"] = result["satellite"]
config.setdefault("transactions", {})["set_satellite_config"] = result["transaction_hash"]
config.setdefault("gas", {})["set_satellite_config"] = result["gas"]
open(path, "w").write(json.dumps(config, indent=2) + "\n")
print(f"sepolia: child_program_hash set to {result['satellite']['child_program_hash']} ({result['transaction_hash']})", file=sys.stderr)
EOF
}

case "${1:-deploy}" in
  deploy) deploy ;;
  set-config) set_config "${2:-}" "${3:-}" ;;
  settle) settle "${2:-}" ;;
  translate) translate "${2:-}" ;;
  *) sed -n '2,29p' "$0" >&2; exit 2 ;;
esac
