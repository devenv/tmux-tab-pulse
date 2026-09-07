#!/usr/bin/env bash
# Shared helpers for tmux-tab-pulse: option getters (with defaults), and small
# utilities shared between the daemon and the tmux entrypoint.
#
# Every knob is a tmux option under the @tab-pulse-* namespace, so users can
# retune behavior without editing scripts (`set -g @tab-pulse-interval 300`).

# Resolved from THIS file's own location (not the caller's), since helpers.sh
# is sourced by scripts that may live elsewhere in principle — needed so
# tab_pulse_publish_window below can find classify.awk reliably.
TAB_PULSE_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# tmux_get <option> <default>
# Reads a global tmux option, falling back to <default> if unset/empty.
tmux_get() {
  local option="$1"
  local default="$2"
  local value
  value="$(tmux show-option -gqv "$option" 2>/dev/null)"
  if [ -z "$value" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

# Cadence (milliseconds), converted to seconds (with fraction) for `sleep`.
# Clamped to a 50ms floor: a non-numeric or negative @tab-pulse-* value would
# otherwise become a 0-length sleep (awk coerces non-numeric strings to 0 in
# numeric context) and busy-loop the daemon at effectively 100% CPU.
tab_pulse_interval_seconds() {
  local ms
  ms="$(tmux_get '@tab-pulse-interval' '500')"
  LC_ALL=C awk -v ms="$ms" 'BEGIN { ms = ms + 0; if (ms < 50) ms = 50; printf "%.3f", ms / 1000 }'
}

tab_pulse_idle_interval_seconds() {
  local ms
  ms="$(tmux_get '@tab-pulse-idle-interval' '2000')"
  LC_ALL=C awk -v ms="$ms" 'BEGIN { ms = ms + 0; if (ms < 50) ms = 50; printf "%.3f", ms / 1000 }'
}

# Seconds a pane may sit in the "working" state with no fresh push before the
# daemon stops trusting it and treats it as claude-idle instead. Claude Code's
# Stop hook does not fire when a turn ends via user interrupt (Esc/Ctrl-C) —
# https://code.claude.com/docs/en/hooks — so a pane left mid-turn that way
# would otherwise show the working spinner forever, since nothing but another
# UserPromptSubmit or SessionEnd would ever clear it. 0 disables the check.
tab_pulse_working_stale_seconds() {
  tmux_get '@tab-pulse-working-stale-seconds' '900'
}

# ERE Claude Code's own pane_current_command matches when hook state hasn't
# been pushed yet: tmux reports Claude Code's version string (e.g. 2.1.214)
# as the foreground command, not "claude" (see README) — so a pane running
# Claude Code that predates the hooks being installed, or predates its first
# SessionStart/UserPromptSubmit since, would otherwise be indistinguishable
# from an arbitrary background process and get the generic process marker
# instead of anything Claude-specific.
tab_pulse_claude_version_pattern() {
  tmux_get '@tab-pulse-claude-version-pattern' '^[0-9]+(\.[0-9]+){1,3}$'
}

# Spinner frames, SPACE-SEPARATED (not one contiguous string) so the daemon
# can split them with plain word-splitting regardless of multibyte
# width/locale support in whatever /bin/bash the user has (notably macOS's
# stock bash 3.2). Default: a braille "thinking" spinner, the same family
# Claude Code's own CLI spinner uses.
tab_pulse_spinner_frames() {
  tmux_get '@tab-pulse-spinner' '⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏'
}

tab_pulse_working_style() {
  tmux_get '@tab-pulse-working-style' '#[fg=colour45]'
}

tab_pulse_attention_glyph() {
  tmux_get '@tab-pulse-attention-glyph' '⚠'
}

tab_pulse_attention_style() {
  tmux_get '@tab-pulse-attention-style' '#[fg=red,bold]'
}

tab_pulse_process_glyph() {
  tmux_get '@tab-pulse-process-glyph' '●'
}

tab_pulse_process_style() {
  tmux_get '@tab-pulse-process-style' '#[fg=colour229]'
}

tab_pulse_idle_glyph() {
  tmux_get '@tab-pulse-idle-glyph' ' '
}

tab_pulse_process_detection_enabled() {
  local v
  v="$(tmux_get '@tab-pulse-process-detection' 'on')"
  [ "$v" = "on" ]
}

# Space-separated list of pane_current_command values treated as "shell, not
# a process" (so a bare shell prompt never lights up the process marker).
tab_pulse_shells() {
  tmux_get '@tab-pulse-shells' 'zsh bash sh fish -zsh -bash -sh -fish'
}

# Space-separated list of commands to ignore for process-detection purposes
# (interactive TUIs: editors, pagers, monitors — not "busy" in the sense we
# care about here).
tab_pulse_ignore_commands() {
  tmux_get '@tab-pulse-ignore-commands' \
    'nvim vim vi less more man htop btop top fzf tig lazygit bat delta'
}

# tab_pulse_lock_dir
# The daemon's single-instance lock directory for the CURRENT tmux server,
# keyed by socket path (not just uid) so independent tmux servers run by the
# same user each get their own daemon rather than racing for one lock. Its
# pid file lets other scripts (claude-state.sh) find the running daemon to
# signal it directly, without needing to know its PID in advance.
tab_pulse_lock_dir() {
  local socket_path="${TMUX%%,*}"
  if [ -z "$socket_path" ]; then
    socket_path="$(tmux display-message -p '#{socket_path}' 2>/dev/null)"
  fi
  local lock_key
  lock_key="$(printf '%s' "${socket_path:-default}" | tr -c 'A-Za-z0-9' '_')"
  printf '%s' "${TMPDIR:-/tmp}/tmux-tab-pulse-$(id -u)-${lock_key}.lock"
}

# tab_pulse_publish_window <window_id>
# Classifies every pane in <window_id> RIGHT NOW via classify.awk (the exact
# same logic daemon.sh's bulk sweep uses — see that file) and writes the
# result directly to the window's @tab_pulse option, unconditionally (no
# change-detection: statefile is /dev/null, so classify.awk always emits a
# WIN line rather than only-on-change, since this caller has no previous-tick
# snapshot of its own to compare against — it wants "the current glyph",
# every time it's called).
#
# Used by claude-state.sh for its immediate, single-window push right after
# a hook fires — cheap enough there since it only ever scopes to one
# window's panes, unlike the daemon's server-wide sweep. Kept as ONE
# implementation (this) rather than a second hand-written priority
# calculation, so the two can never drift out of sync with each other.
tab_pulse_publish_window() {
  local win="$1"
  local shells ignores detect
  shells="$(tab_pulse_shells)"
  ignores="$(tab_pulse_ignore_commands)"
  if tab_pulse_process_detection_enabled; then detect=on; else detect=off; fi

  # No frame counter here (this is a one-off push, not an animation tick) —
  # the first spinner frame is used as a static placeholder; the daemon's
  # own next tick takes over actually animating it.
  local frames frame
  read -r -a frames <<<"$(tab_pulse_spinner_frames)"
  frame="${frames[0]:-*}"

  local aggregated kind a b
  aggregated="$(tmux list-panes -t "$win" -F $'#{window_id}\t#{pane_id}\t#{pane_current_command}\t#{@tab_pulse_state}\t#{@tab_pulse_ts}' 2>/dev/null \
    | LC_ALL=C awk -F $'\t' \
      -v shells="$shells" -v ignores="$ignores" -v detect="$detect" \
      -v working_style="$(tab_pulse_working_style)" -v working_frame="$frame" \
      -v attention_glyph="$(tab_pulse_attention_glyph)" -v attention_style="$(tab_pulse_attention_style)" \
      -v process_glyph="$(tab_pulse_process_glyph)" -v process_style="$(tab_pulse_process_style)" \
      -v idle_glyph="$(tab_pulse_idle_glyph)" -v statefile="/dev/null" -v statefile_new="/dev/null" \
      -v claude_version_pattern="$(tab_pulse_claude_version_pattern)" \
      -v stale_seconds="$(tab_pulse_working_stale_seconds)" -v now="$(date +%s)" \
      -f "$TAB_PULSE_HELPERS_DIR/classify.awk")"

  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
    CLEAR) tmux set-option -pu -t "$a" @tab_pulse_state >/dev/null 2>&1 ;;
    WIN) tmux set-option -w -t "$a" @tab_pulse "$b" >/dev/null 2>&1 ;;
    esac
  done <<<"$aggregated"
}
