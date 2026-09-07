# tmux-tab-pulse

A tiny, fixed-width busy/idle indicator for tmux window tabs.

It answers one question at a glance, per tab, without switching into it: *is
anything happening here?*

```
myrepo ○       idle — nothing going on (dim, easy to ignore)
myrepo ⠹       Claude Code is working (animated spinner)
myrepo ⚠       Claude Code needs you — a permission prompt or a question (red, alarming)
myrepo ⚙2      2 Task-tool subagents are actively running in this window
myrepo ●       a plain process is running (script, dev server, …) — light yellow
myrepo ⛔       a turn ended via a rate limit or billing/spend-cap error (orange, outranks everything)
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
  ("working" / "attention" / "idle") onto whichever pane Claude is
  running in, via `$TMUX_PANE`. This is optional — the plugin works for plain
  processes with zero Claude Code integration. The hook script also pushes an
  immediate update itself the moment a hook fires — showing the correct glyph
  right away — and wakes the daemon (a `SIGUSR1` to its own pid, found via
  its lock file) so it takes over animating subsequent frames immediately
  instead of sitting out the rest of whatever idle-cadence sleep it happened
  to be in. Without this, a turn could start and finish before the daemon's
  own poll ever noticed it, or the spinner could sit frozen on its first
  frame for up to `@tab-pulse-idle-interval`.
- **Subagents get their own signal, independent of the main state**:
  `SubagentStart`/`SubagentStop` maintain a live count of Task-tool
  subagents running in a pane. A window with one or more active subagents
  shows a count (`⚙2` by default) instead of idle/process — even if
  the MAIN turn already Stopped, since background agent work is real,
  ongoing activity the main state alone can't see. Never overrides
  `attention`: a genuine pending question always wins over background
  busywork.
- **A turn that ended via an API error gets its own marker, above
  everything else**: Claude Code's `StopFailure` hook (matchers `rate_limit`
  and `billing_error`) maps to `quota_error` — a rate limit or a
  billing/spend-cap hit, not a normal completion. Outranks `attention`
  itself: a broken turn needing a model switch or a wait is a more urgent
  signal than a routine pending question.
- **Red means a genuine ask, not just "a turn ended"**: only
  `Notification`'s `permission_prompt`/`agent_needs_input` matchers — which
  specifically mean Claude is blocked waiting on you for something — turn the
  marker red. (An earlier version mapped `Stop` straight to `attention`,
  so any pane you hadn't glanced at since its last turn stayed alarmingly red
  indefinitely, regardless of whether anything was actually pending. A later
  version added `idle_prompt` to the same list, which turned out to be just
  as wrong in a subtler way: that notification fires whenever Claude Code
  notices a session has been sitting idle, i.e. on ordinary finished turns —
  not on a genuine block — so it re-created the same false-red problem
  `Stop`'s removal had already fixed.)
- **Self-heals stale state**: if Claude exits without ever firing its
  `SessionEnd` hook (killed, Ctrl-C'd, crashed), a pane can be left with a
  stuck `attention`/`working` marker and no more hooks left to clear it. The
  daemon notices when a pane still carries Claude state but its foreground
  command has reverted to a plain shell, and clears it automatically within
  one tick.
- Everything is a tmux option (`@tab-pulse-*`), so you can restyle glyphs,
  change the animation speed, or turn parts off without editing any script.

> **Note:** without the hooks installed, tmux can't tell "Claude Code is
> sitting idle at its prompt" apart from "a process is running" — it'll show
> the static process marker (`●`, light yellow) for an idle Claude REPL, same as any other
> non-shell command, since tmux reports Claude Code's `pane_current_command`
> as its version string (e.g. `2.1.214`), not `claude`. Installing the hooks
> is what lets tmux-tab-pulse distinguish Claude's actual working/attention
> states from "just some process is running".

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

To get the animated "working" spinner and the red "genuinely needs you"
marker, register the plugin's hooks into Claude Code's settings:

```sh
~/path/to/tmux-tab-pulse/scripts/install-claude-hooks.sh
```

This appends entries to `~/.claude/settings.json` (backing up the original
first) for `SessionStart`, `UserPromptSubmit`, `Stop`, `Notification`,
`SessionEnd`, `SubagentStart`, `SubagentStop`, and `StopFailure`. It's safe
to re-run — idempotent per event, not just all-or-nothing: if you (or
something else)
later remove just one or two of
these hooks by hand, re-running restores only what's missing rather than
seeing anything and doing nothing. Without this step, tmux-tab-pulse still
shows the static process marker for any other running command; it just
won't know anything about Claude specifically.

> **Note:** this writes to the *live* Claude Code settings file
> (`~/.claude/settings.json` by default — override with
> `CLAUDE_SETTINGS_PATH`). If you keep your Claude config elsewhere and
> symlink it in, make sure that symlink target is where you expect hooks to
> land.

## Options

All are `tmux set -g <option> <value>`. Most are read live by the daemon on
its next tick (≤ `@tab-pulse-idle-interval`, or the current spinner tick if
one's mid-run), so most changes just take effect on their own. Three are
read only ONCE, at plugin load time, and need a reload (`prefix + I`,
`tmux source ~/.tmux.conf`, or a restart) to pick up a change — marked below.
`@tab-pulse-interval`/`@tab-pulse-idle-interval` are clamped to a 50ms floor
regardless of what you set (a non-numeric or too-low value would otherwise
busy-loop the daemon).

| Option | Default | Meaning |
|---|---|---|
| `@tab-pulse-interval` | `500` | Tick length in ms while anything is in the `working` state (drives spinner animation speed). |
| `@tab-pulse-idle-interval` | `2000` | Tick length in ms when nothing is working (still needs to catch processes starting/stopping and Claude turns finishing). |
| `@tab-pulse-spinner` *(load-time only for the daemon's own animation)* | `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` | Space-separated animation frames for the `working` state. Read once into the daemon's frame list at startup — restart it to pick up a change. The hook script's own one-off immediate push (frame 0, as a placeholder until the daemon's next tick takes over) reads it fresh each time, so a mid-session change shows up there first. |
| `@tab-pulse-working-style` | `#[fg=colour45]` | tmux style prefix applied to the spinner. |
| `@tab-pulse-attention-glyph` | `⚠` | Glyph shown when Claude genuinely needs you (permission prompt / question). |
| `@tab-pulse-attention-style` | `#[fg=red,bold]` | Style for the attention glyph. |
| `@tab-pulse-quota-glyph` | `⛔` | Glyph shown when a turn ended via a rate limit or billing/spend-cap error (`StopFailure`), outranking every other state. |
| `@tab-pulse-quota-style` | `#[fg=colour208,bold]` (orange, bold) | Style for the quota-error glyph. |
| `@tab-pulse-agent-glyph` | `⚙` | Glyph prefix shown when one or more Task-tool subagents are running in the window, followed by the live count (e.g. `⚙2`). |
| `@tab-pulse-agent-style` | `#[fg=colour213]` | Style for the agent-count glyph. |
| *(no separate option)* | — | The subagent counter's staleness self-heal (a nonzero count reset to 0 after no fresh `SubagentStart`/`SubagentStop`, mirroring `working`'s) deliberately reuses `@tab-pulse-working-stale-seconds` rather than having its own knob — set that one option to change both. |
| `@tab-pulse-process-glyph` | `●` | Glyph shown for a plain running process (distinct shape from attention's `⚠`). |
| `@tab-pulse-process-style` | `#[fg=colour229]` (light yellow) | Style for the process glyph. |
| `@tab-pulse-idle-glyph` | `○` | What renders in the reserved cell when idle. Set to `' '` (space) to go back to a blank cell. |
| `@tab-pulse-idle-style` | `#[fg=colour242]` (dim gray) | Style for the idle glyph — muted on purpose, so it stays easy to visually ignore next to the busier states. |
| `@tab-pulse-process-detection` | `on` | Set to `off` to disable the plain-process marker entirely (Claude-only mode). |
| `@tab-pulse-working-stale-seconds` | `900` | Seconds a pane may sit in `working` with no fresh push before it's treated as claude-idle instead — self-heals a turn interrupted (Esc/Ctrl-C) before Claude's `Stop` hook could fire, since that hook doesn't run on a user interrupt. `0` disables the check. Never applies to `attention`, which can legitimately wait a long time. |
| `@tab-pulse-claude-version-pattern` | `^[0-9]+(\.[0-9]+){1,3}$` | ERE matching Claude Code's own `pane_current_command` shape (tmux reports its version string, e.g. `2.1.263`, not `claude`) — lets a pane with no hook-pushed state yet (predates the hooks being installed) still classify as claude-idle instead of the generic process marker. |
| `@tab-pulse-ignore-commands` | `nvim vim vi less more man htop btop top fzf tig lazygit bat delta` | Space-separated `pane_current_command` values that should *not* count as "a process running" (interactive TUIs). |
| `@tab-pulse-shells` | `zsh bash sh fish -zsh -bash -sh -fish` | Space-separated commands treated as "just a shell prompt", i.e. never a process. |
| `@tab-pulse-name-format` *(load-time only)* | `#I:#W` | The window-name portion tmux-tab-pulse builds its format string around. |
| `@tab-pulse-manual` *(load-time only)* | `off` | Set to `on` to stop tmux-tab-pulse from touching `window-status-format` — place `#{@tab_pulse}` yourself wherever you like in your own format string. |

## Precedence

Each pane in a window is classified, and the window shows the
highest-priority pane's status:

```
claude-quota-error > claude-working > claude-attention > process > claude-idle > idle
```

A working or awaiting-you Claude pane always wins over a sibling process pane.
A Claude pane that's merely idle, though, yields to a genuinely running
process in another pane — so a dev server in a split still surfaces instead
of being masked by a quiet Claude prompt.

Running subagents are tracked separately from this ladder entirely (summed
across every pane in the window) and override the glyph choice above — except
`attention`, which always wins regardless of subagent activity.

## Known limitations

- **Suspending Claude (Ctrl-Z)** briefly looks like it exited: the pane's
  foreground command reverts to your shell while suspended, which the
  self-heal (see below) treats the same as "Claude exited without cleanup"
  and clears its state within one tick. `fg` doesn't restore it — the
  indicator stays blank until the next hook fires (next prompt, or you quit
  Claude). Self-limiting and rare enough not to be worth the extra
  cross-tick state tracking a fix would need.
- With more than one client attached to the same session, only the
  attached client(s) tmux's `refresh-client -S` reaches are guaranteed to
  redraw immediately; in the worst case a less-active client could lag up to
  `status-interval` (tmux's own default: 15s) behind.

## Requirements

- tmux ≥ 3.0 (developed against 3.5a)
- `bash` (works fine with macOS's stock bash 3.2 — no bash 4+ features used)
- `awk` (any of gawk/mawk/BSD awk)
- `jq`, only for the optional Claude-hooks installer

## License

MIT — see [LICENSE](LICENSE).
