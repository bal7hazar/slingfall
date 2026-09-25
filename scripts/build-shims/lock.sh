#!/usr/bin/env bash
# Build locks shared by the orchestrators of this machine (31 GB, no swap), as in rapier-cairo:
#   * one PROJECT lock per repository: at most one Cairo build/test of slingfall at a time
#     (`~/orchestrator/locks/slingfall.lock`);
#   * the machine-wide HEAVY lock (`~/orchestrator/heavy-build.lock`, shared with rapier-cairo,
#     glam-cairo and nalgebra-cairo) for workspace-wide test runs and `scarb prove` / `verify`.
# A crate-scoped build or test (`snforge test -p <crate>`, `scarb build/lint`, `snforge test` inside
# the nested `crates/slingfall_replay` package) only takes the project lock. Lock order is always
# project -> heavy (no cycle: the other projects only take the heavy lock). Nested calls
# (snforge -> scarb) inherit the locks.
#
#   lock.sh <real-binary> <args...>
set -u
real="$1"; shift
root="$(cd "$(dirname "$0")/../.." && pwd)"
project_lock="${SLINGFALL_PROJECT_LOCK:-$HOME/orchestrator/locks/slingfall.lock}"
heavy_lock="${HEAVY_BUILD_LOCK:-$HOME/orchestrator/heavy-build.lock}"
mkdir -p "$(dirname "$project_lock")"
[ -n "${SLINGFALL_BUILD_LOCK_HELD:-}" ] && exec "$real" "$@"
heavy=0
case "$(basename "$real")" in
  snforge)
    [ "${1:-}" = test ] || exec "$real" "$@"
    # Without `-p`, a run from the root is workspace-wide; a run inside the nested replay package
    # covers that package only.
    [ "$PWD" = "$root" ] && heavy=1
    for a in "$@"; do case "$a" in -p|--package|--package=*|-p*) heavy=0 ;; esac; done
    for a in "$@"; do [ "$a" = --workspace ] && heavy=1; done ;;
  scarb)
    # The subcommand may follow global options (`scarb --manifest-path <file> build`).
    sub=""; skip=0
    for a in "$@"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      case "$a" in
        --manifest-path|-P|--profile|--target-dir|--global-cache-dir|--global-config-dir) skip=1 ;;
        -*) ;;
        *) sub="$a"; break ;;
      esac
    done
    case "$sub" in
      build|lint|check|test|execute) ;;
      prove|verify) heavy=1 ;;
      *) exec "$real" "$@" ;;
    esac
    for a in "$@"; do [ "$a" = --workspace ] && [ "$sub" = test ] && heavy=1; done ;;
  *) exec "$real" "$@" ;;
esac
# Same CPU policy as the machine-wide shim in ~/.local/bin (8 vCPU: a sustained 100 % makes the
# hypervisor throttle the VM): capped build parallelism, lowered priority.
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-4}" CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
export SLINGFALL_BUILD_LOCK_HELD=1 HEAVY_BUILD_LOCK_HELD=1
if [ "$heavy" = 1 ]; then
  exec nice -n 10 flock "$project_lock" flock "$heavy_lock" "$real" "$@"
fi
exec nice -n 10 flock "$project_lock" "$real" "$@"
