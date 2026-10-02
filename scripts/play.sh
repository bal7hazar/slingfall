#!/usr/bin/env bash
# Play Slingfall on this machine with one command (lot L1, docs/play-local.md): a local devnet, both
# services and the client, the three validation tiers with no credential, no testnet, no wallet.
#
#   scripts/play.sh [up]      build what is missing (once), start what is not running, print the URL
#   scripts/play.sh down      stop exactly what `up` started (the devnet saves its state first)
#   scripts/play.sh status    what runs, where, and the contract
#   scripts/play.sh doctor    check the prerequisites and say how to install what is missing
#   scripts/play.sh reset     `down`, then forget the devnet's state: the next `up` redeploys
#
# What `up` runs, each on 127.0.0.1, logs and PID files under target/play/:
#   devnet   deploy/devnet.sh: starknet-devnet 0.10.0, contract v3, proven tier open; its state is
#            saved on `down` (target/play/devnet-state.json) and loaded by the next `up`
#   attest   services/attest/attest.py serve --execute, the public devnet test key ('slingfall-devnet')
#   prove    scripts/play/prove_local.py: the prover service, fake SNIP-36 prover (proven tier) and
#            fake Atlantic + the devnet's FakeSatellite (settled tier), relaying for the player
#   client   Vite (client/), devnet mode, the player = devnet account #1; the devnet and the services
#            behind its proxy (scripts/play/vite.config.mts)
# Accounts (starknet-devnet --seed 0): #0 admin (and the FakeSatellite's facts), #1 the player, #2 the
# SNIP-36 path of the prover service, #3 its relay.
#
# Environment (all optional):
#   PLAY_HOST (127.0.0.1)   the dev server's address; 0.0.0.0 to play from another device of the same
#                           network (docs/play-local.md: never on a network exposed to the internet)
#   PLAY_PORT (5173)  PLAY_DEVNET_PORT (5050)  PLAY_ATTEST_PORT (8547)  PLAY_PROVE_PORT (8549)
#   PLAY_NO_VM=1            do not build the wasm runner (headless checks: the page then replays a
#                           recorded trace)
# The local mode ignores the caller's STARKNET_*, SLINGFALL_*, ATLANTIC_*, VITE_* and DEVNET_*
# variables (and starknet-devnet's own, e.g. FORK_NETWORK): each child gets the devnet's values only.
set -euo pipefail
# Sierra is not deterministic across compiler threads: every build here runs on one (docs/proving.md "Deterministic builds").
export RAYON_NUM_THREADS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAY="$ROOT/target/play"
HOST="${PLAY_HOST:-127.0.0.1}"
PORT="${PLAY_PORT:-5173}"
DEVNET_PORT="${PLAY_DEVNET_PORT:-5050}"
ATTEST_PORT="${PLAY_ATTEST_PORT:-8547}"
PROVE_PORT="${PLAY_PROVE_PORT:-8549}"
RPC="http://127.0.0.1:${DEVNET_PORT}/rpc"
ATTEST_KEY=0x736c696e6766616c6c2d6465766e6574 # 'slingfall-devnet': public, devnet only
CONFIG="$PLAY/devnet.json"
DUMP="$PLAY/devnet-state.json"
WASM="$ROOT/client/vm/pkg/slingfall_vm_runner_bg.wasm"
REPLAY_BUILT="$ROOT/crates/slingfall_replay/target/dev/main.executable.json"
SPLIT_BUILT="$ROOT/target/dev/slingfall_split_SplitChain.contract_class.json"

say() { echo "play: $*" >&2; }
die() {
  say "$*"
  exit 1
}

# ------------------------------------------------------------------ environment (lot B6's defect)

