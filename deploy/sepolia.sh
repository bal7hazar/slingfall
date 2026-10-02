#!/usr/bin/env bash
# Slingfall on Starknet Sepolia (docs/e2e.md "Sepolia"): contract v2 (docs/contract-v2.md), the
# settled tier on Herodotus's Satellite, the attested tier when an attestation key is set. Spends
# the owner's STRK; the keys come from the environment, never a command line:
#
#   STARKNET_RPC_URL (or STARKNET_RPC)                       a Sepolia RPC 0.8+ endpoint
#   STARKNET_ACCOUNT_ADDRESS (or SLINGFALL_ACCOUNT_ADDRESS)  the admin account (deployed, funded)
#   STARKNET_PRIVATE_KEY (or SLINGFALL_PRIVATE_KEY)          its key
#   SLINGFALL_ATTESTATION_KEY   the PUBLIC key of the attestation service (attest.py pubkey); needed
#                               with the Stub verifier (the default)
#   SLINGFALL_VERIFIER          stub (default: both tiers) or satellite (the attested tier closed)
#   SLINGFALL_CHILD_HASH        optional: c1main's program hash (default: the pinned one, deploy/slingfall.ts)
#   SEPOLIA_OUT                 the deployment record (default deploy/sepolia.json)
#
#   deploy/sepolia.sh deploy      a fresh v2 deployment: declare + deploy Slingfall, then attestation key
#                                 + pin_program(c1main, 0) + Satellite config (+ verifier), the six
#                                 levels -> $SEPOLIA_OUT
#   deploy/sepolia.sh pin CHILD_HASH (--bit-compatible | --grace S | --no-grace) [--yes]
#                                 re-pin c1main (a rapier2d / c1main bump): pin_program(hash, grace_s),
#                                 the previous program valid grace_s more seconds. The grace is always
#                                 explicit: --bit-compatible (same outputs, research 06 §2.3) = 86 400 s,
#                                 --no-grace = 0 (a numeric change, or a defect: then revoke too).
#                                 Warns and refuses (M7) when services/prove/out holds jobs that are not
#                                 yet known to be settled, since their proofs stop settling once the
#                                 grace ends (docs/proving.md "Program hash history"); --yes goes on.
#   deploy/sepolia.sh revoke CHILD_HASH [--yes]   revoke_program: the program is refused at once
#                                 (same guard as pin)
#   deploy/sepolia.sh set-attestation-key PUBKEY  rotates the attestation key (bumps the epoch: every
#                                 earlier attestation stops verifying)
#   deploy/sepolia.sh set-admin ADDRESS           proposes an admin; the new admin then runs
#   deploy/sepolia.sh accept-admin                with its own account in the environment
#   deploy/sepolia.sh upgrade (CLASS_HASH | --declare)  replace_class to CLASS_HASH, or to the class
#                                 built in deploy/contract (declared first)
#   deploy/sepolia.sh settle JOB  a settled submit: prover-service job JOB (services/prove, its fact on
#                                 the Satellite) -> submit_settled(outputs, args, the job's program),
#                                 best, both boards, all recorded in $SEPOLIA_OUT (the Poseidon path
#                                 when the fact is translated, else the keccak one); any account may
#                                 send it, the record is the job's player's
#   deploy/sepolia.sh translate JOB  lot E3c: translateFactHash for job JOB's bridged keccak fact
#                                 (one transaction, permissionless; the cheap path of `settle`)
#
# deploy/sepolia.env gets the client's VITE_* variables (addresses only, no key, no private RPC).
set -euo pipefail
# Sierra is not deterministic across compiler threads (docs/proving.md "Deterministic builds").
export RAYON_NUM_THREADS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STARKNET_RPC="${STARKNET_RPC:-${STARKNET_RPC_URL:-}}"
export SLINGFALL_ACCOUNT_ADDRESS="${SLINGFALL_ACCOUNT_ADDRESS:-${STARKNET_ACCOUNT_ADDRESS:-}}"
export SLINGFALL_PRIVATE_KEY="${SLINGFALL_PRIVATE_KEY:-${STARKNET_PRIVATE_KEY:-}}"
: "${STARKNET_RPC:?set STARKNET_RPC_URL to a Sepolia RPC URL}"
: "${SLINGFALL_ACCOUNT_ADDRESS:?set STARKNET_ACCOUNT_ADDRESS}"
: "${SLINGFALL_PRIVATE_KEY:?set STARKNET_PRIVATE_KEY}"
OUT="${SEPOLIA_OUT:-$ROOT/deploy/sepolia.json}"
RUN="$ROOT/deploy/out/sepolia"
STORE="${PROVE_STORE:-$ROOT/services/prove/out}"
mkdir -p "$RUN"
cli() { node "$ROOT/deploy/slingfall.ts" "$@" --rpc "$STARKNET_RPC"; }

