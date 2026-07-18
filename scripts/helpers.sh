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