# `tools/atlantic`'s `account_env` prefers STARKNET_RPC to STARKNET_RPC_URL while its reads use the
# latter: a caller with both set could read the devnet and send to another network. The local mode
# drops every such variable and sets both names to the devnet.
scrub_env() {
  local names
  names="$(env | grep -E '^(STARKNET|SLINGFALL|ATLANTIC|VITE|DEVNET)_[A-Za-z0-9_]*=' | cut -d= -f1 | sort -u | tr '\n' ' ' || true)"
  # starknet-devnet reads these too when its flags leave them out.
  local name
  for name in FORK_NETWORK FORK_BLOCK FORK_UPSTREAM_CACHING BLOCK_GENERATION_ON LITE_MODE RESTRICTIVE_MODE \
    STATE_ARCHIVE_CAPACITY CHAIN_ID START_TIME ACCOUNT_CLASS ACCOUNT_CLASS_CUSTOM INITIAL_BALANCE DUMP_ON DUMP_PATH; do
    if [ -n "${!name+x}" ]; then names="$names$name "; fi
  done
  if [ -n "$names" ]; then
    say "local mode: ignoring your ${names% } (every child gets the devnet's values only)"
    for name in $names; do unset "$name"; done
  fi
}

# ------------------------------------------------------------------ processes

pid_file() { echo "$PLAY/$1.pid"; }
devnet_env() { env DEVNET_PORT="$DEVNET_PORT" DEVNET_RUN="$PLAY" DEVNET_DUMP="$DUMP" DEVNET_OUT="$CONFIG" \
  DEVNET_ENV="$PLAY/devnet.env" DEVNET_SPLIT_OUT="$PLAY/devnet-split.json" DEVNET_ATTEST_KEY="$ATTEST_KEY" "$@"; }

# A process of ours: its PID file names a live process whose command line holds `marker`.
running() {
  local file marker pid
  file="$(pid_file "$1")" marker="$2"
  [ "$1" = devnet ] && file="$PLAY/devnet-${DEVNET_PORT}.pid"
  [ -f "$file" ] || return 1
  pid="$(head -n1 "$file")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o command= 2>/dev/null | grep -q -- "$marker"
}
marker() {
  case "$1" in
    devnet) echo starknet-devnet ;;
    attest) echo "attest.py serve" ;;
    prove) echo prove_local.py ;;
    client) echo "scripts/play/vite.config.mts" ;;
  esac
}
# The contract a running service was started for (second line of its PID file).
started_for() { sed -n 2p "$(pid_file "$1")" 2>/dev/null || true; }
# The devnet instance (a token written at each fresh deployment, kept while its state is loaded again):
# the seed is fixed, so a redeployed devnet has the same contract address, and a service started for
# the old chain must not be mistaken for one of this chain. Third line of a service's PID file.
instance() { cat "$PLAY/devnet.instance" 2>/dev/null || true; }
started_on() { sed -n 3p "$(pid_file "$1")" 2>/dev/null || true; }
new_instance() { printf '%s-%s\n' "$(date +%s)" "$$" >"$PLAY/devnet.instance"; }

# The chain height (latest block number) of the devnet; empty when it does not answer.
block_number() {
  python3 - "$RPC" <<'EOF' 2>/dev/null || true
import json, sys, urllib.request
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "starknet_blockNumber"}).encode()
print(json.load(urllib.request.urlopen(urllib.request.Request(sys.argv[1], body, {"Content-Type": "application/json"}), timeout=10))["result"])
EOF
}

# A clean `down` leaves "<instance> <height>" in the prover store (saved state and store agree at
# that height). `up` consumes it: a state loaded at any other height, another instance, or no note
# at all (the devnet was lost unsaved, an older dump was put back) is a rollback, and the jobs the
# store holds may belong to a chain that no longer exists.
mark_chain_clean() {
  local height
  height="$(block_number)"
  [ -n "$height" ] || return 0
  mkdir -p "$PLAY/prove"
  printf '%s %s\n' "$(instance)" "$height" >"$PLAY/prove/.chain"
}
# 0 when the loaded state is the one the last clean `down` saved; consumes the note either way.
chain_intact() {
  local note height
  note="$(cat "$PLAY/prove/.chain" 2>/dev/null || true)"
  rm -f "$PLAY/prove/.chain"
  height="$(block_number)"
  [ -n "$note" ] && [ -n "$height" ] && [ "$note" = "$(instance) $height" ]
}

