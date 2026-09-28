#!/usr/bin/env bash
# End-to-end check of the contract's three tiers on a fresh local devnet (lots G9, E3b, W1, W3;
# docs/e2e.md). Accounts: #0 admin, #1 the player, #2 a third party (the relay, and the prover
# service's account), #3 a second player.
#
#   devnet up (starknet-devnet 0.10.0, --proof-mode none)
#   -> build contract v3, the v2 class of Sepolia's deployment (deploy/v2.sh, hash-checked against
#      deploy/sepolia.json) and layout (e)'s classes (slingfall_split)
#   -> deploy v2 (attestation key, pin_program(c1main, 0), FakeSatellite, six levels)
#   -> the golden shots replayed with `scarb execute` (deploy/outputs.py) for the players and admin
#   provisional tier (on v2):
#   -> attest.py --execute re-executes the replay and signs the message -> the player's
#      submit(outputs, [program_hash, expiry, r, s]); LevelValidated, best / boards; the same submit
#      again: 'submit: nullifier'; the admin's and the second player's provisional records
#   upgrade v2 -> v3:
#   -> `snapshot` (every value, both records and boards of the three players, each attempt's tier),
#      upgrade(v3), `snapshot` again: identical but the class hash
#   -> the proven tier opened: SplitChain deployed over the declared classes, set_chunk_marker,
#      pin_virtual_os (the devnet's), pin_chain(chain, bundle, 0) (`deploy/devnet.sh proven`)
#   proven tier (SNIP-36, fake prover): the player's provisional record -> proven
#   -> `prove_service.py prove --tier proven --snip36 fake` (account #2): the whole chain of the
#      pile10 reference shot planned by simulation, one proof per virtual transaction, one Invoke
#      per proof (submit_chunk per message), finalize; LevelValidated proven with the bundle hash,
#      attempt() = 3, the settled board's row "proven by SNIP-36"
#   settled tier, relayed: the second player's provisional record -> settled
#   -> the prover service's relay (account #2) waits while the fact is absent, then, the Atlantic
#      fact registered on the FakeSatellite, sends submit_settled for claim.player; attempt() = 2,
#      the settled board holds both rows, each with its proof and release
#   retired chain:
#   -> pin_chain(second chain, bundle, 3600): a proof of the first chain is still accepted inside
#      the grace, refused after it ('chunk: chain'), and so is its finalize ('finalize: chain')
#   re-pin with grace (M7):
#   -> pin_program(new, 3600): a proof of the old program settles inside the window; after
#      devnet_increaseTime past it, another is refused with 'submit: program' (simulated first)
#   expired provisional record:
#   -> the admin's provisional record: 24 h later the third party expires it (RecordExpired), a
#      second expire 'expire: none'
#   Cost figures of the proven tier are written to deploy/out/e2e/cost.json (docs/proving.md).
#
# E2E_SETTLE=keccak registers only the bridged keccak facts (the path Sepolia takes while
# Atlantic's translation stalls), else only the translated Poseidon facts.
#   deploy/e2e.sh [--keep]     --keep leaves the devnet running (deploy/devnet.sh down stops it)
#
# Ports: E2E_DEVNET_PORT (5055, apart from a dev devnet on 5050), E2E_ATTEST_PORT (8548).
# Everything is written to deploy/out/e2e/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/deploy/out/e2e"
export DEVNET_PORT="${E2E_DEVNET_PORT:-5055}"
export DEVNET_OUT="$OUT/devnet.json"
export DEVNET_ENV="$OUT/devnet.env"
export DEVNET_SPLIT_OUT="$OUT/split.json"
RPC="http://127.0.0.1:${DEVNET_PORT}/rpc"
ATTEST_PORT="${E2E_ATTEST_PORT:-8548}"
ATTEST_URL="http://127.0.0.1:${ATTEST_PORT}"
ATTEST_KEY="${DEVNET_ATTEST_KEY:-0x736c696e6766616c6c2d6465766e6574}"
SETTLE="${E2E_SETTLE:-poseidon}"
GRACE=3600
KEEP="${1:-}"
STARTED=$SECONDS
mkdir -p "$OUT"
rm -rf "$OUT"/*.json "$OUT"/*.txt "$OUT/prove" "$OUT/proven"

step() { echo "e2e: [$((SECONDS - STARTED)) s] $*" >&2; }
json() { python3 -c "import json, sys; d = json.load(open(sys.argv[1])); print($2)" "$1"; }
cli() { node "$ROOT/deploy/slingfall.ts" "$@" --rpc "$RPC"; }
check() { python3 - "$@"; }
key() { cli account --index "$1" --with-key | python3 -c 'import json, sys; print(json.load(sys.stdin)["private_key"])'; }

attest_pid=""
split_pid=""
cleanup() {
  [ -n "$attest_pid" ] && kill "$attest_pid" 2>/dev/null || true
  [ -n "$split_pid" ] && kill "$split_pid" 2>/dev/null || true
  [ "$KEEP" = "--keep" ] || "$ROOT/deploy/devnet.sh" down
}
trap cleanup EXIT

# A fresh devnet: nullifiers and records from an earlier run would fail the checks.
"$ROOT/deploy/devnet.sh" down
"$ROOT/deploy/devnet.sh" up

# Layout (e)'s classes build beside the replays (two jobs at most); the proven tier waits for them.
step "build: layout (e)'s classes (slingfall_split, in the background), contract v3, the v2 class of deploy/sepolia.json (deploy/v2.sh)"
scarb build -p slingfall_split >"$OUT/split-build.log" 2>&1 &
split_pid=$!
scarb --manifest-path "$ROOT/deploy/contract/Scarb.toml" build >&2
"$ROOT/deploy/v2.sh" >"$OUT/v2-artifacts.txt"

step "deploy contract v2 (the class of deploy/sepolia.json)"
DEVNET_CONTRACT=v2 "$ROOT/deploy/devnet.sh" deploy
CONFIG="$DEVNET_OUT"
ADDRESS="$(json "$CONFIG" 'd["address"]')"
CHILD="$(json "$CONFIG" 'd["program"]["current"]')"
PILE10="$(json "$CONFIG" 'd["levels"]["pile10"]')"
ADMIN="$(cli account --index 0)"
PLAYER="$(cli account --index 1)"
RELAY="$(cli account --index 2)"
SECOND="$(cli account --index 3)"
check "$CONFIG" "$ROOT/deploy/sepolia.json" <<'EOF'
import json, sys
config, sepolia = (json.load(open(p)) for p in sys.argv[1:])
assert config["contract_version"] == 2 and int(config["class_hash"], 16) == int(sepolia["class_hash"], 16), config
EOF
cli program --config "$CONFIG" >"$OUT/program.json"
check "$OUT/program.json" "$CHILD" <<'EOF'
import json, sys
program, child = json.load(open(sys.argv[1])), int(sys.argv[2], 16)
assert int(program["current"], 16) == child and program["valid"], program
EOF
step "contract v2 $ADDRESS, program $CHILD; admin $ADMIN, player $PLAYER, relay $RELAY, second player $SECOND"

step "replays (scarb execute main): pile10 for the player, the admin and the second player; two one_block shots for the player"
outputs() { python3 "$ROOT/deploy/outputs.py" --case "$1" --player "$2" --child-hash "$CHILD" --out "$OUT/$3.json" ${4:-}; }
outputs pile10-reference "$PLAYER" a1
outputs one_block-delay30 "$PLAYER" a2 --no-build
outputs one_block-disk-boundary "$PLAYER" a3 --no-build
outputs pile10-reference "$ADMIN" a4 --no-build
outputs pile10-reference "$SECOND" a5 --no-build
for run in a1 a2 a3 a4 a5; do
  python3 -c "import json, sys; json.dump(json.load(open(sys.argv[1]))['args'], open(sys.argv[2], 'w'))" "$OUT/$run.json" "$OUT/$run.args.json"
done

step "attestation service (--execute: re-executes each replay natively)"
SLINGFALL_ATTEST_KEY="$ATTEST_KEY" python3 "$ROOT/services/attest/attest.py" serve --execute --no-build \
  --contract "$ADDRESS" --rpc "$RPC" --port "$ATTEST_PORT" 2>"$OUT/attest.log" &
attest_pid=$!
for _ in $(seq 1 50); do
  python3 -c "import urllib.request; urllib.request.urlopen('$ATTEST_URL/health', timeout=1)" 2>/dev/null && break
  sleep 0.2
done
attest() {
  python3 "$ROOT/services/attest/attest.py" request --url "$ATTEST_URL" --level "$(json "$OUT/$1.json" 'd["level"]')" \
    --inputs "$OUT/$1.json" --outputs "$OUT/$1.json" >"$OUT/attestation-$1.json"
  check "$OUT/attestation-$1.json" "$CHILD" "$ADDRESS" <<'EOF'
import json, sys
a, child, contract = json.load(open(sys.argv[1])), int(sys.argv[2], 16), int(sys.argv[3], 16)
assert a["mode"] == "execute" and a["verified"] and a["epoch"] == 1, a
assert int(a["program_hash"], 16) == child and int(a["contract"], 16) == contract and len(a["evidence"]) == 4, a
print(f"e2e: attested {a['message']} (epoch {a['epoch']}, expiry {a['expiry']})", file=sys.stderr)
EOF
}

step "provisional (v2): the player's attested submit"
attest a1
cli submit --devnet --index 1 --config "$CONFIG" --outputs "$OUT/a1.json" --attestation "$OUT/attestation-a1.json" >"$OUT/submit.json"
cli best --config "$CONFIG" --player "$PLAYER" --level "$PILE10" >"$OUT/best.json"
cli best --config "$CONFIG" --player "$PLAYER" --level "$PILE10" --settled >"$OUT/best-settled-before.json"
cli boards --config "$CONFIG" --level "$PILE10" >"$OUT/boards.json"
check "$OUT" "$PLAYER" "$CHILD" <<'EOF'
import json, sys
out, player, child = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
load = lambda name: json.load(open(f"{out}/{name}.json"))
a1, submit, best, settled, boards = load("a1"), load("submit"), load("best"), load("best-settled-before"), load("boards")
score, won = int(a1["outputs"][5], 16), int(a1["outputs"][6], 16) == 1
[event] = submit["level_validated"]
assert int(event["player"], 16) == player and event["score"] == score and event["won"] == won, event
assert not event["settled"] and not event["proven"] and int(event["programHash"], 16) == child, event
assert best["score"] == score and not best["settled"] and best["timestamp"] > 0 and int(best["programHash"], 16) == child, best
assert settled["score"] == 0 and not settled["won"], settled
assert boards["settled"] == [], boards
if won:
    assert [(int(r["player"], 16), r["score"], r["settled"], r["proof"]) for r in boards["provisional"]] == [(player, score, False, None)], boards
gas = submit["gas"]
print(f"e2e: provisional ok; submit l2_gas {gas['l2Gas']:,}, fee {int(gas['fee']):,} {gas['unit']}", file=sys.stderr)
EOF

step "the same submit again must be rejected"
cli submit --devnet --index 1 --config "$CONFIG" --outputs "$OUT/a1.json" --attestation "$OUT/attestation-a1.json" \
  --expect-panic 'submit: nullifier' >"$OUT/resubmit.json"
cat "$OUT/resubmit.json" >&2

step "the admin's provisional record (to expire later; expire now is early) and the second player's"
attest a4
cli submit --devnet --index 0 --config "$CONFIG" --outputs "$OUT/a4.json" --attestation "$OUT/attestation-a4.json" >"$OUT/submit-a4.json"
cli expire --devnet --index 2 --config "$CONFIG" --level "$PILE10" --player "$ADMIN" --expect-panic 'expire: early' >"$OUT/expire-early.json"
cat "$OUT/expire-early.json" >&2
attest a5
cli submit --devnet --index 3 --config "$CONFIG" --outputs "$OUT/a5.json" --attestation "$OUT/attestation-a5.json" >"$OUT/submit-a5.json"

step "upgrade v2 -> v3: every value read back"
PLAYERS="$PLAYER,$ADMIN,$SECOND"
cli snapshot --config "$CONFIG" --players "$PLAYERS" >"$OUT/snapshot-v2.json"
V3_CLASS="$(node "$ROOT/deploy/slingfall.ts" class-hash)"
cli upgrade --devnet --config "$CONFIG" --declare >"$OUT/upgrade.json"
cli snapshot --config "$CONFIG" --players "$PLAYERS" >"$OUT/snapshot-v3.json"
check "$OUT" "$V3_CLASS" "$PILE10" "$PLAYER" <<'EOF'
import json, sys
out, v3, pile10, player = sys.argv[1], int(sys.argv[2], 16), sys.argv[3], sys.argv[4]
load = lambda name: json.load(open(f"{out}/{name}.json"))
before, after, upgrade = load("snapshot-v2"), load("snapshot-v3"), load("upgrade")
assert int(upgrade["class_hash"], 16) == v3 and int(upgrade["class_hash_at"], 16) == v3 and int(after["class_hash"], 16) == v3, upgrade
assert int(before["class_hash"], 16) != v3
same = lambda d: {k: v for k, v in d.items() if k != "class_hash"}
assert same(before) == same(after), "a v2 value changed across the upgrade"
records = before["levels"]["pile10"]["records"]
assert all(r["attempt"] == 1 for r in records.values()), records  # three attested pile10 records
print(f"e2e: upgraded to {hex(v3)}; {len(before['levels'])} levels, {len(records)} players' records, both boards, "
      f"keys, programs and Satellite read back unchanged", file=sys.stderr)
EOF

step "open the proven tier: SplitChain over the declared classes, marker, virtual OS, pin_chain"
wait "$split_pid" || { cat "$OUT/split-build.log" >&2; exit 1; }
split_pid=""
"$ROOT/deploy/devnet.sh" proven
BUNDLE="$(json "$DEVNET_SPLIT_OUT" 'd["bundle_hash"]')"
CHAIN="$(json "$DEVNET_SPLIT_OUT" 'd["chain"]')"
cli chain --config "$CONFIG" >"$OUT/chain.json"
check "$OUT/chain.json" "$CHAIN" "$BUNDLE" <<'EOF'
import json, sys
c, chain, bundle = json.load(open(sys.argv[1])), int(sys.argv[2], 16), int(sys.argv[3], 16)
assert int(c["current"], 16) == chain and int(c["bundle_hash"], 16) == bundle and c["valid"], c
assert int(c["chunk_marker"], 16) == int.from_bytes(b"SLINGFALL", "big"), c
EOF

relay_env() {
  env SLINGFALL_ADDRESS="$ADDRESS" STARKNET_RPC_URL="$RPC" STARKNET_ACCOUNT_ADDRESS="$RELAY" STARKNET_PRIVATE_KEY="$(key 2)" "$@"
}

step "proven (SNIP-36, fake prover): the player's provisional pile10 record, relayed by the prover service"
PROVEN_STORE="$OUT/proven"
relay_env python3 "$ROOT/services/prove/prove_service.py" prove --tier proven --snip36 fake --store "$PROVEN_STORE" \
  --level pile10 --inputs "$(json "$OUT/a1.json" '",".join(d["inputs"])')" >"$OUT/proven.json" 2>"$OUT/proven.log" ||
  { tail -20 "$OUT/proven.log" >&2; exit 1; }
grep -v WARN "$OUT/proven.log" >&2 || true
cli attempt --config "$CONFIG" --level "$PILE10" --player "$PLAYER" --inputs-hash "$(json "$OUT/a1.json" 'd["outputs"][4]')" >"$OUT/attempt-proven.json"
cli best --config "$CONFIG" --player "$PLAYER" --level "$PILE10" --settled >"$OUT/best-proven.json"
check "$OUT" "$PLAYER" "$RELAY" "$BUNDLE" "$RPC" "$ADDRESS" <<'EOF'
import json, sys, urllib.request
out, player, relay, bundle, rpc, contract = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16), int(sys.argv[4], 16), sys.argv[5], int(sys.argv[6], 16)
load = lambda name: json.load(open(f"{out}/{name}.json"))
job, attempt, best, a1 = load("proven"), load("attempt-proven"), load("best-proven"), load("a1")
assert job["state"] == "proven" and job["tier"] == "proven" and job["chain_match"], {k: job.get(k) for k in ("state", "error", "chain_match")}
assert all(p["state"] == "submitted" for p in job["proofs"]), job["proofs"]
fin = job["finalize"]
assert fin["state"] == "finalized" and int(fin["program_hash"], 16) == bundle, fin
assert attempt["attempt"] == 3 and attempt["tier"] == "proven", attempt
assert best["settled"] and best["score"] == int(a1["outputs"][5], 16) and int(best["programHash"], 16) == bundle, best
def rpc_call(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    return json.load(urllib.request.urlopen(urllib.request.Request(rpc, body, {"Content-Type": "application/json"})))["result"]
sent = rpc_call("starknet_getTransactionByHash", {"transaction_hash": fin["transaction_hash"]})
assert int(sent["sender_address"], 16) == relay, sent  # finalize relayed by a third party, for the player
receipt = rpc_call("starknet_getTransactionReceipt", {"transaction_hash": fin["transaction_hash"]})
[ev] = [e for e in receipt["events"] if int(e["from_address"], 16) == contract and len(e["keys"]) == 3]
assert int(ev["keys"][1], 16) == player and int(ev["data"][3], 16) == 1 and int(ev["data"][4], 16) == bundle and int(ev["data"][5], 16) == 1, ev
plan, proofs = job["plan"], job["proofs"]
cost = {"shot": "pile10-reference", "layout": "e", "ticks": plan["ticks"], "budget_l2_gas": plan["budget"],
        "proofs": len(proofs), "calls": plan["calls"], "virtual_l2_gas": plan["l2_gas"],
        "messages": [p["messages"] for p in proofs], "submit_chunk_tx_l2_gas": [p["gas"]["l2Gas"] for p in proofs],
        "submit_chunk_tx_l1_data_gas": [p["gas"]["l1DataGas"] for p in proofs],
        "finalize_l2_gas": fin["gas"]["l2Gas"], "finalize_l1_data_gas": fin["gas"]["l1DataGas"], "plan_seconds": plan["seconds"]}
json.dump(cost, open(f"{out}/cost.json", "w"), indent=2)
print(f"e2e: proven by SNIP-36: {len(proofs)} proofs of {plan['calls']} calls ({plan['ticks']} ticks, virtual L2 gas "
      f"{[f'{g:,}' for g in plan['l2_gas']]}); submit_chunk Invokes L2 gas {[f'{g:,}' for g in cost['submit_chunk_tx_l2_gas']]}; "
      f"finalize {fin['gas']['l2Gas']:,} by {hex(relay)}", file=sys.stderr)
EOF

register_fact() {
  if [ "$SETTLE" = keccak ]; then
    cli fake-fact --devnet --config "$CONFIG" --keccak "$(json "$OUT/$1.json" 'd["facts"]["sharp_fact_hash"]')"
  else
    cli fake-fact --devnet --config "$CONFIG" --fact "$(json "$OUT/$1.json" 'd["facts"]["integrity_fact_hash"]')"
  fi
}

step "settled, relayed by a third party: the second player's provisional record, the prover service's relay ($SETTLE fact)"
STORE="$OUT/prove"
JOB="$(python3 - "$OUT/a5.json" "$STORE" "$ROOT" <<'EOF'
import json, sys
from pathlib import Path
sys.path.insert(0, f"{sys.argv[3]}/services/prove")
import prove_service as ps
run, store = json.load(open(sys.argv[1])), Path(sys.argv[2])
name, level_hash, _ = ps.resolve_level(run["level"])
inputs = [int(x, 16) for x in run["inputs"]]
jid = ps.job_id(level_hash, inputs, "e2e", ps.DEFAULT_RESULT)
ps.Store(store).save({"id": jid, "state": "submitted", "level": name, "level_hash": hex(level_hash),
                      "inputs": run["inputs"], "outputs": run["outputs"], "result": ps.DEFAULT_RESULT, "error": None,
                      "run": {k: run["facts"][k] for k in ("child_program_hash", "integrity_fact_hash", "sharp_fact_hash")}})
print(jid)
EOF
)"
relay() { relay_env python3 "$ROOT/services/prove/prove_service.py" relay "$JOB" --store "$STORE"; }
if relay >"$OUT/relay-early.json"; then
  echo "e2e: the relay sent a settle before the fact existed" >&2
  exit 1
fi
check "$OUT/relay-early.json" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
assert not r["settleable"] and r["relay"]["state"] == "waiting" and not r["relayed"], r
print(f"e2e: relay waits while the fact is absent: {r['relay']}", file=sys.stderr)
EOF
register_fact a5
relay >"$OUT/relay.json" || { echo "e2e: the relay did not settle:" >&2; cat "$OUT/relay.json" >&2; exit 1; }
cli best --config "$CONFIG" --player "$SECOND" --level "$PILE10" --settled >"$OUT/best-settled.json"
cli attempt --config "$CONFIG" --level "$PILE10" --player "$SECOND" --inputs-hash "$(json "$OUT/a5.json" 'd["outputs"][4]')" >"$OUT/attempt-settled.json"
cli boards --config "$CONFIG" --level "$PILE10" >"$OUT/boards-settled.json"
check "$OUT" "$PLAYER" "$SECOND" "$RELAY" "$RPC" "$BUNDLE" "$CHILD" <<'EOF'
import json, sys, urllib.request
out, player, second, relay_account, rpc = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16), int(sys.argv[4], 16), sys.argv[5]
bundle, child = int(sys.argv[6], 16), int(sys.argv[7], 16)
load = lambda name: json.load(open(f"{out}/{name}.json"))
a5, relay, settled, attempt, boards, submit = (load(n) for n in ("a5", "relay", "best-settled", "attempt-settled", "boards-settled", "submit-a5"))
score = int(a5["outputs"][5], 16)
assert relay["relayed"] and relay["relay"]["state"] == "relayed", relay
tx = relay["relay"]["transaction_hash"]
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "starknet_getTransactionByHash", "params": {"transaction_hash": tx}}).encode()
sent = json.load(urllib.request.urlopen(urllib.request.Request(rpc, body, {"Content-Type": "application/json"})))["result"]
assert int(sent["sender_address"], 16) == relay_account, sent  # a third party sent it ...
assert settled["settled"] and settled["score"] == score and int(settled["programHash"], 16) == child, settled  # ... for the player
assert attempt["attempt"] == 2 and attempt["tier"] == "settled", attempt
rows = {int(r["player"], 16): (r["proof"], int(r["programHash"], 16)) for r in boards["settled"]}
assert rows == {player: ("snip36", bundle), second: ("sharp", child)}, boards["settled"]
settle_gas, attested = relay["relay"]["gas"]["l2Gas"], submit["gas"]["l2Gas"]
print(f"e2e: relayed settle {tx} by {hex(relay_account)}; submit_settled l2_gas {settle_gas:,} "
      f"= {settle_gas / attested:.2f}x the attested submit; settled board: proven by SNIP-36 and settled by SHARP", file=sys.stderr)
EOF
cli submit-settled --devnet --index 3 --config "$CONFIG" --outputs "$OUT/a5.json" --args "$OUT/a5.args.json" \
  --child-hash "$CHILD" --expect-panic 'submit: nullifier' >"$OUT/resettle.json"
step "the second player's own settle after the relay: $(tr -d '\n ' <"$OUT/resettle.json")"

step "retired chain: pin a second chain with a ${GRACE} s grace; the first chain's proofs pass inside it, not after"
PROOF0="$(ls "$PROVEN_STORE"/*/proof-0.json)"
cli deploy-split --devnet --out "$OUT/split-2.json" --salt 0x2 >/dev/null
cli pin-chain --devnet --config "$CONFIG" --split "$OUT/split-2.json" --grace "$GRACE" >"$OUT/pin-chain-2.json"
cli submit-proof --devnet --index 2 --config "$CONFIG" --proof "$PROOF0" >"$OUT/resubmit-proof-grace.json"
cli devnet-time --advance $((GRACE + 1)) >"$OUT/time-0.json"
cli submit-proof --devnet --index 2 --config "$CONFIG" --proof "$PROOF0" --expect-panic 'chunk: chain' >"$OUT/resubmit-proof-retired.json"
cli finalize --devnet --index 2 --config "$CONFIG" --chain "$CHAIN" --level "$PILE10" --inputs "$OUT/a1.json" --outputs "$OUT/a1.json" \
  --expect-panic 'finalize: chain' >"$OUT/finalize-retired.json"
