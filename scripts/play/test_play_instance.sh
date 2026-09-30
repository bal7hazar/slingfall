#!/usr/bin/env bash
# Test of `scripts/play.sh`'s service reuse (lot H4): a service is reused only for the same contract AND the
# same devnet instance; a redeployed devnet (same seed, same address, new instance) stops and restarts it.
#   scripts/play/test_play_instance.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLAY_SOURCED=1 . "$ROOT/scripts/play.sh"
PLAY="$(mktemp -d)"
failed=0
check() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: got '$2', want '$3'"; failed=1; fi; }

# A live process of "ours" (its command line holds the marker), recorded as `start` does.
spawn() {
  bash -c 'sleep 120; :' prove_local.py >/dev/null 2>&1 &
  SPID=$!
  printf '%s\n%s\n%s\n' "$SPID" "$1" "$2" >"$(pid_file prove)"
}
alive() { if kill -0 "$SPID" 2>/dev/null; then echo alive; else echo stopped; fi; }

new_instance
OLD="$(instance)"
check "an instance is recorded" "$([ -n "$OLD" ] && echo yes)" yes

spawn 0xabc "$OLD"
fresh prove 59123 0xabc && rc=0 || rc=$?
check "same contract, same instance: reused" "$rc" 1
check "the service still runs" "$(alive)" alive

echo "$OLD-redeployed" >"$PLAY/devnet.instance" # the devnet was redeployed: same seed, same contract address
fresh prove 59123 0xabc && rc=0 || rc=$?
check "same contract, other instance: started again" "$rc" 0
check "the old service was stopped" "$(alive)" stopped

spawn 0xabc "$(instance)"
fresh prove 59123 0xdef && rc=0 || rc=$?
check "other contract: started again" "$rc" 0
check "that service was stopped too" "$(alive)" stopped

kill "$SPID" 2>/dev/null || true

# The prover store's chain note (fake devnet height, fake files): fresh, clean reload, rollback.
HEIGHT=30
block_number() { echo "$HEIGHT"; }
intact() { chain_intact && echo intact || echo rollback; }
mkdir -p "$PLAY/prove/0xabc"
new_instance

check "fresh (no note, nothing saved): a rollback, so the store is dropped" "$(intact)" rollback

mark_chain_clean # a clean `down` at height 30
check "the note is '<instance> <height>'" "$(cat "$PLAY/prove/.chain")" "$(instance) 30"
check "clean reload (same instance, same height): everything kept" "$(intact)" intact
check "the note is consumed by the reload" "$([ -f "$PLAY/prove/.chain" ] && echo there || echo gone)" gone
check "a second reload without a clean down in between: rollback (the devnet was lost unsaved)" "$(intact)" rollback

mark_chain_clean
HEIGHT=12 # an older dump put back
check "older dump (height lower than the note): rollback" "$(intact)" rollback

HEIGHT=30
mark_chain_clean
echo "$(instance)-other" >"$PLAY/devnet.instance"
check "another instance: rollback" "$(intact)" rollback

HEIGHT=30
new_instance
mark_chain_clean
HEIGHT=""
check "a devnet that does not answer: rollback, never 'intact'" "$(intact)" rollback
rm -rf "$PLAY"
exit "$failed"
