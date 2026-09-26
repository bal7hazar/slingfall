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

case "${1:-deploy}" in
  deploy) deploy ;;
  settle) settle "${2:-}" ;;
  translate) translate "${2:-}" ;;
  *) sed -n '2,22p' "$0" >&2; exit 2 ;;
esac