check "$OUT" "$CHAIN" "$BUNDLE" <<'EOF'
import json, sys
out, chain, bundle = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
load = lambda name: json.load(open(f"{out}/{name}.json"))
pin, grace, retired, fin = load("pin-chain-2"), load("resubmit-proof-grace"), load("resubmit-proof-retired"), load("finalize-retired")
assert int(pin["previous"], 16) == chain and int(pin["bundle_hash"], 16) == bundle and pin["grace_s"] == 3600, pin
assert grace["transaction_hash"] and grace["level_validated"] == [], grace  # idempotent inside the grace
assert retired["rejected"] == "chunk: chain" and fin["rejected"] == "finalize: chain", (retired, fin)
print(f"e2e: chain {hex(chain)} retired: accepted inside its grace, then refused ('chunk: chain', 'finalize: chain')", file=sys.stderr)
EOF

step "re-pin with a ${GRACE} s grace: old proofs settle inside the window, not after"
register_fact a2
register_fact a3
NEW_PROGRAM="$(python3 -c "import sys; print(hex(int(sys.argv[1], 16) + 1))" "$CHILD")"
cli pin-program --devnet --config "$CONFIG" --child-hash "$NEW_PROGRAM" --grace "$GRACE" >"$OUT/pin.json"
cli program --config "$CONFIG" --child-hash "$CHILD" >"$OUT/program-old.json"
check "$OUT/pin.json" "$OUT/program-old.json" "$CHILD" "$NEW_PROGRAM" "$GRACE" <<'EOF'
import json, sys
pin, old = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
child, new, grace = int(sys.argv[3], 16), int(sys.argv[4], 16), int(sys.argv[5])
assert int(pin["program_hash"], 16) == new and int(pin["previous"], 16) == child and pin["grace_s"] == grace, pin
assert int(old["current"], 16) == new and old["valid"] and int(old["valid_until"]) == int(pin["previous_valid_until"]), old
print(f"e2e: pinned {hex(new)}; {hex(child)} valid until {old['valid_until']} (now {old['now']})", file=sys.stderr)
EOF
cli submit-settled --devnet --index 1 --config "$CONFIG" --outputs "$OUT/a2.json" --args "$OUT/a2.args.json" \
  --child-hash "$CHILD" --simulate >"$OUT/settle-grace-simulated.json"