port_free() {
  python3 - "$1" <<'EOF'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
EOF
}

http_ok() { curl -fsS --max-time 2 -o /dev/null "$1" 2>/dev/null; }

wait_http() {
  local name="$1" url="$2" log="$3" i
  for i in $(seq 1 150); do
    if http_ok "$url"; then return 0; fi
    sleep 0.2
  done
  tail -n 20 "$log" >&2 || true
  die "$name did not answer on $url (log $log)"
}

stop() {
  local name="$1" file pid
  file="$(pid_file "$name")"
  if running "$name" "$(marker "$name")"; then
    pid="$(head -n1 "$file")"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    say "$name stopped (pid $pid)"
  fi
  rm -f "$file"
}

json_get() { python3 -c "import json, sys; d = json.load(open(sys.argv[1])); print($2)" "$1"; }

# The devnet holds the deployment of $CONFIG (the state loaded from $DUMP, or the running devnet's).
deployed() {
  [ -f "$CONFIG" ] || return 1
  python3 - "$RPC" "$(json_get "$CONFIG" 'd["address"]')" "$(json_get "$CONFIG" 'd["class_hash"]')" <<'EOF'
import json, sys, urllib.request
rpc, address, class_hash = sys.argv[1:]
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "starknet_getClassHashAt",
                   "params": {"block_id": "latest", "contract_address": address}}).encode()
try:
    answer = json.load(urllib.request.urlopen(urllib.request.Request(rpc, body, {"Content-Type": "application/json"}), timeout=10))
except Exception:
    sys.exit(1)
sys.exit(0 if int(answer.get("result", "0x0"), 16) == int(class_hash, 16) else 1)
EOF
}

# Devnet accounts #1..#3 (deterministic with --seed 0) as `index address key` lines.
accounts() {
  python3 - "$RPC" <<'EOF'
import json, sys, urllib.request
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "devnet_getPredeployedAccounts"}).encode()
accounts = json.load(urllib.request.urlopen(urllib.request.Request(sys.argv[1], body, {"Content-Type": "application/json"}), timeout=10))["result"]
for i in (1, 2, 3):
    print(i, accounts[i]["address"], accounts[i]["private_key"])
EOF
}
account() { awk -v i="$1" -v f="$2" '$1 == i { print $f }' "$PLAY/accounts.txt"; }

# ------------------------------------------------------------------ builds (once)

build() {
  local lock="$ROOT/client/node_modules/.package-lock.json"
  if [ ! -f "$lock" ] || [ "$ROOT/client/package-lock.json" -nt "$lock" ]; then
    say "client dependencies (npm ci, once)"
    npm --prefix "$ROOT/client" ci --no-audit --no-fund >"$PLAY/npm.log" 2>&1 || { tail -n 20 "$PLAY/npm.log" >&2; die "npm ci failed"; }
  fi
  if [ ! -f "$WASM" ]; then
    if [ "${PLAY_NO_VM:-}" = 1 ]; then
      say "PLAY_NO_VM=1: the wasm runner is not built; the page replays a recorded trace"
    else
      command -v cargo >/dev/null || die "the wasm runner needs Rust (https://rustup.rs), once; or PLAY_NO_VM=1 (scripts/play.sh doctor)"
      say "the wasm runner (client/vm/scripts/build.sh, once: a few minutes; log $PLAY/vm-build.log)"
      "$ROOT/client/vm/scripts/build.sh" >"$PLAY/vm-build.log" 2>&1 || { tail -n 20 "$PLAY/vm-build.log" >&2; die "wasm runner build failed"; }
    fi
  fi
  # One scarb build at a time: two in parallel stalled for over 10 minutes on a 4-core CI runner
  # (both wait on scarb's shared caches). The contract: deploy/devnet.sh builds it (scarb caches).
  if [ ! -f "$REPLAY_BUILT" ]; then
    say "the replay executables (scarb build of crates/slingfall_replay, once: a few minutes)"
    scarb --manifest-path "$ROOT/crates/slingfall_replay/Scarb.toml" build >"$PLAY/replay-build.log" 2>&1 ||
      { tail -n 20 "$PLAY/replay-build.log" >&2; die "replay build failed"; }
  fi
  if [ ! -f "$SPLIT_BUILT" ]; then
    say "the proven tier's classes (scarb build -p slingfall_split, once: a minute or two)"
    scarb --manifest-path "$ROOT/Scarb.toml" build -p slingfall_split >"$PLAY/split-build.log" 2>&1 ||
      { tail -n 20 "$PLAY/split-build.log" >&2; die "split classes build failed"; }
  fi
}

