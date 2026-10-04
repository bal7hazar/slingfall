#!/usr/bin/env bash
# PH: recompute `c1main`'s program hash and compare it with the pins (docs/proving.md "Reproduce", trimmed to
# the hash). CI's `program-hash` job runs both subcommands.
#
#   tools/atlantic/program-hash.sh fork    # build cairo1-run (the fork's binary is copied to out/cairo1-run)
#   tools/atlantic/program-hash.sh check   # build c1main, run one_block, hash the PIE, compare with the pins
#   tools/atlantic/program-hash.sh key     # the cache key of the fork's binary: FORK_REV, RUST_TOOLCHAIN, the patch's sha256
#
# `check` exits 1 when the computed hash differs from `CHILD_PROGRAM_HASH` (deploy/slingfall.ts) or
# `program.current` (deploy/sepolia.json), or when no fixtures/proofs/atlantic/child-hash-*.json records it
# (exactly one must). A pin that is missing or not `0x` + 1..64 lower-case hex digits is a failure.
# The program hash is CASM-side: it does not depend on the build root (docs/proving.md).
set -euo pipefail

FORK_REV=da8e48c62ab1383f6d7a410e5d2151033e40b544
FORK_REPO=https://github.com/HerodotusDev/starkware-cairo-vm
RUST_TOOLCHAIN=1.94.0
PATCH=cairo-vm-cairo-lang-2.20.0.patch

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/out"
FORK="$OUT/starkware-cairo-vm"
BIN="$OUT/cairo1-run"

# The only place that names the revision, the toolchain and the patch: CI keys its cache on this line.
key() {
  echo "cairo1-run-${FORK_REV:0:7}-rust${RUST_TOOLCHAIN}-$(sha256sum "$HERE/$PATCH" | cut -c1-16)"
}

fork() {
  if [ -x "$BIN" ]; then
    echo "cairo1-run: cached ($BIN)"
    return
  fi
  mkdir -p "$OUT"
  rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
  git clone --quiet "$FORK_REPO" "$FORK"
  git -C "$FORK" checkout --quiet "$FORK_REV"
  git -C "$FORK" apply "$HERE/$PATCH"
  # Built on the toolchain of the cache key, not on whatever `stable` is.
  cargo "+$RUST_TOOLCHAIN" build --manifest-path "$FORK/Cargo.toml" -p cairo1-run --release
  cp "$FORK/target/release/cairo1-run" "$BIN"
}

check() {
  [ -x "$BIN" ] || { echo "::error::$BIN is missing: run '$0 fork' first"; exit 1; }
  cd "$ROOT"
  local work
  work="$(mktemp -d)"

  scarb --manifest-path tools/atlantic/c1main/Scarb.toml build
  python3 tools/tracec/tracec.py args fixtures/levels/one_block.felts.json --shot=-150,-150 --out "$work/args.json"
  python3 tools/atlantic/atlantic.py c1-input --args "$work/args.json" --out "$work/input.txt"
  "$BIN" tools/atlantic/c1main/target/dev/c1main.sierra.json --layout all_cairo --append_return_values \
    --cairo_pie_output "$work/pie.zip" --args_file "$work/input.txt" --print_output
  python3 tools/atlantic/atlantic.py program-hash --pie "$work/pie.zip" --json > "$work/hash.json"
  cat "$work/hash.json"

  python3 - "$work/hash.json" <<'PY'
import glob
import json
import re
import sys

PIN = re.compile(r"^0x[0-9a-f]{1,64}$")
computed = json.load(open(sys.argv[1]))["program_hash_pedersen"]
if not PIN.match(computed):
    sys.exit(f"::error::the computed program hash {computed!r} is not 0x + 1..64 lower-case hex digits")

errors = []


def pin(name, value):
    if not isinstance(value, str) or not PIN.match(value):
        errors.append(f"{name}: missing or not 0x + 1..64 lower-case hex digits ({value!r})")
        return None
    return value


pins = {}
matches = re.findall(r"^const CHILD_PROGRAM_HASH = '([^']*)';", open("deploy/slingfall.ts").read(), re.M)
if len(matches) != 1:
    errors.append(f"deploy/slingfall.ts: expected exactly one CHILD_PROGRAM_HASH constant, found {len(matches)}")
else:
    pins["CHILD_PROGRAM_HASH (deploy/slingfall.ts)"] = pin("CHILD_PROGRAM_HASH", matches[0])
try:
    current = json.load(open("deploy/sepolia.json"))["program"]["current"]
except (KeyError, TypeError) as exc:
    current = None
    errors.append(f"deploy/sepolia.json: program.current is missing ({exc!r})")
if current is not None:
    pins["program.current (deploy/sepolia.json)"] = pin("program.current", current)

records = []
for path in sorted(glob.glob("fixtures/proofs/atlantic/child-hash-*.json")):
    value = json.load(open(path)).get("child_program_hash")
    if pin(path, value) == computed:
        records.append(path)

print(f"computed program hash: {computed}")
for name, value in pins.items():
    if value is not None and value != computed:
        errors.append(f"{name} = {value}, computed {computed}")
if len(records) != 1:
    errors.append(
        f"fixtures/proofs/atlantic/child-hash-*.json: exactly one must record {computed}, found {len(records)}"
        + (f" ({', '.join(records)})" if records else "")
    )
else:
    print(f"record: {records[0]}")

if errors:
    for line in errors:
        print(f"::error::{line}")
    print(
        "::error::the c1main program moved: this PR must carry the Sepolia re-pin plan (OPERATIONS.md §7): "
        "its brief names the pin_program transaction"
    )
    sys.exit(1)
print("program hash matches every pin")
PY
}

case "${1:-}" in
  fork) fork ;;
  check) check ;;
  key) key ;;
  *) echo "usage: $0 fork|check|key" >&2; exit 2 ;;
esac
