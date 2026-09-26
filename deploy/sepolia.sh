#!/usr/bin/env bash
# Deploys Slingfall on Starknet Sepolia, as deploy/devnet.sh does on the devnet (docs/e2e.md).
# Not run by the lots: it spends the owner's funds and needs the owner's keys, from the environment:
#
#   STARKNET_RPC                 a Sepolia RPC 0.10 endpoint
#   SLINGFALL_ACCOUNT_ADDRESS    the admin account (deployed, funded with STRK)
#   SLINGFALL_PRIVATE_KEY        its key (never on a command line, never committed)
#   SLINGFALL_ATTESTATION_KEY    the PUBLIC key of the attestation service (attest.py pubkey on the
#                                service's machine); the secret never leaves that machine
#
# Writes deploy/sepolia.json (addresses, class hash, level hashes, gas) and deploy/sepolia.env
# (the client's VITE_* variables, without any key).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${STARKNET_RPC:?set STARKNET_RPC to a Sepolia RPC URL}"
: "${SLINGFALL_ACCOUNT_ADDRESS:?set SLINGFALL_ACCOUNT_ADDRESS}"
: "${SLINGFALL_PRIVATE_KEY:?set SLINGFALL_PRIVATE_KEY}"
: "${SLINGFALL_ATTESTATION_KEY:?set SLINGFALL_ATTESTATION_KEY (public key)}"
export STARKNET_RPC SLINGFALL_ACCOUNT_ADDRESS SLINGFALL_PRIVATE_KEY
OUT="$ROOT/deploy/sepolia.json"

[ -d "$ROOT/client/node_modules/starknet" ] || npm --prefix "$ROOT/client" ci --no-audit --no-fund
scarb --manifest-path "$ROOT/deploy/contract/Scarb.toml" build
node "$ROOT/deploy/slingfall.ts" deploy --network sepolia --rpc "$STARKNET_RPC" \
  --attestation-key "$SLINGFALL_ATTESTATION_KEY" --out "$OUT"
python3 - "$OUT" >"$ROOT/deploy/sepolia.env" <<'EOF'
import json, sys
config = json.load(open(sys.argv[1]))
print(f"VITE_SLINGFALL_ADDRESS={config['address']}")
print(f"VITE_RPC_URL={config['rpc_url']}")
print("VITE_ATTEST_URL=https://attest.example.invalid  # the public attestation service")
EOF
echo "sepolia: wrote $OUT and deploy/sepolia.env" >&2