# ------------------------------------------------------------------ up

up_devnet() {
  if running devnet starknet-devnet; then
    deployed || die "the devnet on :$DEVNET_PORT runs without the deployment of $CONFIG: scripts/play.sh reset"
    say "devnet: reused on :$DEVNET_PORT"
    return
  fi
  port_free "$DEVNET_PORT" || die "port $DEVNET_PORT is taken by another process: stop it or set PLAY_DEVNET_PORT"
  devnet_env "$ROOT/deploy/devnet.sh" up
  if deployed; then
    say "devnet: state loaded from $DUMP"
    if ! chain_intact; then
      say "devnet: this state is not the one the last clean 'down' saved (a rollback): dropping the prover's jobs"
      stop client
      stop prove
      stop attest
      rm -rf "$PLAY/prove"
      new_instance
    fi
    [ -n "$(instance)" ] || new_instance
    return
  fi
  say "devnet: fresh state; deploying contract v3 and opening the proven tier (about a minute; log $PLAY/deploy.log)"
  # The prover service's jobs belong to the chain they ran on: a fresh devnet has the same seed, hence the
  # same contract address and job ids, so a job left by an earlier chain (a restored `target/`, a lost
  # dump) would be answered as done (H4: CI run 36740770202).
  # A prover still running for the old chain could write its job back into the cleared store: stop the
  # services first (`up` starts them again, after the deployment), then clear, then a new instance.
  stop client
  stop prove
  stop attest
  rm -rf "$PLAY/prove"
  new_instance
  rm -f "$CONFIG" "$PLAY/devnet-split.json" "$PLAY/accounts.txt"
  devnet_env "$ROOT/deploy/devnet.sh" deploy >"$PLAY/deploy.log" 2>&1 || { tail -n 20 "$PLAY/deploy.log" >&2; die "deploy failed"; }
  devnet_env "$ROOT/deploy/devnet.sh" proven >>"$PLAY/deploy.log" 2>&1 || { tail -n 20 "$PLAY/deploy.log" >&2; die "opening the proven tier failed"; }
}

# start NAME CONTRACT LOG CMD...: in the background, detached from this shell; PID + contract recorded.
start() {
  local name="$1" contract="$2" log="$3"
  shift 3
  nohup "$@" >"$log" 2>&1 </dev/null &
  printf '%s\n%s\n%s\n' "$!" "$contract" "$(instance)" >"$(pid_file "$name")"
}

# A service is reused when it runs for this contract; restarted when the devnet was redeployed.
fresh() {
  local name="$1" port="$2" contract="$3"
  if running "$name" "$(marker "$name")"; then
    if [ "$(started_for "$name")" = "$contract" ] && [ "$(started_on "$name")" = "$(instance)" ]; then
      say "$name: reused on :$port"
      return 1
    fi
    stop "$name"
  fi
  port_free "$port" || die "port $port ($name) is taken by another process: stop it or set its PLAY_*_PORT"
  return 0
}

