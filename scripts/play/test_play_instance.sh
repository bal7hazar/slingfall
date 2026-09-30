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
rm -rf "$PLAY"
exit "$failed"
