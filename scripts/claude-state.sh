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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
. "$SCRIPT_DIR/helpers.sh"

state="${1:-}"

case "$state" in
  clear|"")
    # SessionEnd, or called with no state: remove the marker entirely so this
    # pane stops being treated as a Claude pane at all.
    tmux set-option -pu -t "$TMUX_PANE" @tab_pulse_state >/dev/null 2>&1
    ;;
  *)
    tmux set-option -p -t "$TMUX_PANE" @tab_pulse_state "$state" >/dev/null 2>&1
    ;;
esac

# Publish this pane's window right now instead of waiting for the daemon's
# next poll — the poll cadence backs off to @tab-pulse-idle-interval (2s by
# default) whenever nothing is working, so without this a fast turn could
# finish before the daemon ever notices it started. The daemon still owns
# animating the spinner past its first frame and detecting plain (non-Claude)
# processes, both of which don't need this instant path.
win="$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)"
if [ -n "$win" ]; then
  priority="$(tab_pulse_window_priority "$win")"
  glyph="$(tab_pulse_glyph_for_priority "$priority")"
  tmux set-option -w -t "$win" @tab_pulse "$glyph" >/dev/null 2>&1
  tmux refresh-client -S >/dev/null 2>&1
fi

exit 0