up() {
  local t0=$SECONDS contract
  mkdir -p "$PLAY"
  preflight
  build
  up_devnet
  contract="$(json_get "$CONFIG" 'd["address"]')"
  [ -f "$PLAY/accounts.txt" ] || accounts >"$PLAY/accounts.txt"

  if fresh attest "$ATTEST_PORT" "$contract"; then
    start attest "$contract" "$PLAY/attest.log" env SLINGFALL_ATTEST_KEY="$ATTEST_KEY" \
      python3 "$ROOT/services/attest/attest.py" serve --execute --no-build --rate 0 \
      --contract "$contract" --rpc "$RPC" --host 127.0.0.1 --port "$ATTEST_PORT"
  fi
  if fresh prove "$PROVE_PORT" "$contract"; then
    start prove "$contract" "$PLAY/prove.log" env SLINGFALL_ADDRESS="$contract" \
      STARKNET_RPC_URL="$RPC" STARKNET_RPC="$RPC" \
      STARKNET_ACCOUNT_ADDRESS="$(account 2 2)" STARKNET_PRIVATE_KEY="$(account 2 3)" \
      RELAY_ACCOUNT_ADDRESS="$(account 3 2)" RELAY_PRIVATE_KEY="$(account 3 3)" \
      python3 "$ROOT/scripts/play/prove_local.py" --config "$CONFIG" --host 127.0.0.1 --port "$PROVE_PORT" \
      --store "$PLAY/prove/$contract"
  fi
  if fresh client "$PORT" "$contract"; then
    # Vite reads VITE_* at start; every one the page uses is given (a client/.env* file cannot win).
    start client "$contract" "$PLAY/client.log" env \
      PLAY_DEVNET_PORT="$DEVNET_PORT" PLAY_ATTEST_PORT="$ATTEST_PORT" PLAY_PROVE_PORT="$PROVE_PORT" \
      VITE_PLAY_LOCAL=1 VITE_NETWORK=devnet VITE_SLINGFALL_ADDRESS="$contract" VITE_DEPLOY_BLOCK=0 \
      VITE_STARKNET_RPC_URL=/rpc VITE_RPC_URL=/rpc VITE_ATTEST_URL=/attest-service VITE_PROVE_URL=/prove-service \
      VITE_DEVNET_ACCOUNT_ADDRESS="$(account 1 2)" VITE_DEVNET_PRIVATE_KEY="$(account 1 3)" \
      node "$ROOT/client/node_modules/vite/bin/vite.js" "$ROOT/client" --config "$ROOT/scripts/play/vite.config.mts" \
      --host "$HOST" --port "$PORT" --strictPort
  fi
  wait_http attest "http://127.0.0.1:$ATTEST_PORT/health" "$PLAY/attest.log"
  wait_http prove "http://127.0.0.1:$PROVE_PORT/health" "$PLAY/prove.log"
  wait_http client "http://127.0.0.1:$PORT/" "$PLAY/client.log"
  # The page's own routes, through the dev server's proxy.
  http_ok "http://127.0.0.1:$PORT/prove-service/health" || die "the dev server does not proxy the prover service (log $PLAY/client.log)"
  say "up in $((SECONDS - t0)) s: contract $contract, player $(account 1 2)"
  echo
  echo "  Open http://127.0.0.1:$PORT/   (local devnet: proofs are simulated)"
  if [ "$HOST" != 127.0.0.1 ] && [ "$HOST" != localhost ]; then
    echo "  From another device of this network: http://$(lan_ip):$PORT/"
    echo "  WARNING: the devnet and both services are reachable through it by anyone on this network;"
    echo "           never do this on a network exposed to the internet (docs/play-local.md)."
  fi
  echo "  Stop: scripts/play.sh down    Status: scripts/play.sh status    Logs: target/play/*.log"
}

lan_ip() {
  python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("192.0.2.1", 9)); print(s.getsockname()[0])' 2>/dev/null || echo "<this machine's address>"
}

