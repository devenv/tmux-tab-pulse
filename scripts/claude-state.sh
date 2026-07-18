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

exit 0
