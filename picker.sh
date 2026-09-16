#!/usr/bin/env bash
# OpenSpec change picker: popup listing all active changes of the watched
# repos. Enter/click starts or focuses a session depending on the phase.
#
#   picker.sh          interactive selection (popup)
#   picker.sh --list   debug output of the list without fzf
#   picker.sh --select <change> <repo_root> <phase> <tab_id>
#                      internal selection handler (called from fzf --bind)

set -euo pipefail

ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=lib.sh
. "$ROOT/lib.sh"

SYM_EXPLORE="?"
SYM_APPLY=">"
SYM_APPLY_BLOCKED="!"
SYM_READY="P"
SYM_PLANNING="·"

# Closes the fzf popup when the fzf HTTP server port is known.
close_picker() {
  if [ -n "${FZF_PORT:-}" ]; then
    curl -sS -XPOST "localhost:$FZF_PORT" -d close >/dev/null 2>&1 || true
  fi
}

# Internal selection handler. phase == "header" is a repo separator (no
# action). For planning the popup stays open (the fzf header was already
# updated via change-header).
select_entry() {
  local change="$1" repo_root="$2" phase="$3" tab_id="$4"
  local runner

  case "$phase" in
    header)
      return 0
      ;;
    ready)
      runner="$(default_runner_or_fail)" || return 0
      if start_apply "$repo_root" "$change" "$runner"; then
        close_picker
      fi
      return 0
      ;;
    explore|apply|apply-blocked)
      if [ -n "$tab_id" ] && [ "$tab_id" != "-" ]; then
        "$BIN" tab focus "$tab_id" >/dev/null 2>&1 || true
      fi
      close_picker
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

# Prints the phase table: change<tab>phase<tab>hint<tab>tab_id<tab>pane_status
# One change per line; matching via pane tokens.
# Priority: explore > apply-blocked > apply > ready > planning.
build_rows() {
  local repo_root panes_json
  panes_json="$("$BIN" pane list 2>/dev/null | jq -c '[.result.panes[]? | select(.tokens.os_change != null) | {change: .tokens.os_change, phase: .tokens.os_phase, status: .agent_status, tab: .tab_id, cwd: .cwd}]' 2>/dev/null || echo '[]')"

  while IFS= read -r repo_root; do
    [ -n "$repo_root" ] || continue
    local name complete missing hint phase tab status
    while IFS= read -r row; do
      name="$(printf '%s' "$row" | jq -r '.changeName // empty' 2>/dev/null)"
      complete="$(printf '%s' "$row" | jq -r '.isPlanningComplete // false' 2>/dev/null)"
      [ -n "$name" ] || continue
      phase="" hint="" tab="-" status=""

      # Panes of this change (name + cwd under the repo root).
      local matches explore_match apply_matches apply_pane
      matches="$(printf '%s' "$panes_json" | jq -c --arg n "$name" --arg r "$repo_root" '[.[] | select(.change == $n and ((.cwd // "") | startswith($r))) ]' 2>/dev/null)"
      explore_match="$(printf '%s' "$matches" | jq -r '[.[] | select(.phase == "explore")][0] // empty' 2>/dev/null)"
      apply_matches="$(printf '%s' "$matches" | jq -c '[.[] | select(.phase == "apply")]' 2>/dev/null)"

      if [ -n "$explore_match" ]; then
        phase="explore"
        tab="$(printf '%s' "$explore_match" | jq -r '.tab // "-"' 2>/dev/null)"
        status="$(printf '%s' "$explore_match" | jq -r '.status // ""' 2>/dev/null)"
        hint="$status"
        [ "$tab" = "null" ] && tab="-"
      elif [ "$(printf '%s' "$apply_matches" | jq 'length' 2>/dev/null)" != "0" ]; then
        apply_pane="$(printf '%s' "$apply_matches" | jq -r '.[] | select(.status == "blocked") | .tab' 2>/dev/null | head -1)"
        if [ -n "$apply_pane" ]; then
          phase="apply-blocked"
          tab="$apply_pane"
          hint="blocked"
        else
          phase="apply"
          tab="$(printf '%s' "$apply_matches" | jq -r '.[0].tab // "-"' 2>/dev/null)"
          status="$(printf '%s' "$apply_matches" | jq -r '.[0].status // ""' 2>/dev/null)"
          hint="$status"
          [ "$tab" = "null" ] && tab="-"
        fi
      elif [ "$complete" = "true" ]; then
        phase="ready"
        tab="-"
        hint=""
      else
        phase="planning"
        tab="-"
        missing="$(printf '%s' "$row" | jq -r '[.artifactPaths | to_entries[] | select(.value.existingOutputPaths | length == 0) | .key] | join(", ")' 2>/dev/null)"
        hint="missing: ${missing:-artifacts}"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$repo_root" "$phase" "$hint" "$tab" "$status"
    done < <(cd "$repo_root" && openspec status --all --json 2>/dev/null | jq -c '.changes[]' 2>/dev/null)
  done < <(read_watch_roots)
}

# Prints the fzf selection lines.
# Format: sym<TAB>change<TAB>phase<TAB>hint<TAB>repo_root<TAB>tab_id
emit_lines() {
  local line last_repo="" name root phase hint tab sym
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    name="$(printf '%s\n' "$line" | cut -f1)"
    root="$(printf '%s\n' "$line" | cut -f2)"
    phase="$(printf '%s\n' "$line" | cut -f3)"
    hint="$(printf '%s\n' "$line" | cut -f4)"
    tab="$(printf '%s\n' "$line" | cut -f5)"
    [ -n "$name" ] || continue
    if [ "$root" != "$last_repo" ]; then
      printf '\033[2m%s\t\t%s\t\t%s\t%s\033[0m\n' "$(basename "$root")" "header" "$root" "-"
      last_repo="$root"
    fi
    case "$phase" in
      explore)        sym="$SYM_EXPLORE" ;;
      apply)          sym="$SYM_APPLY" ;;
      apply-blocked)  sym="$SYM_APPLY_BLOCKED" ;;
      ready)          sym="$SYM_READY" ;;
      planning)       sym="$SYM_PLANNING" ;;
      *)              sym=" " ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sym" "$name" "$phase" "$hint" "$root" "$tab"
  done < <(build_rows)
}

if [ "${1:-}" = "--select" ]; then
  select_entry "${2:-}" "${3:-}" "${4:-}" "${5:-}"
  exit 0
fi

ensure_runners_file

if [ "${1:-}" = "--list" ]; then
  emit_lines
  exit 0
fi

lines="$(emit_lines)"
if [ -z "$lines" ]; then
  lines="$(printf '\033[2mNo OpenSpec changes\t\t\t\t\t\033[0m\n')"
fi

# Display: symbol, change, hint. Selection handling via --select.
# {3}=phase {4}=hint {5}=repo_root {6}=tab_id
export FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS:-}"
printf '%s\n' "$lines" | fzf \
  --delimiter $'\t' \
  --with-nth 1,2,4 \
  --no-info \
  --header "OpenSpec changes – Enter/click: select, Esc: close ($(observer_status))" \
  --bind "enter:execute(bash \"$ROOT/picker.sh\" --select {2} {5} {3} {6})+change-header({4})" \
  --bind "double-click:execute(bash \"$ROOT/picker.sh\" --select {2} {5} {3} {6})+change-header({4})" \
  --listen=0 \
  --ansi
