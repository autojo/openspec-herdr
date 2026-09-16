#!/usr/bin/env bash
# Agent syntax table: the apply workflow as each Herdr agent kind invokes it
# (verified against OpenSpec 1.13 command generation), and detection of the
# installed kinds. Table order is the default-runner preference order.

set -euo pipefail

AGENT_APPLY_TABLE='
claude	/opsx:apply {change}
opencode	/opsx-apply {change}
codex	$openspec-apply-change {change}
gemini	/opsx:apply {change}
copilot	/opsx-apply {change}
kilo	/opsx-apply {change}
qwen	/opsx-apply {change}
cursor	/opsx-apply {change}
'

# Prints the installed agent kinds with their apply syntax, preference order:
#   kind<TAB>apply-template
# Kinds are Herdr's canonical executables, so `command -v` on the PATH works.
detect_runners() {
  local kind apply
  while IFS=$'\t' read -r kind apply; do
    [ -n "$kind" ] || continue
    if command -v "$kind" >/dev/null 2>&1; then
      printf '%s\t%s\n' "$kind" "$apply"
    fi
  done <<< "$AGENT_APPLY_TABLE"
}
