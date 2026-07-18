#!/usr/bin/env bash
# tmux-tab-pulse — TPM entrypoint.
#
# Wires window-status-format/window-status-current-format to reserve a
# fixed-width cell for the pulse indicator, then starts the background
# daemon (scripts/daemon.sh) that computes and refreshes it.
#
# Safe to re-source (tmux re-runs plugin scripts on `prefix + I` / reload).

set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./scripts/helpers.sh
. "$CURRENT_DIR/scripts/helpers.sh"

wire_status_format() {
  local manual
  manual="$(tmux_get '@tab-pulse-manual' 'off')"
  [ "$manual" = "off" ] || return 0

  local name_format
  name_format="$(tmux_get '@tab-pulse-name-format' '#I:#W')"

  # One leading separator space + one glyph cell, reserved whether or not
  # @tab_pulse is currently set — this is what keeps the tab chip's width
  # constant across idle/working/attention/process states.
  local suffix='#{?@tab_pulse,#{@tab_pulse}, }#{?window_flags,#{window_flags}, }'

  tmux set-option -g window-status-format "${name_format} ${suffix}"
  tmux set-option -g window-status-current-format "${name_format} ${suffix}"
}

start_daemon() {
  tmux run-shell -b "$CURRENT_DIR/scripts/daemon.sh"
}

wire_status_format
start_daemon

# Re-arm the daemon whenever a new tmux server-level session is created after
# this one dies out (e.g. `tmux kill-server` then a fresh `tmux new`) — the
# lock directory is cleaned up on exit so this is a no-op if one is already
# running.
tmux set-hook -ga session-created "run-shell -b '$CURRENT_DIR/scripts/daemon.sh'"
