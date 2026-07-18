#!/usr/bin/env bash
# Shared helpers for tmux-tab-pulse: option getters (with defaults), and small
# utilities shared between the daemon and the tmux entrypoint.
#
# Every knob is a tmux option under the @tab-pulse-* namespace, so users can
# retune behavior without editing scripts (`set -g @tab-pulse-interval 300`).

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
tab_pulse_interval_seconds() {
  local ms
  ms="$(tmux_get '@tab-pulse-interval' '500')"
  awk -v ms="$ms" 'BEGIN { printf "%.3f", ms / 1000 }'
}

tab_pulse_idle_interval_seconds() {
  local ms
  ms="$(tmux_get '@tab-pulse-idle-interval' '2000')"
  awk -v ms="$ms" 'BEGIN { printf "%.3f", ms / 1000 }'
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
  tmux_get '@tab-pulse-attention-glyph' '●'
}

tab_pulse_attention_style() {
  tmux_get '@tab-pulse-attention-style' '#[fg=red,bold]'
}

tab_pulse_process_glyph() {
  tmux_get '@tab-pulse-process-glyph' '▪'
}

tab_pulse_process_style() {
  tmux_get '@tab-pulse-process-style' '#[fg=colour39]'
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

# word_in_list <word> <space-separated-list>
word_in_list() {
  local word="$1" list="$2" item
  for item in $list; do
    [ "$item" = "$word" ] && return 0
  done
  return 1
}

# Priority scale shared by daemon.sh's bulk aggregator and the single-window
# helper below: 5=claude-working 4=claude-attention 3=process 2=claude-idle
# 1=idle. Higher wins when aggregating panes within one window.

# tab_pulse_priority_for_claude_state <state>
tab_pulse_priority_for_claude_state() {
  case "$1" in
  working) printf '5' ;;
  attention) printf '4' ;;
  *) printf '2' ;; # any other/unknown Claude state = claude-idle
  esac
}

# tab_pulse_priority_for_process <cmd>
tab_pulse_priority_for_process() {
  local cmd="$1"
  if tab_pulse_process_detection_enabled \
    && ! word_in_list "$cmd" "$(tab_pulse_shells)" \
    && ! word_in_list "$cmd" "$(tab_pulse_ignore_commands)"; then
    printf '3'
  else
    printf '1'
  fi
}

# tab_pulse_window_priority <window_id>
# Aggregates every pane currently in <window_id> into a single priority
# number. Used for the immediate, single-window push from claude-state.sh —
# cheap enough there since it only ever scopes to one window's panes, unlike
# the daemon's server-wide sweep.
tab_pulse_window_priority() {
  local win="$1" best=1 cmd state pr
  while IFS=$'\t' read -r cmd state; do
    [ -n "$cmd" ] || continue
    if [ -n "$state" ]; then
      pr="$(tab_pulse_priority_for_claude_state "$state")"
    else
      pr="$(tab_pulse_priority_for_process "$cmd")"
    fi
    [ "$pr" -gt "$best" ] && best="$pr"
  done < <(tmux list-panes -t "$win" -F $'#{pane_current_command}\t#{@tab_pulse_state}' 2>/dev/null)
  printf '%s' "$best"
}

# tab_pulse_glyph_for_priority <priority> [working-glyph]
# [working-glyph] lets a caller with an animated frame counter (daemon.sh)
# pass the current frame; callers without one (claude-state.sh's one-off
# instant push) get the first spinner frame as a static placeholder — the
# daemon's own next tick takes over animating it.
tab_pulse_glyph_for_priority() {
  local pr="$1" working_glyph="${2:-}"
  case "$pr" in
  5)
    if [ -z "$working_glyph" ]; then
      local frames
      read -r -a frames <<<"$(tab_pulse_spinner_frames)"
      working_glyph="${frames[0]:-*}"
    fi
    printf '%s%s#[default]' "$(tab_pulse_working_style)" "$working_glyph"
    ;;
  4) printf '%s%s#[default]' "$(tab_pulse_attention_style)" "$(tab_pulse_attention_glyph)" ;;
  3) printf '%s%s#[default]' "$(tab_pulse_process_style)" "$(tab_pulse_process_glyph)" ;;
  *) printf '%s' "$(tab_pulse_idle_glyph)" ;;
  esac
}