# Appends a transaction of RESULT (a slingfall.ts answer) to $OUT under LABEL; EXTRA is Python run
# with `config` and `result` in scope (e.g. to update the program record).
record() {
  python3 - "$OUT" "$1" "$2" "${3:-}" <<'EOF'
import json, sys
path, label, result_path, extra = sys.argv[1:5]
config, result = json.load(open(path)), json.load(open(result_path))
config.setdefault("transactions", {})[label] = result["transaction_hash"]
config.setdefault("gas", {})[label] = result["gas"]
exec(extra)
open(path, "w").write(json.dumps(config, indent=2) + "\n")
print(f"sepolia: {label} {result['transaction_hash']}", file=sys.stderr)
EOF
}

deploy() {
  [ -d "$ROOT/client/node_modules/starknet" ] || npm --prefix "$ROOT/client" ci --no-audit --no-fund
  scarb --manifest-path "$ROOT/deploy/contract/Scarb.toml" build
  local extra=(--verifier "${SLINGFALL_VERIFIER:-stub}")
  [ -n "${SLINGFALL_ATTESTATION_KEY:-}" ] && extra+=(--attestation-key "$SLINGFALL_ATTESTATION_KEY")
  [ -n "${SLINGFALL_CHILD_HASH:-}" ] && extra+=(--child-hash "$SLINGFALL_CHILD_HASH")
  cli deploy --network sepolia "${extra[@]}" --out "$OUT"
  python3 - "$OUT" >"$ROOT/deploy/sepolia.env" <<'EOF'
import json, sys
config = json.load(open(sys.argv[1]))
print(f"VITE_NETWORK=sepolia")
print(f"VITE_SLINGFALL_ADDRESS={config['address']}")
print("VITE_STARKNET_RPC_URL=  # a Sepolia RPC 0.8+ endpoint (the deployer's is not recorded)")
print("VITE_ATTEST_URL=  # the attestation service (services/attest/attest.py serve --execute)")
print("VITE_PROVE_URL=  # the prover service (services/prove/prove_service.py serve [--relay])")
EOF
  echo "sepolia: wrote $OUT and deploy/sepolia.env" >&2
}

# M7 (Q3): refuses while prover-service jobs may still need the program being replaced, unless --yes.
guard_jobs() {
  local what="$1" yes="$2"
  python3 - "$STORE" "$yes" "$what" <<'EOF'
import json, sys
from pathlib import Path
store, yes, what = Path(sys.argv[1]), sys.argv[2] == "--yes", sys.argv[3]
unsettled = [json.loads(p.read_text()) for p in sorted(store.glob("*/job.json"))]
unsettled = [j for j in unsettled if j.get("state") in ("queued", "running", "built", "submitted")
             and (j.get("relay") or {}).get("state") not in ("relayed", "settled")]
if unsettled:
    print(f"sepolia: WARNING: {len(unsettled)} job(s) under {store} are not known to be settled yet; {what} "
          f"(docs/proving.md \"Program hash history\"):", file=sys.stderr)
    for job in unsettled:
        print(f"  - {job['id']} ({job.get('level')}, state {job['state']})", file=sys.stderr)
    if not yes:
        print("sepolia: pass --yes to continue anyway", file=sys.stderr)
        sys.exit(1)
EOF
}

