#!/usr/bin/env bash
# End-to-end check of contract v2's two tiers on a fresh local devnet (lots G9, E3b, W1;
# docs/e2e.md). Accounts: #0 admin, #1 the player, #2 a third party (the relay).
#
#   devnet up -> deploy v2 (attestation key, pin_program(c1main, 0), FakeSatellite, six levels)
#   -> the golden shots replayed with `scarb execute` (deploy/outputs.py) for the player and admin
#   provisional tier:
#   -> attest.py --execute re-executes the replay and signs the v2 message (chain, contract,
#      program, epoch, expiry) -> the player's submit(outputs, [program_hash, expiry, r, s])
#   -> LevelValidated (provisional, program_hash), best / best_settled / both boards
#   -> the same submit again: 'submit: nullifier'
#   settled tier, relayed:
#   -> the prover service's relay (`prove_service.py relay`, account #2) waits while the fact is
#      absent, then, the run's Atlantic fact registered on the FakeSatellite, simulates and sends
#      submit_settled for claim.player; the player's own settle after it: 'submit: nullifier'
#   re-pin with grace (M7):
#   -> pin_program(new, 3600): a proof of the old program settles inside the window; after
#      devnet_increaseTime past it, another is refused with 'submit: program' (simulated first)
#   expired provisional record:
#   -> the admin's provisional record: expire() before the delay 'expire: early'; 24 h later
#      (devnet_increaseTime) the third party expires it (RecordExpired), a second expire 'expire: none'
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
RPC="http://127.0.0.1:${DEVNET_PORT}/rpc"
ATTEST_PORT="${E2E_ATTEST_PORT:-8548}"
ATTEST_URL="http://127.0.0.1:${ATTEST_PORT}"
ATTEST_KEY="${DEVNET_ATTEST_KEY:-0x736c696e6766616c6c2d6465766e6574}"
SETTLE="${E2E_SETTLE:-poseidon}"
GRACE=3600
KEEP="${1:-}"
mkdir -p "$OUT"
rm -rf "$OUT"/*.json "$OUT/prove"

step() { echo "e2e: $*" >&2; }
json() { python3 -c "import json, sys; d = json.load(open(sys.argv[1])); print($2)" "$1"; }
cli() { node "$ROOT/deploy/slingfall.ts" "$@" --rpc "$RPC"; }
check() { python3 - "$@"; }

attest_pid=""
cleanup() {
  [ -n "$attest_pid" ] && kill "$attest_pid" 2>/dev/null || true
  [ "$KEEP" = "--keep" ] || "$ROOT/deploy/devnet.sh" down
}
trap cleanup EXIT

# A fresh devnet: nullifiers and records from an earlier run would fail the checks.
"$ROOT/deploy/devnet.sh" down
step "devnet up and deploy (contract v2)"
"$ROOT/deploy/devnet.sh" all
CONFIG="$DEVNET_OUT"
ADDRESS="$(json "$CONFIG" 'd["address"]')"
CHILD="$(json "$CONFIG" 'd["program"]["current"]')"
PILE10="$(json "$CONFIG" 'd["levels"]["pile10"]')"
ADMIN="$(cli account --index 0)"
PLAYER="$(cli account --index 1)"
RELAY="$(cli account --index 2)"
cli program --config "$CONFIG" >"$OUT/program.json"
check "$OUT/program.json" "$CHILD" <<'EOF'
import json, sys
program, child = json.load(open(sys.argv[1])), int(sys.argv[2], 16)
assert int(program["current"], 16) == child and program["valid"], program
EOF
step "contract $ADDRESS, program $CHILD; admin $ADMIN, player $PLAYER, relay $RELAY"

step "replays (scarb execute main): pile10 and two one_block shots for the player, pile10 for the admin"
outputs() { python3 "$ROOT/deploy/outputs.py" --case "$1" --player "$2" --child-hash "$CHILD" --out "$OUT/$3.json" ${4:-}; }
outputs pile10-reference "$PLAYER" a1
outputs one_block-delay30 "$PLAYER" a2 --no-build
outputs one_block-disk-boundary "$PLAYER" a3 --no-build
outputs pile10-reference "$ADMIN" a4 --no-build
for run in a1 a2 a3 a4; do
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

step "provisional: the player's attested submit"
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
assert not event["settled"] and int(event["programHash"], 16) == child, event
assert best["score"] == score and not best["settled"] and best["timestamp"] > 0 and int(best["programHash"], 16) == child, best
assert settled["score"] == 0 and not settled["won"], settled
assert boards["settled"] == [], boards
if won:
    assert [(int(r["player"], 16), r["score"], r["settled"]) for r in boards["provisional"]] == [(player, score, False)], boards
gas = submit["gas"]
print(f"e2e: provisional ok; submit l2_gas {gas['l2Gas']:,}, fee {int(gas['fee']):,} {gas['unit']}", file=sys.stderr)
EOF

step "the same submit again must be rejected"
cli submit --devnet --index 1 --config "$CONFIG" --outputs "$OUT/a1.json" --attestation "$OUT/attestation-a1.json" \
  --expect-panic 'submit: nullifier' >"$OUT/resubmit.json"
cat "$OUT/resubmit.json" >&2

step "the admin's provisional record (to expire later); expire now is early"
attest a4
cli submit --devnet --index 0 --config "$CONFIG" --outputs "$OUT/a4.json" --attestation "$OUT/attestation-a4.json" >"$OUT/submit-a4.json"
cli expire --devnet --index 2 --config "$CONFIG" --level "$PILE10" --player "$ADMIN" --expect-panic 'expire: early' >"$OUT/expire-early.json"
cat "$OUT/expire-early.json" >&2

register_fact() {
  if [ "$SETTLE" = keccak ]; then
    cli fake-fact --devnet --config "$CONFIG" --keccak "$(json "$OUT/$1.json" 'd["facts"]["sharp_fact_hash"]')"
  else
    cli fake-fact --devnet --config "$CONFIG" --fact "$(json "$OUT/$1.json" 'd["facts"]["integrity_fact_hash"]')"
  fi
}

step "settled, relayed by a third party: the prover service's relay (account #2, $SETTLE fact)"
STORE="$OUT/prove"
JOB="$(python3 - "$OUT/a1.json" "$STORE" "$ROOT" <<'EOF'
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
relay() {
  env SLINGFALL_ADDRESS="$ADDRESS" STARKNET_RPC_URL="$RPC" STARKNET_ACCOUNT_ADDRESS="$RELAY" \
    STARKNET_PRIVATE_KEY="$(cli account --index 2 --with-key | python3 -c 'import json, sys; print(json.load(sys.stdin)["private_key"])')" \
    python3 "$ROOT/services/prove/prove_service.py" relay "$JOB" --store "$STORE"
}
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
register_fact a1
relay >"$OUT/relay.json"
cli best --config "$CONFIG" --player "$PLAYER" --level "$PILE10" >"$OUT/best-relayed.json"
cli best --config "$CONFIG" --player "$PLAYER" --level "$PILE10" --settled >"$OUT/best-settled.json"
cli boards --config "$CONFIG" --level "$PILE10" >"$OUT/boards-settled.json"
check "$OUT" "$PLAYER" "$RELAY" "$RPC" <<'EOF'
import json, sys, urllib.request
out, player, relay_account, rpc = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16), sys.argv[4]
load = lambda name: json.load(open(f"{out}/{name}.json"))
a1, relay, best, settled, boards, submit = (load(n) for n in ("a1", "relay", "best-relayed", "best-settled", "boards-settled", "submit"))
score, won = int(a1["outputs"][5], 16), int(a1["outputs"][6], 16) == 1
assert relay["relayed"] and relay["relay"]["state"] == "relayed", relay
tx = relay["relay"]["transaction_hash"]
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "starknet_getTransactionByHash", "params": {"transaction_hash": tx}}).encode()
sent = json.load(urllib.request.urlopen(urllib.request.Request(rpc, body, {"Content-Type": "application/json"})))["result"]
assert int(sent["sender_address"], 16) == relay_account, sent  # a third party sent it ...
assert best["settled"] and best["score"] == score, best          # ... for the player
assert settled["settled"] and settled["score"] == score, settled
if won:
    assert [(int(r["player"], 16), r["score"]) for r in boards["settled"]] == [(player, score)], boards
    assert [r["settled"] for r in boards["provisional"] if int(r["player"], 16) == player] == [True], boards
settle_gas, attested = relay["relay"]["gas"]["l2Gas"], submit["gas"]["l2Gas"]
print(f"e2e: relayed settle {tx} by {hex(relay_account)}; submit_settled l2_gas {settle_gas:,} "
      f"= {settle_gas / attested:.2f}x the attested submit", file=sys.stderr)
EOF
cli submit-settled --devnet --index 1 --config "$CONFIG" --outputs "$OUT/a1.json" --args "$OUT/a1.args.json" \
  --child-hash "$CHILD" --expect-panic 'submit: nullifier' >"$OUT/resettle.json"
step "the player's own settle after the relay: $(tr -d '\n ' <"$OUT/resettle.json")"

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
assert event["settled"] and int(event["programHash"], 16) == child, event
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
check "$OUT/best-expired.json" "$OUT/board-before-expire.json" "$OUT/board-expired.json" "$ADMIN" "$PLAYER" <<'EOF'
import json, sys
best, before, board = (json.load(open(p)) for p in sys.argv[1:4])
admin, player = int(sys.argv[4], 16), int(sys.argv[5], 16)
assert any(int(r["player"], 16) == admin for r in before), before
assert best["score"] == 0 and not best["settled"] and not best["won"], best
assert [int(r["player"], 16) for r in board] == [player], board
print(f"e2e: expired; the admin's best {best}, live board {board}", file=sys.stderr)
EOF
cli expire --devnet --index 2 --config "$CONFIG" --level "$PILE10" --player "$ADMIN" --expect-panic 'expire: none' >"$OUT/expire-again.json"
cat "$OUT/expire-again.json" >&2

step "OK"
