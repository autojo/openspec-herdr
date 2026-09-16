#!/usr/bin/env bash
# Minimal parser for the runner configuration (runners.toml).
# Supports exactly the generated template form:
#   default = "name"
#   [runners.name]
#   kind = "string"
#   args = ["a", "b"]
#   apply = "/opsx:apply {change}"
# No general TOML interpreter.

# File that is parsed. CONFIG_DIR is set by lib.sh.
RUNNERS_FILE="${RUNNERS_FILE:-${CONFIG_DIR:-$HOME/.config/herdr/plugins/config/openspec.picker}/runners.toml}"

# Agents table: kind -> apply syntax, preference order.
# shellcheck source=agents.sh
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$AGENTS_DIR/agents.sh"

# Notification fallback; lib.sh provides its own (same signature).
if ! command -v notify >/dev/null 2>&1; then
  notify() {
    local title="$1" body="$2"
    "${HERDR_BIN_PATH:-herdr}" notification show "$title" --body "$body" >/dev/null 2>&1 || true
  }
fi

# Creates runners.toml on first start, generated from the installed agents.
# Never overwrites an existing file. Without any known installed agent the
# file contains only comments and a notification is shown.
ensure_runners_file() {
  local default="" out="" kind apply first=1 count=0
  mkdir -p "$(dirname "$RUNNERS_FILE")"
  [ -f "$RUNNERS_FILE" ] && return 0
  while IFS=$'\t' read -r kind apply; do
    [ -n "$kind" ] || continue
    count=$((count + 1))
    [ "$first" -eq 1 ] && default="$kind" && first=0
    out="${out}[runners.$kind]
kind = \"$kind\"
apply = \"$apply\"

"
  done < <(detect_runners)
  {
    cat <<'EOF'
# OpenSpec apply runners. Each named runner has an agent kind (kind), optional
# arguments for the agent start (args) and an apply command template (apply)
# with the {change} placeholder. Edit and reopen the picker.
#
# Example with an explicit model:
#   [runners.claude-sonnet]
#   kind = "claude"
#   args = ["--model", "sonnet"]
#   apply = "/opsx:apply {change}"
#
# Generated from the agents found on this machine. Add or change runners as
# you like; this file is never regenerated.
EOF
    if [ -n "$default" ]; then
      printf '\ndefault = "%s"\n\n' "$default"
    fi
    printf '%s' "$out"
  } > "$RUNNERS_FILE"
  if [ "$count" -eq 0 ]; then
    notify "OpenSpec: no runner detected" \
      "No supported agent was found. Add a runner to $RUNNERS_FILE."
  fi
  return 0
}

_unquote() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    \"*) v="${v#\"}"; v="${v%\"}" ;;
    \'*) v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# Prints lines of the form:
#   default<TAB><name>
#   <runner><TAB><key><TAB><value>     (args elements separated by \x1f)
_runners_dump() {
  local line section="" key value elems
  [ -f "$RUNNERS_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    [ -z "$line" ] && continue
    case "$line" in
      \[runners.*\])
        section="${line#\[runners.}"
        section="${section%\]}"
        section="$(_unquote "$section")"
        ;;
      \[*\]*)
        section=""
        ;;
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        key="${key#"${key%%[![:space:]]*}"}"
        value="$(_unquote "$value")"
        case "$value" in
          \[*\])
            elems="$(printf '%s\n' "$value" | sed -e 's/^\[//' -e 's/\]$//' -e 's/,/\n/g' \
              | while IFS= read -r e || [ -n "$e" ]; do
                  e="$(_unquote "$e")"
                  [ -n "$e" ] && printf '%s\x1f' "$e"
                done)"
            ;;
          *) elems="" ;;
        esac
        if [ -z "$section" ] && [ "$key" = "default" ]; then
          printf 'default\t%s\n' "$value"
        elif [ -n "$section" ]; then
          if [ "$key" = "args" ]; then
            printf '%s\t%s\t%s\n' "$section" "$key" "$elems"
          else
            printf '%s\t%s\t%s\n' "$section" "$key" "$value"
          fi
        fi
        ;;
    esac
  done < "$RUNNERS_FILE"
}

# Name of the default runner; empty when the file is missing/unreadable.
runner_default() {
  _runners_dump 2>/dev/null | awk -F'\t' '$1=="default"{print $2; exit}'
}

# A single field of a runner. "args" prints one element per line.
# Returns 1 when the field or the runner is missing (or args is empty).
runner_field() {
  local name="$1" key="$2"
  local val
  val="$(_runners_dump 2>/dev/null | awk -F'\t' -v n="$name" -v k="$key" '$1==n && $2==k{$0=substr($0, length($1)+length($2)+3); print; exit}')"
  [ -n "$val" ] || return 1
  if [ "$key" = "args" ]; then
    printf '%s' "$val" | tr $'\x1f' '\n' | while IFS= read -r a || [ -n "$a" ]; do
      [ -n "$a" ] && printf '%s\n' "$a"
    done
  else
    printf '%s\n' "$val"
  fi
}

# All runner names, one per line.
runner_names() {
  _runners_dump 2>/dev/null | awk -F'\t' '$1!="default"{print $1}' | sort -u
}
