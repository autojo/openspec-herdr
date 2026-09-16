#!/usr/bin/env bash
# Startup hook: first-time config (runners.toml, watch.txt), dependency
# check, and a detached observer daemon that tracks OpenSpec signals in panes.

set -euo pipefail

ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=lib.sh
. "$ROOT/lib.sh"

LOCK_FILE="${LOCK_FILE:-$STATE_DIR/observer.lock}"
PID_FILE="${PID_FILE:-$STATE_DIR/observer.pid}"
OBSERVER_LOG="${OBSERVER_LOG:-$STATE_DIR/observer.log}"
DEPS_MARKER="${DEPS_MARKER:-$STATE_DIR/deps-notified}"

# One-time notification about missing runtime dependencies.
check_deps() {
  [ -f "$DEPS_MARKER" ] && return 0
  local missing="" d
  for d in jq fzf curl python3; do
    command -v "$d" >/dev/null 2>&1 || missing="${missing}${missing:+, }$d"
  done
  if [ -n "$missing" ]; then
    log "observer: missing dependencies: $missing"
    notify "OpenSpec Picker: missing dependencies" \
      "Missing: $missing. Tracking may be limited until installed."
    mkdir -p "$(dirname "$DEPS_MARKER")"
    touch "$DEPS_MARKER"
  fi
}

# Detached daemon start, guarded against double starts with flock: the lock
# is handed to the python process, so a second run exits immediately.
start_observer() {
  mkdir -p "$STATE_DIR"
  command -v python3 >/dev/null 2>&1 || return 0
  exec 9>"$LOCK_FILE"
  flock -n 9 || {
    log "observer: already running (lock held)"
    exec 9>&-
    return 0
  }
  nohup python3 "$ROOT/observer.py" >>"$OBSERVER_LOG" 2>&1 </dev/null 9<&9 &
  echo $! > "$PID_FILE"
  log "observer: spawned pid $!"
}

ensure_runners_file
ensure_watch_file
check_deps
start_observer

exit 0
