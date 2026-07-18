# tmux-tab-pulse

A tiny, fixed-width busy/idle indicator for tmux window tabs.

It answers one question at a glance, per tab, without switching into it: *is
anything happening here?*

```
myrepo         idle — nothing going on
myrepo ⠹       Claude Code is working (animated spinner)
myrepo ●       Claude Code finished and is waiting on you (red, alarming)
myrepo ▪       a plain process is still running (script, dev server, …)
```

The cell is always reserved — the tab's width never changes as it switches
between these states.

It considers **every pane in the window**, not just the active one, and if a
window has both a busy Claude Code pane and a plain running process in
another pane, Claude's status wins.

## How it works

- A tiny background daemon (one per tmux server) polls all panes, classifies
  each one, and writes a precomputed glyph into a per-window tmux option
  (`@tab_pulse`). `window-status-format` just reads that option — no
  per-window subprocess, no shelling out from the status line itself.
- [Claude Code hooks](https://code.claude.com/docs/en/hooks) push state
  ("working" / "attention" / "idle") onto whichever pane Claude is running
  in, via `$TMUX_PANE`. This is optional — the plugin works for plain
  processes with zero Claude Code integration.
- Everything is a tmux option (`@tab-pulse-*`), so you can restyle glyphs,
  change the animation speed, or turn parts off without editing any script.

## Install

### TPM (recommended)

Add to `~/.tmux.conf`, above the line that runs TPM:

```tmux
set -g @plugin 'rafaelsales/tmux-tab-pulse'
```

Then `prefix + I` to fetch and load it.

### Manual

```tmux
run '~/path/to/tmux-tab-pulse/tab-pulse.tmux'
```

### Claude Code integration (optional, one-time)

To get the animated "working" spinner and the red "your turn" marker, register
the plugin's hooks into Claude Code's settings:

```sh
~/path/to/tmux-tab-pulse/scripts/install-claude-hooks.sh
```

This appends entries to `~/.claude/settings.json` (backing up the original
first) for `SessionStart`, `UserPromptSubmit`, `Stop`, `Notification`, and
`SessionEnd`. It's safe to re-run — it detects it's already installed and
does nothing. Without this step, tmux-tab-pulse still shows the static
process marker for any other running command; it just won't know anything
about Claude specifically.

> **Note:** this writes to the *live* Claude Code settings file
> (`~/.claude/settings.json` by default — override with
> `CLAUDE_SETTINGS_PATH`). If you keep your Claude config elsewhere and
> symlink it in, make sure that symlink target is where you expect hooks to
> land.

## Options

All are `tmux set -g <option> <value>` (or in `.tmux.conf` before/after
loading the plugin — options are read live by the daemon on every tick, so
changes take effect within one tick, no reload needed).

| Option | Default | Meaning |
|---|---|---|
| `@tab-pulse-interval` | `500` | Tick length in ms while anything is in the `working` state (drives spinner animation speed). |
| `@tab-pulse-idle-interval` | `2000` | Tick length in ms when nothing is working (still needs to catch processes starting/stopping and Claude turns finishing). |
| `@tab-pulse-spinner` | `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` | Space-separated animation frames for the `working` state. |
| `@tab-pulse-working-style` | `#[fg=colour45]` | tmux style prefix applied to the spinner. |
| `@tab-pulse-attention-glyph` | `●` | Glyph shown when Claude has finished / needs you. |
| `@tab-pulse-attention-style` | `#[fg=red,bold]` | Style for the attention glyph. |
| `@tab-pulse-process-glyph` | `▪` | Glyph shown for a plain running process. |
| `@tab-pulse-process-style` | `#[fg=colour39]` | Style for the process glyph. |
| `@tab-pulse-idle-glyph` | ` ` (space) | What renders in the reserved cell when idle. |
| `@tab-pulse-process-detection` | `on` | Set to `off` to disable the plain-process marker entirely (Claude-only mode). |
| `@tab-pulse-ignore-commands` | `nvim vim vi less more man htop btop top fzf tig lazygit bat delta` | Space-separated `pane_current_command` values that should *not* count as "a process running" (interactive TUIs). |
| `@tab-pulse-shells` | `zsh bash sh fish -zsh -bash -sh -fish` | Space-separated commands treated as "just a shell prompt", i.e. never a process. |
| `@tab-pulse-name-format` | `#I:#W` | The window-name portion tmux-tab-pulse builds its format string around. |
| `@tab-pulse-manual` | `off` | Set to `on` to stop tmux-tab-pulse from touching `window-status-format` — place `#{@tab_pulse}` yourself wherever you like in your own format string. |

## Precedence

Each pane in a window is classified, and the window shows the
highest-priority pane's status:

```
claude-working > claude-attention > process > claude-idle > idle
```

A working or awaiting-you Claude pane always wins over a sibling process pane.
A Claude pane that's merely idle, though, yields to a genuinely running
process in another pane — so a dev server in a split still surfaces instead
of being masked by a quiet Claude prompt.

## Requirements

- tmux ≥ 3.0 (developed against 3.5a)
- `bash` (works fine with macOS's stock bash 3.2 — no bash 4+ features used)
- `awk` (any of gawk/mawk/BSD awk)
- `jq`, only for the optional Claude-hooks installer

## License

MIT — see [LICENSE](LICENSE).
