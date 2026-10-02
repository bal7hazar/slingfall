#!/usr/bin/env bash
# Once per clone: git runs the hooks of .githooks/ (the pre-push check, scripts/prepush.sh).
# `core.hooksPath` is relative, so every worktree of the clone uses its own checkout's hooks.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
echo "core.hooksPath = .githooks"
