#!/usr/bin/env bash
# Local devnet of Slingfall (lot G9, docs/e2e.md).
#
#   deploy/devnet.sh [all]     install starknet-devnet if needed, start it, deploy, open the proven tier (default)
#   deploy/devnet.sh up        install if needed and start the devnet (reused when already up)
#   deploy/devnet.sh deploy    build the class and deploy on the running devnet
#   deploy/devnet.sh proven    build layout (e)'s classes, deploy the SNIP-36 chain, pin it (contract v3)
#   deploy/devnet.sh down      stop the devnet this script started
#
# The devnet runs `--seed 0` with four prefunded accounts (deterministic): #0 is the admin, #1 and
# #3 play, #2 relays (`deploy/e2e.sh`), and `--proof-mode none`: it ignores a transaction's proof
# but still checks its SNIP-36 facts' header as the OS does (the fake prover of `services/prove`,
# docs/proving.md "SNIP-36"). `deploy` declares `Slingfall` (not `SlingfallSim`; v3, or with
# DEVNET_CONTRACT=v2 the v2 class of Sepolia's deployment, `deploy/v2.sh`), deploys it and
# configures it as a fresh deployment (`deploy/slingfall.ts deploy`): the attestation key,
# `pin_program(c1main, 0)`, a `FakeSatellite` (deploy/contract: true for the facts it is told) as
# the `SatelliteVerifier`'s Satellite, the verifier left `Stub`; registers the six fixture levels
# and writes:
#   deploy/devnet.json   network, RPC, class hash, address, admin, attestation key, level hashes, gas
#   deploy/devnet.env    VITE_* variables of the client (docs/e2e.md), with the devnet account
# `proven` (a v3 deployment) builds `slingfall_split` (`scarb build -p slingfall_split`) when needed,
# declares its classes and deploys `SplitChain` (`slingfall.ts deploy-split`, written to
# deploy/devnet-split.json), then `set_chunk_marker('SLINGFALL')`, `pin_virtual_os` of the devnet's
# virtual-OS program and `pin_chain(chain, bundle, 0)`.
#
# Environment:
#   DEVNET_PORT (5050)   DEVNET_VERSION (0.10.0: the fake prover's facts are this version's)
#   DEVNET_ATTEST_KEY    attestation secret of the devnet (default 'slingfall-devnet': a public
#                        test key, never a real one)
#   DEVNET_CONTRACT      v3 (default) or v2
#   DEVNET_OUT           deploy/devnet.json      DEVNET_ENV   deploy/devnet.env
#   DEVNET_SPLIT_OUT     deploy/devnet-split.json
#   DEVNET_RUN           deploy/out: the devnet's log and PID file
#   DEVNET_DUMP          a file: the devnet's state is dumped there when `down` stops it (SIGINT) and
#                        loaded from it at start (scripts/play.sh: a restart without a redeploy)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${DEVNET_PORT:-5050}"
RPC="http://127.0.0.1:${PORT}/rpc"
BIN_DIR="$ROOT/deploy/.devnet/bin"
RUN="${DEVNET_RUN:-$ROOT/deploy/out}"
PID_FILE="$RUN/devnet-${PORT}.pid"
OUT="${DEVNET_OUT:-$ROOT/deploy/devnet.json}"
ENV_OUT="${DEVNET_ENV:-$ROOT/deploy/devnet.env}"
SPLIT_OUT="${DEVNET_SPLIT_OUT:-$ROOT/deploy/devnet-split.json}"
ATTEST_KEY="${DEVNET_ATTEST_KEY:-0x736c696e6766616c6c2d6465766e6574}" # 'slingfall-devnet'
DEVNET_VERSION="${DEVNET_VERSION:-0.10.0}"
# An asdf shim picks this version (a machine with asdf's starknet-devnet and no .tool-versions pin).
export ASDF_STARKNET_DEVNET_VERSION="${ASDF_STARKNET_DEVNET_VERSION:-$DEVNET_VERSION}"
export PATH="$BIN_DIR:$HOME/.cargo/bin:$PATH"
mkdir -p "$RUN"

alive() {
  python3 - "$PORT" <<'EOF'
import sys, urllib.request
try:
    urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/is_alive", timeout=2)
except Exception:
    sys.exit(1)
EOF
}

install_devnet() {
  # A binary that does not run (an asdf shim with no version it accepts) does not count: install ours.
  if starknet-devnet --version >/dev/null 2>&1; then return; fi
  # The release binary (seconds) when the platform has one, else cargo (minutes, 2 jobs).
  local target=""
  case "$(uname -sm)" in
    "Linux x86_64") target=x86_64-unknown-linux-gnu ;;
    "Linux aarch64") target=aarch64-unknown-linux-gnu ;;
    "Darwin arm64") target=aarch64-apple-darwin ;;
    "Darwin x86_64") target=x86_64-apple-darwin ;;
  esac
  local url="https://github.com/0xSpaceShard/starknet-devnet/releases/download/v${DEVNET_VERSION}/starknet-devnet-${target}.tar.gz"
  mkdir -p "$BIN_DIR"
  if [ -n "$target" ] && curl -fsSL "$url" | tar -xz -C "$BIN_DIR"; then
    echo "devnet: installed $url" >&2
  else
    echo "devnet: no release binary; cargo install starknet-devnet $DEVNET_VERSION" >&2
    cargo install -j 2 --locked starknet-devnet --version "$DEVNET_VERSION"
  fi
  starknet-devnet --version >/dev/null 2>&1
}

