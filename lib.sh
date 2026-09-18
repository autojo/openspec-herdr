#!/usr/bin/env bash
# Shared helpers for the OpenSpec Picker plugin.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN="${HERDR_BIN_PATH:-herdr}"
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr/plugins/config/openspec.picker}"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-$CONFIG_DIR/state}"
WATCH_FILE="${WATCH_FILE:-$CONFIG_DIR/watch.txt}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/plugin.log}"
RUNNERS_FILE="${RUNNERS_FILE:-$CONFIG_DIR/runners.toml}"
LOCK_FILE="${LOCK_FILE:-$STATE_DIR/observer.lock}"
PID_FILE="${PID_FILE:-$STATE_DIR/observer.pid}"

# "observer running"/"observer not running" based on the observer's flock,
# or on its pid file where flock is missing (macOS).
observer_status() {
  local running=1 pid
  if command -v flock >/dev/null 2>&1; then
    [ -f "$LOCK_FILE" ] && ! flock -n "$LOCK_FILE" -c true 2>/dev/null && running=0
  elif [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && running=0
  fi
  if [ "$running" -eq 0 ]; then
    printf 'observer running'
  else
    printf 'observer not running'
  fi
}

# shellcheck source=runners.sh
. "$LIB_DIR/runners.sh"

log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '[%s] %s\n' "$(date -Is)" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# Pure-bash trim of surrounding whitespace.
trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# Print absolute repository roots (each must contain openspec/changes),
# one per line: the union of the working directories of all open panes
# (searched upwards for openspec/changes) and the watch file entries.
# Deduplicated, sorted.
read_watch_roots() {
  local line root
  {
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      while [ -n "$line" ] && [ "$line" != "/" ]; do
        if [ -d "$line/openspec/changes" ]; then
          printf '%s\n' "$line"
          break
        fi
        line="$(dirname "$line")"
      done
    done < <("$BIN" pane list 2>/dev/null | jq -r '.result.panes[]?.cwd // empty' 2>/dev/null)

    if [ -f "$WATCH_FILE" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        root="$(trim "$line")"
        [ -z "$root" ] && continue
        case "$root" in
          "~")      root="$HOME" ;;
          "~"/*)    root="$HOME${root#\~}" ;;
        esac
        if [ -d "$root/openspec/changes" ]; then
          printf '%s\n' "$root"
        fi
      done < "$WATCH_FILE"
    fi
  } | sort -u
}

# Creates watch.txt on first start: comment only, no paths. Never
# overwrites an existing file.
ensure_watch_file() {
  mkdir -p "$(dirname "$WATCH_FILE")"
  [ -f "$WATCH_FILE" ] && return 0
  cat > "$WATCH_FILE" <<'EOF'
# Optional extra repositories to watch, one absolute path per line.
# Repositories of open Herdr panes are watched automatically; add paths here
# only for repositories without an open pane. Lines starting with # are
# ignored.
EOF
  return 0
}

# Resolve the workspace where this repo is opened.
# Preference: workspace label == repo directory name, then a pane whose cwd
# equals the repo root exactly. Prints the workspace id, or nothing.
find_workspace_for_repo() {
  local repo_root="$1"
  local base_lower wid cand ws_json
  ws_json="$("$BIN" workspace list 2>/dev/null || true)"
  base_lower="$(printf '%s' "${repo_root##*/}" | tr '[:upper:]' '[:lower:]')"

  # 1) Workspace labelled with the repo directory name (case-insensitive).
  wid="$(printf '%s\n' "$ws_json" \
    | jq -r --arg b "$base_lower" \
      '[.result.workspaces[]? | select((.label // "" | ascii_downcase) == $b) | .workspace_id] | .[0] // empty' 2>/dev/null)"
  [ -n "$wid" ] && { printf '%s\n' "$wid"; return 0; }

  # 2) Workspace containing a pane whose cwd equals the repo root exactly.
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if "$BIN" pane list --workspace "$cand" 2>/dev/null \
      | jq -e --arg r "$repo_root" \
        '[.result.panes[]? | (.cwd // .foreground_cwd // "") == $r] | any' \
      >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done < <(printf '%s\n' "$ws_json" | jq -r '.result.workspaces[]?.workspace_id // empty' 2>/dev/null)
  return 1
}

notify() {
  local title="$1" body="$2"
  "$BIN" notification show "$title" --body "$body" >/dev/null 2>&1 || true
}

# Wait until the agent's TUI has rendered (its terminal title carries the
# agent name), so a submitted prompt is not dropped by the splash screen.
# Returns 0 when ready, 1 after ~30s.
wait_agent_ui() {
  local pane="$1" kind="$2" title lower waited=0
  while :; do
    title="$("$BIN" pane get "$pane" 2>/dev/null | jq -r '.result.pane.terminal_title // empty' 2>/dev/null || true)"
    lower="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"
    case "$kind" in
      opencode)
        case "$lower" in
          *opencode*|*"oc |"*) return 0 ;;
        esac
        ;;
      claude)
        case "$lower" in
          *claude*) return 0 ;;
        esac
        ;;
      *)
        return 0
        ;;
    esac
    waited=$((waited + 1))
    [ "$waited" -ge 30 ] && return 1
    sleep 1
  done
}