cli submit-settled --devnet --index 1 --config "$CONFIG" --outputs "$OUT/a2.json" --args "$OUT/a2.args.json" \
  --child-hash "$CHILD" >"$OUT/settle-grace.json"
check "$OUT/settle-grace.json" "$CHILD" <<'EOF'
import json, sys
settle, child = json.load(open(sys.argv[1])), int(sys.argv[2], 16)
[event] = settle["level_validated"]
assert event["settled"] and not event["proven"] and int(event["programHash"], 16) == child, event
print(f"e2e: the old program's proof settled inside the grace window ({settle['transaction_hash']})", file=sys.stderr)
EOF
cli devnet-time --advance $((GRACE + 1)) >"$OUT/time-1.json"
cli submit-settled --devnet --index 1 --config "$CONFIG" --outputs "$OUT/a3.json" --args "$OUT/a3.args.json" \
  --child-hash "$CHILD" --simulate --expect-panic 'submit: program' >"$OUT/settle-stale-simulated.json"
cli submit-settled --devnet --index 1 --config "$CONFIG" --outputs "$OUT/a3.json" --args "$OUT/a3.args.json" \
  --child-hash "$CHILD" --expect-panic 'submit: program' >"$OUT/settle-stale.json"
step "after the grace: $(tr -d '\n ' <"$OUT/settle-stale.json")"

