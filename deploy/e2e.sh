#!/usr/bin/env bash
# End-to-end check of the Stub path on a fresh local devnet (lot G9, docs/e2e.md):
#
#   devnet up -> deploy (Stub verifier, attestation key, six levels)
#   -> the golden reference shot on pile10 replayed with `scarb execute` for the devnet account
#   -> POST /attest to attest.py -> submit(outputs, [r, s]) from that account
#   -> LevelValidated emitted, best(player, pile10) = the score, the leaderboard lists the player
#   -> the same submit again is rejected with 'submit: nullifier'
#   -> the settled tier, mocked (lot E3b): the run's Atlantic fact (tools/atlantic/encoding.py) is
#      registered on the devnet's FakeSatellite, submit_settled(outputs, args) upgrades the attempt
#      (LevelValidated settled, best().settled), a second submit_settled is rejected
#
# E2E_SETTLE=keccak registers only the bridged keccak fact (the path Sepolia takes while
# Atlantic's translation stalls), else only the translated Poseidon fact.
#   deploy/e2e.sh [--keep]     --keep leaves the devnet running (deploy/devnet.sh down stops it)
#
# The attestation service runs `--no-verify` (no proof in this check) unless E2E_PROOF names a
# proof of these outputs and tools/prove/verify.py (lot P1) exists. Ports: E2E_DEVNET_PORT
# (5055, apart from a dev devnet on 5050), E2E_ATTEST_PORT (8548). Everything is written to
# deploy/out/e2e/.
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
CASE=pile10-reference
KEEP="${1:-}"
mkdir -p "$OUT"
rm -f "$OUT"/*.json

step() { echo "e2e: $*" >&2; }
json() { python3 -c "import json, sys; d = json.load(open(sys.argv[1])); print($2)" "$1"; }
cli() { node "$ROOT/deploy/slingfall.ts" "$@" --rpc "$RPC"; }

attest_pid=""
cleanup() {
  [ -n "$attest_pid" ] && kill "$attest_pid" 2>/dev/null || true
  [ "$KEEP" = "--keep" ] || "$ROOT/deploy/devnet.sh" down
}
trap cleanup EXIT

# A fresh devnet: nullifiers and records from an earlier run would fail the checks.
"$ROOT/deploy/devnet.sh" down
step "devnet up and deploy"
"$ROOT/deploy/devnet.sh" all
CONFIG="$DEVNET_OUT"
LEVEL="$(json "$CONFIG" 'd["levels"]["pile10"]')"
PLAYER="$(cli account)"
step "contract $(json "$CONFIG" 'd["address"]'), pile10 $LEVEL, player $PLAYER"

step "replay $CASE for the player (scarb execute main)"
CHILD_HASH="$(json "$CONFIG" 'd["satellite"]["child_program_hash"]')"
python3 "$ROOT/deploy/outputs.py" --case "$CASE" --player "$PLAYER" --child-hash "$CHILD_HASH" \
  --out "$OUT/outputs.json"
SCORE="$(json "$OUT/outputs.json" 'int(d["outputs"][5], 16)')"
WON="$(json "$OUT/outputs.json" 'int(d["outputs"][6], 16)')"

step "attest"
verify=(--no-verify)
request=()
if [ -n "${E2E_PROOF:-}" ] && [ -f "$ROOT/tools/prove/verify.py" ]; then
  verify=(--verify-cmd "python3 $ROOT/tools/prove/verify.py")
  request=(--proof-path "$E2E_PROOF")
fi
SLINGFALL_ATTEST_KEY="$ATTEST_KEY" python3 "$ROOT/services/attest/attest.py" serve "${verify[@]}" \
  --port "$ATTEST_PORT" 2>"$OUT/attest.log" &
attest_pid=$!
for _ in $(seq 1 50); do
  python3 -c "import urllib.request; urllib.request.urlopen('$ATTEST_URL/health', timeout=1)" 2>/dev/null && break
  sleep 0.2
done
python3 "$ROOT/services/attest/attest.py" request --url "$ATTEST_URL" --outputs "$OUT/outputs.json" \
  "${request[@]}" >"$OUT/attestation.json"
SIGNATURE="$(json "$OUT/attestation.json" '",".join(d["signature"])')"
step "attestation $(json "$OUT/attestation.json" 'd["attestation_hash"]') verified=$(json "$OUT/attestation.json" 'd["verified"]')"

step "submit"
cli submit --devnet --config "$CONFIG" --outputs "$OUT/outputs.json" --signature "$SIGNATURE" >"$OUT/submit.json"
json "$OUT/submit.json" 'd["transaction_hash"]' >&2
python3 - "$OUT/submit.json" "$PLAYER" "$LEVEL" "$SCORE" "$WON" <<'EOF'
import json, sys
doc, player, level, score, won = json.load(open(sys.argv[1])), *sys.argv[2:]
[event] = doc["level_validated"]
assert int(event["player"], 16) == int(player, 16), event
assert int(event["levelHash"], 16) == int(level, 16), event
assert event["score"] == int(score) and event["won"] == (won == "1"), event
gas = doc["gas"]
print(f"e2e: LevelValidated ok; submit gas: l2_gas {gas['l2Gas']:,}, l1_data_gas {gas['l1DataGas']}, "
      f"l1_gas {gas['l1Gas']}, fee {int(gas['fee']):,} {gas['unit']}", file=sys.stderr)
EOF

step "best and leaderboard"
cli best --config "$CONFIG" --player "$PLAYER" --level "$LEVEL" >"$OUT/best.json"
cli leaderboard --config "$CONFIG" --level "$LEVEL" >"$OUT/leaderboard.json"
python3 - "$OUT/best.json" "$OUT/leaderboard.json" "$PLAYER" "$SCORE" "$WON" <<'EOF'
import json, sys
best, board = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
player, score, won = int(sys.argv[3], 16), int(sys.argv[4]), sys.argv[5] == "1"
assert best["score"] == score and best["won"] == won and best["block"] > 0 and not best["settled"], best
if won:
    assert [(int(r["player"], 16), r["score"]) for r in board] == [(player, score)], board
print(f"e2e: best {best}; leaderboard {board}", file=sys.stderr)
EOF

step "second submit (same outputs) must be rejected"
cli submit --devnet --config "$CONFIG" --outputs "$OUT/outputs.json" --signature "$SIGNATURE" \
  --expect-panic 'submit: nullifier' >"$OUT/resubmit.json"
cat "$OUT/resubmit.json" >&2

step "settle (mocked Satellite, ${E2E_SETTLE:-poseidon} fact)"
python3 -c "import json, sys; json.dump(json.load(open(sys.argv[1]))['args'], open(sys.argv[2], 'w'))" \
  "$OUT/outputs.json" "$OUT/args.json"
cli submit-settled --devnet --config "$CONFIG" --outputs "$OUT/outputs.json" --args "$OUT/args.json" \
  --expect-panic 'submit: proof' >"$OUT/settle-unknown.json"
step "no fact yet: $(cat "$OUT/settle-unknown.json")"
if [ "${E2E_SETTLE:-poseidon}" = keccak ]; then
  cli fake-fact --devnet --config "$CONFIG" --keccak "$(json "$OUT/outputs.json" 'd["facts"]["sharp_fact_hash"]')"
else
  cli fake-fact --devnet --config "$CONFIG" --fact "$(json "$OUT/outputs.json" 'd["facts"]["integrity_fact_hash"]')"
fi
cli submit-settled --devnet --config "$CONFIG" --outputs "$OUT/outputs.json" --args "$OUT/args.json" >"$OUT/settle.json"
cli best --config "$CONFIG" --player "$PLAYER" --level "$LEVEL" >"$OUT/best-settled.json"
python3 - "$OUT/settle.json" "$OUT/submit.json" "$OUT/best-settled.json" "$SCORE" <<'EOF'
import json, sys
settle, submit, best = (json.load(open(p)) for p in sys.argv[1:4])
[event] = settle["level_validated"]
assert event["settled"] and event["score"] == int(sys.argv[4]), event
assert best["settled"] and best["score"] == int(sys.argv[4]), best
attested, settled = submit["gas"]["l2Gas"], settle["gas"]["l2Gas"]
print(f"e2e: settled; submit_settled l2_gas {settled:,} = {settled / attested:.2f}x the attested submit "
      f"({attested:,}); fee {int(settle['gas']['fee']):,} {settle['gas']['unit']}", file=sys.stderr)
EOF
cli submit-settled --devnet --config "$CONFIG" --outputs "$OUT/outputs.json" --args "$OUT/args.json" \
  --expect-panic 'submit: nullifier' >"$OUT/resettle.json"
cat "$OUT/resettle.json" >&2

step "OK"