# Send the apply prompt and verify it landed: --wait with working/blocked
# detects a dropped prompt (splash screen) as agent_prompt_stalled, so we
# retry a few times. Returns 0 once the agent started processing.
send_apply_prompt() {
  local agent_name="$1" prompt="$2" resp attempt
  for attempt in 1 2 3; do
    resp="$("$BIN" agent prompt "$agent_name" "$prompt" \
      --wait --until working --until blocked --timeout 8000 2>&1)" || true
    if printf '%s\n' "$resp" | jq -e '.result' >/dev/null 2>&1; then
      return 0
    fi
    log "apply: prompt attempt $attempt stalled: $resp"
    sleep 2
  done
  return 1
}

# Validates the default runner from runners.toml. On a missing or invalid
# configuration, shows a notification and returns 1 without starting anything.
default_runner_or_fail() {
  local def kind
  def="$(runner_default)"
  if [ -z "$def" ] || ! kind="$(runner_field "$def" kind)"; then
    notify "OpenSpec: runner configuration" \
      "Add a runner to runners.toml ($RUNNERS_FILE) before starting an apply."
    return 1
  fi
  printf '%s\n' "$def"
}

# Start an apply session for a change in a fresh tab.
#   start_apply <repo_root> <change> <runner>
# Returns 0 on success (apply started or existing tab focused), 1 on failure
# (a notification has been shown; the created tab remains open).
start_apply() {
  local repo_root="$1" change="$2" runner="$3"
  local kind apply ws resp pane tab agent_name args existing
  local prompt

  kind="$(runner_field "$runner" kind 2>/dev/null)" || {
    notify "OpenSpec: runner configuration" "Runner '$runner' is missing or has no kind."
    return 1
  }
  apply="$(runner_field "$runner" apply 2>/dev/null)" || {
    notify "OpenSpec: runner configuration" "Runner '$runner' has no apply command."
    return 1
  }

  # Double-apply protection: focus the existing apply pane instead.
  existing="$("$BIN" pane list 2>/dev/null \
    | jq -r --arg c "$change" \
      '[.result.panes[]? | select((.tokens.os_change // "") == $c and (.tokens.os_phase // "") == "apply") | .tab_id] | .[0] // empty' 2>/dev/null)"
  if [ -n "$existing" ]; then
    log "apply: change $change already has an apply pane; focusing tab $existing"
    "$BIN" tab focus "$existing" >/dev/null 2>&1 || true
    return 0
  fi

  ws="$(find_workspace_for_repo "$repo_root")"
  if [ -z "$ws" ]; then
    notify "OpenSpec: workspace missing" "Open the workspace of $repo_root in Herdr, then try again."
    return 1
  fi

  resp="$("$BIN" tab create --workspace "$ws" --label "$change" --cwd "$repo_root" --focus 2>&1)"
  pane="$(printf '%s\n' "$resp" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)"
  tab="$(printf '%s\n' "$resp" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)"
  if [ -z "$pane" ]; then
    log "apply: tab create failed for $change: $resp"
    notify "OpenSpec: apply failed" "Could not create a tab for $change."
    return 1
  fi
  log "apply: tab $tab (pane $pane) created for $change (cwd=$repo_root)"

  agent_name="$(printf '%s' "$change" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"
  agent_name="$(printf '%.32s' "$agent_name")"

  args=()
  while IFS= read -r a || [ -n "$a" ]; do
    [ -n "$a" ] && args+=("$a")
  done < <(runner_field "$runner" args 2>/dev/null || true)

  start_cmd=("$BIN" agent start "$agent_name" --kind "$kind" --pane "$pane" \
    --timeout "${OSHERDR_AGENT_START_TIMEOUT_MS:-120000}")
  [ "${#args[@]}" -gt 0 ] && start_cmd+=(-- "${args[@]}")
  start_out="$(mktemp)"
  start_rc=1
  tries=0
  # The freshly created pane shell may not be ready yet; retry the transient
  # agent_pane_busy condition for a while before declaring failure.
  while [ "$tries" -lt 15 ]; do
    start_out="$(mktemp)"
    "${start_cmd[@]}" >"$start_out" 2>&1 && start_rc=0 && break
    if grep -q 'agent_pane_busy' "$start_out" 2>/dev/null; then
      tries=$((tries + 1))
      sleep 2
      continue
    fi
    break
  done
  if [ "$start_rc" -ne 0 ]; then
    log "apply: agent start failed for $change: $(cat "$start_out" 2>/dev/null)"
    notify "OpenSpec: agent not ready" "Agent $kind did not become ready in time. Tab stays open, no command sent."
    rm -f "$start_out"
    return 1
  fi
  if ! jq -e '.result' "$start_out" >/dev/null 2>&1; then
    log "apply: agent start returned no result for $change: $(cat "$start_out" 2>/dev/null)"
    notify "OpenSpec: agent not ready" "Agent $kind did not become ready in time. Tab stays open, no command sent."
    rm -f "$start_out"
    return 1
  fi
  rm -f "$start_out"

  prompt="${apply//\{change\}/$change}"
  if ! wait_agent_ui "$pane" "$kind"; then
    log "apply: agent UI never rendered for $change ($kind)"
    notify "OpenSpec: agent not ready" "Agent $kind did not become ready in time. Tab stays open, no command sent."
    return 1
  fi
  if ! send_apply_prompt "$agent_name" "$prompt"; then
    log "apply: prompt never landed for $change"
    notify "OpenSpec: apply failed" "The command could not be sent. Tab stays open."
    return 1
  fi
  log "apply: prompted $agent_name with '$prompt' for $change"

  # Track the change on the pane immediately, before the agent plugin reacts.
  "$BIN" pane report-metadata "$pane" --source openspec \
    --token "os_change=$change" --token "os_phase=apply" >/dev/null 2>&1 || true
  return 0
}