# The minimum `up` needs; `doctor` says more.
preflight() {
  local tool want
  # Any Node of the pinned major: the shell's, else asdf's (scripts/play/node24.sh).
  want="$(awk '$1 == "nodejs" { print $2 }' "$ROOT/.tool-versions")"
  # shellcheck source=play/node24.sh
  . "$ROOT/scripts/play/node24.sh"
  use_asdf_node_major "${want%%.*}"
  [ -n "$NODE_NOTE" ] && say "$NODE_NOTE"
  for tool in node npm scarb python3 curl; do
    command -v "$tool" >/dev/null || die "$tool is missing: scripts/play.sh doctor"
  done
}

# ------------------------------------------------------------------ down, reset, status

# down [nosave]: `nosave` stops the devnet without saving its state (reset).
down() {
  stop client
  stop prove
  stop attest
  if running devnet starknet-devnet; then
    [ "${1:-}" = nosave ] || mark_chain_clean
    if [ "${1:-}" = nosave ]; then
      devnet_env DEVNET_DUMP= "$ROOT/deploy/devnet.sh" down
    else
      devnet_env "$ROOT/deploy/devnet.sh" down
      [ -f "$DUMP" ] && say "devnet state saved to $DUMP (scripts/play.sh reset forgets it)"
    fi
  fi
  rm -f "$PLAY/devnet-${DEVNET_PORT}.pid"
}

reset() {
  down nosave
  rm -rf "$DUMP" "$CONFIG" "$PLAY/devnet-split.json" "$PLAY/devnet.env" "$PLAY/accounts.txt" "$PLAY/prove" "$PLAY/devnet.instance"
  say "devnet state forgotten: the next scripts/play.sh up deploys afresh"
}

status() {
  local name port url any=0
  for name in devnet attest prove client; do
    case "$name" in
      devnet) port="$DEVNET_PORT" url="$RPC" ;;
      attest) port="$ATTEST_PORT" url="http://127.0.0.1:$ATTEST_PORT/health" ;;
      prove) port="$PROVE_PORT" url="http://127.0.0.1:$PROVE_PORT/health" ;;
      client) port="$PORT" url="http://$HOST:$PORT/" ;;
    esac
    if running "$name" "$(marker "$name")"; then
      any=1
      local file
      file="$(pid_file "$name")"
      [ "$name" = devnet ] && file="$PLAY/devnet-${DEVNET_PORT}.pid"
      printf '  %-7s running  pid %-7s :%-5s %s\n' "$name" "$(head -n1 "$file")" "$port" "$url"
    else
      printf '  %-7s stopped%s\n' "$name" "$(port_free "$port" && echo "" || echo "  (port $port taken by another process)")"
    fi
  done
  if [ -f "$CONFIG" ]; then
    echo "  contract $(json_get "$CONFIG" 'd["address"]') (v$(json_get "$CONFIG" 'd["contract_version"]')), state $([ -f "$DUMP" ] && echo "saved in $DUMP" || echo "not saved yet")"
  fi
  if http_ok "http://127.0.0.1:$PROVE_PORT/health"; then
    curl -fsS --max-time 5 "http://127.0.0.1:$PROVE_PORT/health" | python3 -c '
import json, sys
h = json.load(sys.stdin)
available, relay = (h.get("proven") or {}).get("available"), h.get("relay")
print(f"  tiers: provisional (attest), proven (SNIP-36 fake prover, available {available}), settled (FakeSatellite, relay {relay})")'
  fi
  [ "$any" = 1 ] && [ -f "$PLAY/accounts.txt" ] && echo "  player (devnet account #1) $(account 1 2); page http://$HOST:$PORT/"
  return 0
}

# PLAY_SOURCED=1: only the functions (scripts/play/test_play_instance.sh).
[ "${PLAY_SOURCED:-}" = 1 ] && return 0

case "${1:-up}" in
  up)
    scrub_env
    up
    ;;
  down) down ;;
  status) status ;;
  doctor) exec "$ROOT/scripts/play/doctor.sh" ;;
  reset) reset ;;
  -h | --help | help) sed -n '2,33p' "$0" ;;
  *)
    sed -n '2,33p' "$0" >&2
    exit 2
    ;;
esac
