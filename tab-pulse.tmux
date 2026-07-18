#!/usr/bin/env bash
# tmux-tab-pulse — TPM entrypoint.
#
# Wires window-status-format/window-status-current-format to reserve a
# fixed-width cell for the pulse indicator, then starts the background
# daemon (scripts/daemon.sh) that computes and refreshes it.
#
# Safe to re-source (tmux re-runs plugin scripts on `prefix + I` / reload).

set -u

# `pwd -P` (not plain `pwd`) resolves symlinks to a canonical path: this repo
# is commonly reached through more than one path (e.g. a real clone AND a
# `~/.tmux/plugins/...` symlink TPM expects), and without canonicalizing,
# arm_restart_hook's dedup check below would treat the same daemon reached
# via each path as two different entries and register it twice.
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
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

arm_restart_hook() {
  # Re-arm the daemon on every new session in case it died unexpectedly (a
  # crash, an OOM kill, ...) while the server itself kept running — the
  # single-instance lock makes this a no-op whenever a daemon is already
  # alive. `set-hook -ga` appends unconditionally, so re-sourcing this file
  # (`prefix + I`, a config reload) would otherwise register another
  # identical entry every time; skip it if one's already registered.
  if tmux show-hooks -g 2>/dev/null | grep -qF "$CURRENT_DIR/scripts/daemon.sh"; then
    return 0
  fi
  tmux set-hook -ga session-created "run-shell -b '$CURRENT_DIR/scripts/daemon.sh'"
}

wire_status_format
start_daemon
arm_restart_hook
