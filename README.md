# OpenSpec Picker

A [Herdr](https://herdr.dev/) plugin for [OpenSpec](https://openspec.dev/).
A change picker popup lists all active changes of the repos you have open,
with their current phase, and starts an apply in a fresh session with one
keystroke. A background observer tracks which change and phase each pane is
working on — from the terminal output, so it works with any agent.

## How it works

1. **Explore:** run `/opsx-explore` (OpenCode) or `/opsx:explore` (Claude
   Code) in any pane. The tab gets a temporary name from the session title;
   once a change name is known, the label becomes `? <change>`.
2. **Plan:** finish proposal/specs/design/tasks as usual.
3. **Open the picker:** `prefix+alt+o` (see [Configuration](#configuration)).
   The popup lists all active changes with a phase symbol:
   `?` explore · `P` ready · `>` apply running · `!` apply blocked · `·` planning.
4. **Start an apply:** Enter/click on a ready change starts a fresh agent
   session in the repo workspace using the default runner (start the agent,
   send the apply command, tab and sidebar show `apply <change>`). Explore
   and apply entries focus the existing tab instead; for incomplete planning
   the picker names the missing artifacts and stays open.
5. **Sidebar:** agent panes carry the `os_phase`/`os_change` tokens, shown in
   the sidebar as `$os_phase`/`$os_change` after you add the snippet.

The observer scans pane output for OpenSpec signals (`/opsx:…` commands,
`openspec instructions apply --change <name>`, `openspec new change <name>`)
and follows the terminal title while an explore has no change name yet.
Tracking is agent-independent — no hooks or plugins inside agent configs.

## Installation

```bash
herdr plugin install autojo/openspec-herdr
```

Restart Herdr (or the next server start). The plugin creates its config on
first start. Open the picker through the plugin action list or add the
keybinding below.

Requirements:

- [herdr](https://herdr.dev/) (>= 0.9.0)
- `jq`, `fzf`, `curl`, `python3` on `PATH`
- `herdr integration install <agent>` for each agent you want to use
  (needed for the agent status, `apply-blocked`, and `agent prompt`)

## Configuration

The plugin never writes to your Herdr config. To add sidebar rows and a
keybinding, add this snippet to `~/.config/herdr/config.toml` yourself:

```toml
[ui.sidebar.agents]
rows = [["state_icon", "machine", "workspace", "tab"], ["terminal_title_stripped"], ["$os_phase", "$os_change"], ["agent"]]

[ui.sidebar.agents.rows_by_agent.claude]
rows = [["state_icon", "machine", "workspace", "tab"], ["terminal_title_stripped"], ["$os_phase", "$os_change"], ["agent"]]

[[keys.command]]
key = "prefix+alt+o"
type = "plugin_action"
command = "openspec.picker.open"
```

The rows keep the Herdr defaults (including the terminal title) and add one
`$os_phase`/`$os_change` row. `rows_by_agent` overrides the rows for a single
agent (here: `claude`); add more entries for other agents or omit the block
to use the default rows everywhere.

### Watched repos

Repos come from the open Herdr panes: every pane working directory that has
an `openspec/changes` directory (or an ancestor with one) is watched. Add
repos without an open pane to `watch.txt` in the plugin config directory
(`herdr plugin config-dir openspec.picker`), one absolute path per line.

### Runners

`runners.toml` (same config directory) names the agents an apply can start
with. On first start it is generated from the agents found on your machine;
edit it and reopen the picker afterwards:

```toml
default = "claude-sonnet"

[runners.claude-sonnet]
kind = "claude"
args = ["--model", "sonnet"]
apply = "/opsx:apply {change}"

[runners.opencode]
kind = "opencode"
apply = "/opsx-apply {change}"
```

`kind` is a Herdr agent kind, `args` optional arguments for the agent start,
`apply` the command template with the `{change}` placeholder.

## Upgrading from 0.2

Version 0.2 (plugin id `openspec.tabs`) tracked changes through an OpenCode
plugin and a Claude Code hook. Those are gone; the observer replaces them.

- Run `herdr plugin unlink openspec.tabs`, then install/link this version.
- Remove `openspec-tracking.js` from `~/.config/opencode/plugins/` and the
  `UserPromptSubmit` entry from `~/.claude/settings.json`.
- Move your `runners.toml` from the old config directory to the new one
  (`herdr plugin config-dir openspec.picker`), or let the plugin generate a
  fresh one from your installed agents.

## License

MIT, see [LICENSE](LICENSE).
