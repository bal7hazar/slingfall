#!/usr/bin/env bash
# The local check every push runs (`.githooks/pre-push`); also by hand. Catches what CI would
# catch in seconds to minutes: format, syntax, the Python unit tests, the touched crates' build,
# the generated golden tests, the class-size gates. One line per check, the total last.
#
#   scripts/prepush.sh [--full] [--base REF]
#
#   --base REF  diff against `git merge-base HEAD REF` (default origin/main, the local ref, no fetch)
#   --full      adds the slow checks: the dependents of a touched crate and the replay, the Cairo-steps
#               snapshot, the split class-hash pins (advisory) and the replay executables
#
# Every Cairo build goes through the `scarb` / `snforge` shims of the machine (heavy-build lock): never
# bypassed. The wait for that lock is measured apart (sampled, or timed by the compile's own flock) and is not
# part of the time the default run aims at (under 2 minutes).
set -euo pipefail
export RAYON_NUM_THREADS=1   # Sierra is not deterministic across compiler threads (docs/proving.md)

full=0
base_ref=origin/main
while [ $# -gt 0 ]; do
  case "$1" in
    --full) full=1 ;;
    --base) base_ref="${2:?--base needs a ref}"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "usage: scripts/prepush.sh [--full] [--base REF]" >&2; exit 2 ;;
  esac
  shift
done

