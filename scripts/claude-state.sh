#!/usr/bin/env bash
# Claude Code hook receiver.
#
# Registered as a Claude Code hook command (see ../claude-hooks.json /
# install-claude-hooks.sh). Claude invokes this with one argument — the state
# name — on each lifecycle transition. We just stash that state on the tmux
# *pane* Claude happens to be running in; the daemon (scripts/daemon.sh)
# aggregates pane state into a per-window indicator on its own schedule.
#
# Deliberately trivial and fast: it must never slow down or block Claude.
# Hook stdin (the JSON payload Claude sends) is intentionally ignored.

set -u

# Not inside tmux (e.g. Claude run outside a tmux pane) — nothing to do.
if [ -z "${TMUX_PANE:-}" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/helpers.sh
. "$SCRIPT_DIR/helpers.sh"

state="${1:-}"

# bump_agents <delta>
# Reads the pane's current subagent counter, adds <delta>, clamps at a 0
# floor (a stray/duplicate SubagentStop must never drive it negative), and
# re-stamps the timestamp so the daemon's staleness self-heal (mirrors
# tab_pulse_working_stale_seconds — a missed SubagentStop, e.g. from an
# interrupted parent turn, would otherwise leave this stuck above 0 forever)
# has a fresh clock to measure from.
#
# Locked (mkdir, keyed per-pane): this is a read-modify-write on a shared
# tmux option, and parallel Task launches fire SubagentStart concurrently —
# verified without the lock, 8 concurrent agent_start calls on one pane
# settled at 2, not 8 (each reads the same stale value before any writes
# land). The wait is capped at ~5s (100 * 50ms) as a safety valve: if
# something else is somehow wedged holding the lock, degrading to "this one
# push is dropped" is far better than hanging the hook — and therefore
# Claude itself — indefinitely. Contention this heavy in practice is rare
# (concurrent hook firings for the SAME pane, not just concurrent subagents
# in general), so the lock's cost is negligible the overwhelming majority of
# the time.
bump_agents() {
  local delta="$1" current lockdir waited=0
  lockdir="${TMPDIR:-/tmp}/tmux-tab-pulse-agents-$(printf '%s' "$TMUX_PANE" | tr -c 'A-Za-z0-9' '_').lock"
  while ! mkdir "$lockdir" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -gt 100 ] && break
    sleep 0.05
  done

  current="$(tmux show-option -pqv -t "$TMUX_PANE" @tab_pulse_agents 2>/dev/null)"
  # Guard against a corrupted/non-numeric value: under `set -u`, bash
  # arithmetic dereferences a bare word as a variable name, so
  # $((current + delta)) with current="abc" aborts on "unbound variable"
  # instead of just treating it as 0 — verified this crashes the hook
  # (before publishing or waking the daemon) rather than degrading.
  case "$current" in
  '' | *[!0-9-]*) current=0 ;;
  esac
  current=$((current + delta))
  [ "$current" -lt 0 ] && current=0
  tmux set-option -p -t "$TMUX_PANE" @tab_pulse_agents "$current" >/dev/null 2>&1
  tmux set-option -p -t "$TMUX_PANE" @tab_pulse_agents_ts "$(date +%s)" >/dev/null 2>&1

  rmdir "$lockdir" 2>/dev/null
}

case "$state" in
  clear|"")
    # SessionEnd, or called with no state: remove the marker entirely so this
    # pane stops being treated as a Claude pane at all. Subagents can't
    # legitimately outlive their parent session, so their counter goes too.
    tmux set-option -pu -t "$TMUX_PANE" @tab_pulse_state >/dev/null 2>&1
    tmux set-option -pu -t "$TMUX_PANE" @tab_pulse_ts >/dev/null 2>&1
    tmux set-option -pu -t "$TMUX_PANE" @tab_pulse_agents >/dev/null 2>&1
    tmux set-option -pu -t "$TMUX_PANE" @tab_pulse_agents_ts >/dev/null 2>&1
    ;;
  agent_start)
    # Deliberately does NOT touch @tab_pulse_state — a subagent starting
    # doesn't change what the MAIN turn is doing; classify.awk factors the
    # agent counter in as its own, separate signal.
    bump_agents 1
    ;;
  agent_stop)
    bump_agents -1
    ;;
  *)
    tmux set-option -p -t "$TMUX_PANE" @tab_pulse_state "$state" >/dev/null 2>&1
    # Timestamp lets the daemon self-heal a "working" state that never gets
    # a matching Stop — e.g. the user interrupted the turn (Esc/Ctrl-C),
    # which Claude Code's docs say does NOT fire Stop — instead of showing
    # the working spinner forever. See tab_pulse_working_stale_seconds.
    tmux set-option -p -t "$TMUX_PANE" @tab_pulse_ts "$(date +%s)" >/dev/null 2>&1
    ;;
esac

# Publish this pane's window right now instead of waiting for the daemon's
# next poll — the poll cadence backs off to @tab-pulse-idle-interval (2s by
# default) whenever nothing is working, so without this a fast turn could
# finish before the daemon ever notices it started.
win="$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)"
if [ -n "$win" ]; then
  tab_pulse_publish_window "$win"
  tmux refresh-client -S >/dev/null 2>&1
fi

# Wake the daemon immediately rather than leaving it asleep for up to
# @tab-pulse-idle-interval: this one-off push only ever shows a single
# static frame (the caller has no ongoing frame counter to animate with),
# and without this, the daemon wouldn't take over actually *animating* the
# spinner — or notice a "your turn" transition on some OTHER pane, or shift
# into its faster working-cadence — until its current sleep happened to run
# out on its own.
lockdir="$(tab_pulse_lock_dir)"
daemon_pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
if [ -n "$daemon_pid" ]; then
  kill -USR1 "$daemon_pid" 2>/dev/null || true
fi

exit 0