up() {
  if alive; then
    echo "devnet: already up on $RPC" >&2
    return
  fi
  install_devnet
  echo "devnet: $(starknet-devnet --version) on $RPC (log $RUN/devnet-${PORT}.log)" >&2
  local dump=()
  if [ -n "${DEVNET_DUMP:-}" ]; then
    dump=(--dump-on exit --dump-path "$DEVNET_DUMP")
    [ -f "$DEVNET_DUMP" ] && echo "devnet: loading the state of $DEVNET_DUMP" >&2
  fi
  starknet-devnet --seed 0 --accounts 4 --proof-mode none --host 127.0.0.1 --port "$PORT" ${dump[@]+"${dump[@]}"} >"$RUN/devnet-${PORT}.log" 2>&1 &
  echo $! >"$PID_FILE"
  # Loading a dump replays its transactions (the declarations take seconds).
  for _ in $(seq 1 600); do
    if alive; then return; fi
    sleep 0.2
  done
  echo "devnet: did not start; see $RUN/devnet-${PORT}.log" >&2
  exit 1
}

down() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE")"
    if [ -n "${DEVNET_DUMP:-}" ]; then
      # The devnet dumps its state on SIGINT only (not SIGTERM); wait for the file.
      kill -INT "$pid" 2>/dev/null || true
      for _ in $(seq 1 150); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
    fi
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    rm -f "$PID_FILE"
    echo "devnet: stopped (port $PORT)" >&2
  fi
}

deploy() {
  [ -d "$ROOT/client/node_modules/starknet" ] || npm --prefix "$ROOT/client" ci --no-audit --no-fund
  scarb --manifest-path "$ROOT/deploy/contract/Scarb.toml" build
  local pubkey artifacts=()
  pubkey="$(python3 "$ROOT/services/attest/attest.py" pubkey --key "$ATTEST_KEY")"
  if [ "${DEVNET_CONTRACT:-v3}" = v2 ]; then
    artifacts=(--artifacts "$("$ROOT/deploy/v2.sh")")
  fi
  node "$ROOT/deploy/slingfall.ts" deploy --devnet --rpc "$RPC" --network devnet \
    --attestation-key "$pubkey" --fake-satellite --out "$OUT" ${artifacts[@]+"${artifacts[@]}"}
  # The client's configuration: the devnet account signs in the page (dev only).
  node "$ROOT/deploy/slingfall.ts" account --rpc "$RPC" --with-key >"$RUN/account-${PORT}.json"
  python3 - "$RUN/account-${PORT}.json" "$OUT" >"$ENV_OUT" <<'EOF'
import json, sys
account, config = (json.load(open(path)) for path in sys.argv[1:])
print(f"VITE_SLINGFALL_ADDRESS={config['address']}")
print(f"VITE_RPC_URL={config['rpc_url']}")
print("VITE_ATTEST_URL=http://127.0.0.1:8547")
print(f"VITE_DEVNET_ACCOUNT_ADDRESS={account['address']}")
print(f"VITE_DEVNET_PRIVATE_KEY={account['private_key']}")
EOF
  echo "devnet: wrote $OUT and $ENV_OUT" >&2
}

# The devnet's virtual-OS program (what starknet-devnet 0.10.0's prover names; services/prove/snip36.py).
DEVNET_VIRTUAL_OS=0x53f6c9fcfd31d27279ff7d7e422b44623550a732b59fe193354a7316a96daa1

proven() {
  [ -f "$ROOT/target/dev/slingfall_split_SplitChain.contract_class.json" ] || scarb build -p slingfall_split
  local cli=(node "$ROOT/deploy/slingfall.ts")
  "${cli[@]}" deploy-split --devnet --rpc "$RPC" --out "$SPLIT_OUT" >/dev/null
  "${cli[@]}" set-chunk-marker --devnet --rpc "$RPC" --config "$OUT" >/dev/null
  "${cli[@]}" pin-virtual-os --devnet --rpc "$RPC" --config "$OUT" --program "$DEVNET_VIRTUAL_OS" --grace 0 >/dev/null
  "${cli[@]}" pin-chain --devnet --rpc "$RPC" --config "$OUT" --split "$SPLIT_OUT" --grace 0 >"$RUN/pin-chain-${PORT}.json"
  echo "devnet: proven tier open, chain $(python3 -c "import json, sys; d = json.load(open(sys.argv[1])); print(d['chain'], 'bundle', d['bundle_hash'])" "$RUN/pin-chain-${PORT}.json") ($SPLIT_OUT)" >&2
}

case "${1:-all}" in
  up) up ;;
  deploy) deploy ;;
  proven) proven ;;
  down) down ;;
  all)
    up
    deploy
    if [ "${DEVNET_CONTRACT:-v3}" = v3 ]; then proven; fi
    ;;
  *) sed -n '2,35p' "$0" >&2; exit 2 ;;
esac