cd "$(git rev-parse --show-toplevel)"
REPLAY=crates/slingfall_replay/Scarb.toml
LOCK="${HEAVY_BUILD_LOCK:-$HOME/orchestrator/heavy-build.lock}"
base="$(git merge-base HEAD "$base_ref")" || { echo "prepush: no merge base with $base_ref (--base REF)" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Committed, staged, unstaged and untracked changes against the merge base (deleted files stay: a
# deleted trigger path is a change; the per-file checks below skip files that are gone).
{ git diff --name-only "$base"; git ls-files --others --exclude-standard; } | sort -u > "$tmp/changed"

changed() { grep -Eq "$1" "$tmp/changed"; }   # a changed path matches the ERE
existing() { grep -E "$1" "$tmp/changed" | while read -r f; do [ -f "$f" ] && echo "$f"; done || true; }

now() { echo "$EPOCHREALTIME"; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
t_start="$(now)"
lock_wait=0   # seconds
fails=0
skipped_full=()

# The wait for the heavy-build lock is measured by sampling: while a command runs, once a second, is one of
# itself (the shim execs into it) or its own descendants a `flock .../heavy-build.lock` (the shim's, still waiting; once it holds the lock flock
# becomes the real binary)? The command takes the lock through the shim, as always; the lock file is never
# opened here.
waiting_flock() {   # <pid>: prints the pid of the descendant flock that waits, if any
  ps -eo pid,ppid,args | awk -v root="$1" '
    { pp[$1] = $2; a[$1] = $0 }
    END { for (p in pp) { q = p; while (q in pp) { if (p == root || pp[q] == root) { if (a[p] ~ /flock .*heavy-build/) print p; break } q = pp[q] } } }' | head -n 1
}
# run_sampled <cmd...>: output to $tmp/out, status returned, the seconds spent waiting added to lock_wait
# (the unbounded --full steps; the compile steps use run_held).
run_sampled() {
  local pid w=0 rc=0
  "$@" > "$tmp/out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    [ -n "$(waiting_flock "$pid")" ] && w=$((w + 1))
    sleep 1
  done
  wait "$pid" || rc=$?
  lock_wait=$((lock_wait + w))
  return "$rc"
}

# run_held <cmd...>: the compile steps. The script takes the lock itself, `flock -w 90`, and runs the command
# under it with HEAVY_BUILD_LOCK_HELD=1 (set only inside the flock: the shims then pass through instead of
# waiting a second time on the lock held here, as do nested calls). Exit 242 = the lock was not obtained in
# 90 s and nothing ran (a build failure is any other non-zero status). Nothing is killed; the lock file is
# touched only through flock. Without the lock file (the Mac) or on Darwin: no flock, the command runs as is.
lock_busy=0
compile_left_to_ci=0
run_held() {
  local rc=0 stamp="$tmp/acquired" a b
  rm -f "$stamp"; a="$(now)"
  if [ "$compile_cap" -gt 0 ]; then
    flock -w "$compile_cap" -E 242 "$LOCK" bash -c 'date +%s.%N > "$1"; shift; export HEAVY_BUILD_LOCK_HELD=1; exec "$@"' _ "$stamp" "$@" \
      > "$tmp/out" 2>&1 || rc=$?
    if [ "$rc" = 242 ]; then
      lock_wait="$(awk -v w="$lock_wait" -v d="$compile_cap" 'BEGIN { printf "%.1f", w + d }')"; lock_busy=1; return 242
    fi
    [ -s "$stamp" ] && lock_wait="$(awk -v w="$lock_wait" -v a="$a" -v g="$(cat "$stamp")" 'BEGIN { printf "%.1f", w + g - a }')"
  else
    "$@" > "$tmp/out" 2>&1 || rc=$?
  fi
  return "$rc"
}

# The locked scarb calls (build) put the subcommand first: the VPS shim takes the lock only then. The compile
# steps hold the lock themselves for at most 90 s of waiting (run_held), then are left to CI.
compile_cap=90
if [ "$(uname -s)" = Darwin ] || [ ! -e "$LOCK" ]; then compile_cap=0; fi

line() { printf '%-5s %-44s %s\n' "$1" "$2" "${3:-}"; }

# run <name> <locked 0|1> <cmd...>: ok / FAIL, with the last lines of the output on a failure.
run() {
  local name="$1" locked="$2"; shift 2
  local a b rc=0; a="$(now)"
  if [ "$locked" = held ]; then run_held "$@" || rc=$?
  elif [ "$locked" = 1 ]; then run_sampled "$@" || rc=$?
  else "$@" > "$tmp/out" 2>&1 || rc=$?; fi
  b="$(now)"
  if [ "$rc" = 242 ] && [ "$lock_busy" = 1 ]; then
    [ "$compile_left_to_ci" = 1 ] || echo "heavy lock busy: Cairo compile left to CI"
    compile_left_to_ci=1
  elif [ "$rc" = 0 ]; then
    local note=""   # classsize skips the CASM figures without `starknet-sierra-compile` on PATH
    grep -qi 'CASM not checked' "$tmp/out" && note="(CASM not checked), "
    line ok "$name" "$note$(secs "$a" "$b") s"
  else
    line FAIL "$name" "exit $rc, $(secs "$a" "$b") s"
    tail -n 25 "$tmp/out" | sed 's/^/      | /'
    fails=$((fails + 1))
  fi
}
skip_unchanged() { line skip "$1" "(inputs unchanged)"; }
skip_full() { line skip "$1" "(use --full)"; skipped_full+=("$1"); }

# ---------------------------------------------------------------------------- always
run "fmt (workspace)" 0 scarb fmt --check --workspace
run "fmt (replay)" 0 scarb --manifest-path "$REPLAY" fmt --check   # fmt takes no --manifest-path after it; fmt is not locked

mapfile -t pys < <(existing '\.py$')
if [ "${#pys[@]}" -gt 0 ]; then run "py_compile (${#pys[@]} changed)" 0 python3 -m py_compile "${pys[@]}"
else skip_unchanged "py_compile"; fi
mapfile -t shs < <(existing '(\.sh$|^\.githooks/)')
if [ "${#shs[@]}" -gt 0 ]; then run "bash -n (${#shs[@]} changed)" 0 bash -n "${shs[@]}"
else skip_unchanged "bash -n"; fi

# ---------------------------------------------------------------------------- Python unit tests
pytest_dir() {   # <dir> <cmd...>
  local dir="$1"; shift
  if changed "^$dir/"; then run "tests $dir" 0 "$@"; else skip_unchanged "tests $dir"; fi
}
pytest_dir services/attest python3 -m unittest discover -s services/attest
pytest_dir tools/atlantic python3 -m unittest discover -s tools/atlantic -p 'test_*.py'
pytest_dir services/prove python3 -m unittest discover -s services/prove
# Its decoding tests only, as the CI `prove` job: PROVE_RUN would add the tamper tests.
pytest_dir tools/prove env -u PROVE_RUN python3 tools/prove/test_prove.py
pytest_dir tools/settle python3 -m unittest discover -s tools/settle
pytest_dir tools/levelc python3 -m unittest discover -s tools/levelc
pytest_dir scripts/play python3 -m unittest discover -s scripts/play

# ---------------------------------------------------------------------------- Cairo: what to build
# The crate graph is read from the manifests. `plan` prints shell assignments:
#   BUILD       workspace crates to build: the touched ones (--full: and their dependents)
#   REPLAY      1 when the replay is built: touched (--full: or one of its dependencies touched)
#   CAIRO       1 when a Cairo source or a manifest changed
#   CONTRACT_*  / SPLIT_*   TRIG: the crate or a dependency of its class changed; BUILT: it is in BUILD
#   MOVE        1 when the split class hashes may move
eval "$(python3 - "$full" "$tmp/changed" <<'PY'
import re, sys
from pathlib import Path

full = sys.argv[1] == "1"
changed = [l.strip() for l in Path(sys.argv[2]).read_text().splitlines() if l.strip()]
root = Path("Scarb.toml").read_text()
members = re.findall(r'"crates/(\w+)"', root.split("members", 1)[1].split("]", 1)[0])
REPLAY = "slingfall_replay"
nodes = members + [REPLAY]

def deps(crate):
    """-> (normal path dependencies, dev path dependencies) of a crate's manifest."""
    normal, dev, section = set(), set(), ""
    for line in Path(f"crates/{crate}/Scarb.toml").read_text().splitlines():
        s = line.strip()
        if s.startswith("["):
            section = s
        m = re.match(r'(slingfall_\w+)\s*=\s*\{\s*path', s)
        if m and section == "[dependencies]":
            normal.add(m.group(1))
        elif m and section == "[dev-dependencies]":
            dev.add(m.group(1))
    return normal, dev

graph = {c: deps(c) for c in nodes}

def closure(seed, normal_only=False):
    """Every crate that depends (transitively) on a crate of `seed`, and `seed` itself."""
    out = set(seed)
    grew = True
    while grew:
        grew = False
        for c, (n, d) in graph.items():
            if c not in out and ((n if normal_only else n | d) & out):
                out.add(c); grew = True
    return out

def needs(crate):
    """The crate and its normal dependencies, transitively: what its class is made of."""
    out, todo = set(), [crate]
    while todo:
        c = todo.pop()
        if c not in out:
            out.add(c); todo.extend(graph[c][0])
    return out

touched = {c for c in nodes if any(p.startswith(f"crates/{c}/") for p in changed)}
root_manifest = any(p in ("Scarb.toml", "Scarb.lock") for p in changed)
if root_manifest:
    touched |= set(members)
cairo = root_manifest or any(
    re.match(r"crates/\w+/(.*\.cairo|Scarb\.toml|Scarb\.lock)$", p) for p in changed)
scope = closure(touched) if full else touched
build = [c for c in members if c in scope]
replay = REPLAY in touched or (full and REPLAY in closure(touched))

def flag(name, crate):
    trig = bool(needs(crate) & touched) or root_manifest
    print(f"{name}_TRIG={int(trig)}; {name}_BUILT={int(crate in build)}")

print(f"BUILD='{' '.join(build)}'; REPLAY={int(replay)}; CAIRO={int(cairo)}")
flag("CONTRACT", "slingfall_contract")
flag("SPLIT", "slingfall_split")
print(f"MOVE={int(bool(needs('slingfall_split') & touched) or root_manifest)}")
PY
)"

# ---------------------------------------------------------------------------- compile
if [ "$CAIRO" = 1 ] && [ -n "$BUILD" ]; then
  pkgs=(); for c in $BUILD; do pkgs+=(-p "$c"); done
  run "build $BUILD" held scarb build "${pkgs[@]}"
elif [ "$CAIRO" = 1 ]; then
  skip_unchanged "build (workspace)"
else
  skip_unchanged "build"
fi
if [ "$REPLAY" = 1 ] && [ "$compile_left_to_ci" = 1 ]; then
  :   # the compile was left to CI above
elif [ "$REPLAY" = 1 ]; then
  run "build slingfall_replay" held scarb build --manifest-path "$REPLAY"
elif [ "$CAIRO" = 1 ]; then
  skip_full "build slingfall_replay"
else
  skip_unchanged "build slingfall_replay"
fi
if [ "$CAIRO" = 1 ] && [ "$full" = 0 ]; then
  # Dependents of the touched crates, which only --full builds.
  skipped_full+=("dependents")
fi

# ---------------------------------------------------------------------------- generated golden tests
if changed '^(fixtures/|tools/golden/|crates/slingfall_replay/tests/golden\.cairo$)'; then
  run "golden to-cairo --check" 0 python3 tools/golden/golden.py to-cairo --check
else
  skip_unchanged "golden to-cairo --check"
fi

# ---------------------------------------------------------------------------- class sizes (path-free)
size_check() {   # <name> <TRIG> <BUILT> <classsize subcommand>
  if [ "$2" != 1 ]; then skip_unchanged "$1"
  elif [ "$compile_left_to_ci" = 1 ]; then line skip "$1" "(compile left to CI)"
  elif [ "$3" != 1 ]; then skip_full "$1"
  else run "$1" 0 python3 tools/classsize/classsize.py "$4" --no-build
  fi
}
size_check "classsize check (registry)" "$CONTRACT_TRIG" "$CONTRACT_BUILT" check
size_check "classsize split" "$SPLIT_TRIG" "$SPLIT_BUILT" split

# ---------------------------------------------------------------------------- class-hash pins (advisory)
# A local build root is not CI's: a local class hash differing from the pin is not proof of a stale pin
# (OPERATIONS.md section 5). Re-pin from CI's output, never from here.
if [ "$MOVE" = 1 ]; then
  line warn "split class hashes may move" "re-pin from CI's output (OPERATIONS section 5), not locally"
fi

# ---------------------------------------------------------------------------- --full
if [ "$full" = 1 ]; then
  if [ "$compile_left_to_ci" = 1 ]; then
    line skip "steps check" "(compile left to CI)"
  elif [ "$CAIRO" = 1 ] || changed '^steps/'; then
    run "steps check" 1 python3 scripts/steps.py check
  else
    skip_unchanged "steps check"
  fi

  if [ "$MOVE" = 1 ] && [ "$compile_left_to_ci" = 1 ]; then
    line skip "pins (split)" "(compile left to CI)"
  elif [ "$MOVE" = 1 ]; then
    a="$(now)"; rc=0
    run_sampled python3 crates/slingfall_split/scripts/pin.py --check || rc=$?   # `stale:` lines go to stderr
    out="$(cat "$tmp/out")"   # stdout and stderr both
    b="$(now)"
    if [ "$rc" = 0 ]; then
      line ok "pins (split)" "$(secs "$a" "$b") s"
    elif grep -q '^stale:' <<< "$out"; then
      line warn "pins (split) stale locally" "$(secs "$a" "$b") s, advisory"
      while read -r _ const _ value; do
        pinned="$(tr -d '\n' < crates/slingfall_split/src/hashes.cairo \
          | grep -oE "pub const $const: felt252 *= *0x[0-9a-f]+" | grep -oE '0x[0-9a-f]+$' || echo '?')"
        printf '      %s pinned %s, local build %s (a path difference is expected: CI decides)\n' \
          "$const" "$pinned" "$value"
      done < <(grep '^stale:' <<< "$out")
    else
      line FAIL "pins (split)" "exit $rc without stale lines, $(secs "$a" "$b") s"
      tail -n 25 <<< "$out" | sed 's/^/      | /'
      fails=$((fails + 1))
    fi
  else
    skip_unchanged "pins (split)"
  fi

  if [ "$REPLAY" = 1 ] && [ "$compile_left_to_ci" = 1 ]; then
    line skip "replay executables" "(compile left to CI)"
  elif [ "$REPLAY" = 1 ]; then
    compare_executables() {
      local n rc=0
      for n in main_trace init step_chunk outputs; do
        cmp "crates/slingfall_replay/target/dev/$n.executable.json" "client/vm/fixtures/replay/$n.executable.json" || rc=1
      done
      [ "$rc" = 0 ] || echo "regenerate with client/vm/scripts/fetch-executables.sh --build (not run here: it overwrites tracked files)"
      return "$rc"
    }
    run "replay executables = client/vm/fixtures" 0 compare_executables
  else
    skip_unchanged "replay executables"
  fi
else
  if [ "$CAIRO" = 1 ]; then
    skip_full "steps check"
    [ "$MOVE" = 1 ] && skip_full "pins (split)"
    skip_full "replay executables"
  else
    skip_unchanged "--full checks"
  fi
fi

# ---------------------------------------------------------------------------- total
t_end="$(now)"
total="$(secs "$t_start" "$t_end")"
own="$(awk -v t="$total" -v w="$lock_wait" 'BEGIN { printf "%.1f", t - w }')"
echo
if [ "${#skipped_full[@]}" -gt 0 ] && [ "$full" = 0 ] && [ "$CAIRO" = 1 ]; then
  echo "Cairo changed, --full not run: skipped $(IFS=,; echo "${skipped_full[*]}")"
fi
echo "prepush: $total s total, of which $lock_wait s waiting for the heavy-build lock (sampled or flock-timed), $own s without"
if [ "$fails" -gt 0 ]; then echo "prepush: $fails FAILED" >&2; exit 1; fi
echo "prepush: ok"