step "expired provisional record: 24 h later the third party expires the admin's"
cli devnet-time --advance 86400 >"$OUT/time-2.json"
cli leaderboard --config "$CONFIG" --level "$PILE10" --provisional >"$OUT/board-before-expire.json"
cli expire --devnet --index 2 --config "$CONFIG" --level "$PILE10" --player "$ADMIN" >"$OUT/expire.json"
cli best --config "$CONFIG" --player "$ADMIN" --level "$PILE10" >"$OUT/best-expired.json"
cli leaderboard --config "$CONFIG" --level "$PILE10" --provisional >"$OUT/board-expired.json"
check "$OUT/best-expired.json" "$OUT/board-before-expire.json" "$OUT/board-expired.json" "$ADMIN" "$PLAYER" "$SECOND" <<'EOF'
import json, sys
best, before, board = (json.load(open(p)) for p in sys.argv[1:4])
admin, player, second = (int(x, 16) for x in sys.argv[4:7])
assert any(int(r["player"], 16) == admin for r in before), before
assert best["score"] == 0 and not best["settled"] and not best["won"], best
assert sorted(int(r["player"], 16) for r in board) == sorted([player, second]), board
print(f"e2e: expired; the admin's best {best}, live board {board}", file=sys.stderr)
EOF
cli expire --devnet --index 2 --config "$CONFIG" --level "$PILE10" --player "$ADMIN" --expect-panic 'expire: none' >"$OUT/expire-again.json"
cat "$OUT/expire-again.json" >&2

step "OK ($((SECONDS - STARTED)) s)"