pin() {
  local child="${1:?pin CHILD_HASH (--bit-compatible | --grace S | --no-grace) [--yes]}"
  shift
  local grace=() yes="" label=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --bit-compatible) grace=(--bit-compatible); label="86400 s (bit-compatible)" ;;
      --grace) grace=(--grace "${2:?--grace S}"); label="$2 s"; shift ;;
      --no-grace) grace=(--grace 0); label="none" ;;
      --yes) yes=--yes ;;
      *) echo "sepolia: pin: unknown option $1" >&2; exit 2 ;;
    esac
    shift
  done
  if [ ${#grace[@]} -eq 0 ]; then
    echo "sepolia: pin: choose the grace explicitly: --bit-compatible (86 400 s), --grace S or --no-grace" >&2
    exit 2
  fi
  guard_jobs "their proofs of the current program stop settling when its grace ($label) ends" "$yes"
  cli pin-program --config "$OUT" --child-hash "$child" "${grace[@]}" >"$RUN/pin.json"
  record "pin_program $child" "$RUN/pin.json" '
program = config.setdefault("program", {"pins": []})
program["current"] = result["program_hash"]
program.setdefault("pins", []).append({k: result[k] for k in ("program_hash", "grace_s", "previous", "previous_valid_until", "transaction_hash")})'
}

revoke() {
  local child="${1:?revoke CHILD_HASH [--yes]}"
  guard_jobs "their proofs of $child stop settling at once" "${2:-}"
  cli revoke-program --config "$OUT" --child-hash "$child" >"$RUN/revoke.json"
  record "revoke_program $child" "$RUN/revoke.json" '
program = config.setdefault("program", {})
program.setdefault("revoked", []).append(result["program_hash"])
if int(program.get("current") or "0x0", 16) == int(result["program_hash"], 16):
    program["current"] = None'
}

settle() {
  local job="${1:?settle JOB: a services/prove job id}"
  python3 "$ROOT/services/prove/prove_service.py" status "$job" --store "$STORE" >"$RUN/job.json"
  python3 - "$RUN/job.json" "$RUN" <<'EOF'
import json, sys
job, run = json.load(open(sys.argv[1])), sys.argv[2]
assert job["settleable"], f"job {job['id']}: not settleable (fact {job.get('chain')}, program valid {job.get('program_match')})"
print(f"sepolia: settling on the {'Poseidon (translated, cheap)' if job['settleable_poseidon'] else 'keccak'} path", file=sys.stderr)
json.dump({"outputs": job["outputs"]}, open(f"{run}/outputs.json", "w"))
json.dump({"level_hash": job["level_hash"], "inputs": job["inputs"],
           "child_program_hash": job["run"]["child_program_hash"]}, open(f"{run}/args.json", "w"))
EOF
  cli submit-settled --config "$OUT" --outputs "$RUN/outputs.json" --args "$RUN/args.json" >"$RUN/settle.json"
  local level player
  level="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['level_hash'])" "$RUN/job.json")"
  player="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['outputs'][3])" "$RUN/job.json")"
  cli best --config "$OUT" --player "$player" --level "$level" --settled >"$RUN/best.json"
  cli boards --config "$OUT" --level "$level" >"$RUN/boards.json"
  python3 - "$OUT" "$RUN" <<'EOF'
import json, sys
path, run = sys.argv[1], sys.argv[2]
config = json.load(open(path))
job, settle = json.load(open(f"{run}/job.json")), json.load(open(f"{run}/settle.json"))
best, boards = json.load(open(f"{run}/best.json")), json.load(open(f"{run}/boards.json"))
assert best["settled"], best
config.setdefault("settled_submits", []).append({
    "job": job["id"], "atlantic_query": (job.get("atlantic") or {}).get("query_id"), "level": job["level"],
    "child_program_hash": job["run"]["child_program_hash"],
    "integrity_fact_hash": job["run"]["integrity_fact_hash"], "sharp_fact_hash": job["run"]["sharp_fact_hash"],
    "satellite": job.get("chain"), "transaction_hash": settle["transaction_hash"],
    "level_validated": settle["level_validated"], "gas": settle["gas"], "best_settled": best, "boards": boards,
})
config.setdefault("transactions", {})[f"submit_settled {job['id'][:8]}"] = settle["transaction_hash"]
open(path, "w").write(json.dumps(config, indent=2) + "\n")
print(f"sepolia: settled {settle['transaction_hash']}; best settled {best}; boards {boards}", file=sys.stderr)
EOF
}

translate() {
  local job="${1:?translate JOB: a services/prove job id}"
  python3 "$ROOT/services/prove/prove_service.py" translate "$job" --store "$STORE"
}

case "${1:-deploy}" in
  deploy) deploy ;;
  pin) shift; pin "$@" ;;
  revoke) revoke "${2:-}" "${3:-}" ;;
  set-attestation-key)
    cli set-attestation-key --config "$OUT" --attestation-key "${2:?set-attestation-key PUBKEY}" >"$RUN/key.json"
    record "set_attestation_key" "$RUN/key.json" 'config["attestation_key"] = result["attestation_key"]' ;;
  set-admin)
    cli set-admin --config "$OUT" --admin "${2:?set-admin ADDRESS}" >"$RUN/admin.json"
    record "set_admin" "$RUN/admin.json" 'config["pending_admin"] = result["pending_admin"]' ;;
  accept-admin)
    cli accept-admin --config "$OUT" >"$RUN/accept.json"
    record "accept_admin" "$RUN/accept.json" 'config["admin"] = config.pop("pending_admin", config.get("admin"))' ;;
  upgrade)
    if [ "${2:-}" = --declare ]; then
      scarb --manifest-path "$ROOT/deploy/contract/Scarb.toml" build
      cli upgrade --config "$OUT" --declare >"$RUN/upgrade.json"
    else
      cli upgrade --config "$OUT" --class-hash "${2:?upgrade CLASS_HASH | --declare}" >"$RUN/upgrade.json"
    fi
    record "upgrade" "$RUN/upgrade.json" 'config["class_hash"] = result["class_hash"]' ;;
  settle) settle "${2:-}" ;;
  translate) translate "${2:-}" ;;
  *) sed -n '2,45p' "$0" >&2; exit 2 ;;
esac
