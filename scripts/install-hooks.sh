#!/usr/bin/env bash
# Once per MAIN clone, by that clone's owner: git then runs the hooks of .githooks/ (the pre-push check,
# scripts/prepush.sh). `core.hooksPath` is relative, so every worktree of the clone uses its own
# checkout's hooks.
# It refuses to run in a linked worktree (a thread's): git config is shared by every worktree of the
# clone, so a worktree must never write it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [ "$(git rev-parse --path-format=absolute --git-dir)" != "$(git rev-parse --path-format=absolute --git-common-dir)" ]; then
  echo "install-hooks: this is a linked worktree. Run it only on a main clone, by that clone's owner:" >&2
  echo "git config is shared by every worktree of the clone, so nothing was changed." >&2
  exit 1
fi
git config core.hooksPath .githooks
echo "core.hooksPath = .githooks"
