#!/usr/bin/env bash
# Run scripts/executor.sh inside a transient systemd *user* unit, so that the executor survives
# the orchestrator session (and the desktop service it lives in: an OOM kill of that service takes
# its whole cgroup down, `setsid`/`nohup` do not escape it). Same arguments as executor.sh:
#
#   scripts/executor-unit.sh <id> <runner> <brief.md>
#   scripts/executor-unit.sh resume <id> <runner> "<follow-up>"
#
# Unit name: slingfall-exec-<id>.  Follow:  journalctl --user -u slingfall-exec-<id> -f   (launcher
# output only; the agent log stays in ~/orchestrator/logs/slingfall/<id>.log)   Stop: systemctl --user stop …
# Requires lingering (`loginctl enable-linger`) for the unit to outlive every login session.
set -euo pipefail
[ $# -ge 3 ] || { sed -n '2,11p' "$0"; exit 64; }
ID="$1"; [ "$ID" = resume ] && ID="$2"
ROOT="$(git rev-parse --show-toplevel)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" XDG_RUNTIME_DIR="/run/user/$(id -u)"
UNIT="slingfall-exec-$ID"
systemctl --user reset-failed "$UNIT.service" 2>/dev/null || true
exec systemd-run --user --collect --quiet --unit "$UNIT" --working-directory "$ROOT" \
  --setenv=HOME="$HOME" \
  --setenv=PATH="$HOME/.local/bin:$HOME/.asdf/shims:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
  --setenv=EXECUTOR_LOG_DIR="${EXECUTOR_LOG_DIR:-$HOME/orchestrator/logs/slingfall}" \
  --setenv=EXECUTOR_BASE="${EXECUTOR_BASE:-origin/main}" \
  --setenv=EXECUTOR_MAX_TURNS="${EXECUTOR_MAX_TURNS:-300}" \
  --setenv=EXECUTOR_FRESH="${EXECUTOR_FRESH:-}" \
  "$ROOT/scripts/executor.sh" "$@"
