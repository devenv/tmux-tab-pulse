#!/usr/bin/env bats
# Tests for scripts/helpers.sh's option getters and priority helpers, against
# a real (private, isolated) tmux server.

load 'test_helper'

setup() {
  tab_pulse_setup_tmux
  source "$SCRIPTS_DIR/helpers.sh"
}

teardown() {
  tab_pulse_teardown_tmux
}

@test "tmux_get returns the default when the option is unset" {
  result="$(tmux_get '@no-such-option' 'fallback')"
  [ "$result" = "fallback" ]
}

@test "tmux_get returns the set value when present" {
  tab_pulse_tmux set-option -g '@tab-pulse-test-opt' 'hello'
  result="$(tmux_get '@tab-pulse-test-opt' 'fallback')"
  [ "$result" = "hello" ]
}

@test "tab_pulse_interval_seconds defaults to 500ms" {
  [ "$(tab_pulse_interval_seconds)" = "0.500" ]
}

@test "tab_pulse_interval_seconds honors an overridden value" {
  tab_pulse_tmux set-option -g '@tab-pulse-interval' '250'
  [ "$(tab_pulse_interval_seconds)" = "0.250" ]
}

@test "tab_pulse_interval_seconds clamps a too-low value to the 50ms floor" {
  tab_pulse_tmux set-option -g '@tab-pulse-interval' '5'
  [ "$(tab_pulse_interval_seconds)" = "0.050" ]
}

@test "tab_pulse_interval_seconds clamps a non-numeric value to the 50ms floor" {
  # Guards against a busy-loop: awk coerces non-numeric strings to 0.
  tab_pulse_tmux set-option -g '@tab-pulse-interval' 'not-a-number'
  [ "$(tab_pulse_interval_seconds)" = "0.050" ]
}

@test "tab_pulse_idle_interval_seconds defaults to 2s" {
  [ "$(tab_pulse_idle_interval_seconds)" = "2.000" ]
}

@test "tab_pulse_working_stale_seconds defaults to 900" {
  [ "$(tab_pulse_working_stale_seconds)" = "900" ]
}

@test "tab_pulse_working_stale_seconds honors an override" {
  tab_pulse_tmux set-option -g '@tab-pulse-working-stale-seconds' '60'
  [ "$(tab_pulse_working_stale_seconds)" = "60" ]
}

@test "tab_pulse_claude_version_pattern default matches a real Claude Code version string" {
  pattern="$(tab_pulse_claude_version_pattern)"
  [[ "2.1.263" =~ $pattern ]]
  [[ "2.1" =~ $pattern ]]
  [[ "not-a-version" =~ $pattern ]] && exit 1 || true
}

# The test pane's real foreground command is /bin/sh the whole time (this
# harness's own deterministic default shell — see tab_pulse_setup_tmux), and
# "sh" is itself in the default @tab-pulse-shells list. Injecting
# @tab_pulse_state directly onto a pane that's still really just a shell
# would immediately trip the crash-cleanup CLEAR path (a Claude pane that
# carries state but whose command reverted to a shell) and erase the very
# state a test is trying to check — exactly the behavior the LAST test below
# covers on purpose. So every other test here first makes the pane exec a
# real non-shell foreground command before injecting state.

@test "tab_pulse_publish_window: a working pane writes the spinner glyph to @tab_pulse" {
  tab_pulse_tmux send-keys -t "$TEST_PANE" 'exec sleep 300' Enter
  sleep 0.3
  tab_pulse_tmux set-option -p -t "$TEST_PANE" @tab_pulse_state working
  tab_pulse_publish_window "$TEST_WINDOW"
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" == *"$(tab_pulse_spinner_frames | cut -d' ' -f1)"* ]]
}

@test "tab_pulse_publish_window: an attention pane writes the attention glyph to @tab_pulse" {
  tab_pulse_tmux send-keys -t "$TEST_PANE" 'exec sleep 300' Enter
  sleep 0.3
  tab_pulse_tmux set-option -p -t "$TEST_PANE" @tab_pulse_state attention
  tab_pulse_publish_window "$TEST_WINDOW"
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" == *"$(tab_pulse_attention_glyph)"* ]]
}

@test "tab_pulse_publish_window: a done (finished, unseen) pane writes the done glyph" {
  tab_pulse_tmux send-keys -t "$TEST_PANE" 'exec sleep 300' Enter
  sleep 0.3
  tab_pulse_tmux set-option -p -t "$TEST_PANE" @tab_pulse_state done
  tab_pulse_publish_window "$TEST_WINDOW"
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" == *"$(tab_pulse_done_glyph)"* ]]
  # And the state itself must still say "done" — not seen, not cleared.
  [ "$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_state)" = "done" ]
}

@test "tab_pulse_publish_window: a working Claude pane wins over a sibling process pane" {
  tab_pulse_tmux split-window -t test
  panes=($(tab_pulse_tmux list-panes -t test -F '#{pane_id}'))
  tab_pulse_tmux send-keys -t "${panes[0]}" 'exec sleep 300' Enter
  tab_pulse_tmux send-keys -t "${panes[1]}" 'exec sleep 300' Enter
  sleep 0.3
  tab_pulse_tmux set-option -p -t "${panes[0]}" @tab_pulse_state working

  tab_pulse_publish_window "$TEST_WINDOW"
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" == *"$(tab_pulse_spinner_frames | cut -d' ' -f1)"* ]]
}

@test "tab_pulse_publish_window: a real unrelated running process gets the process glyph" {
  tab_pulse_tmux send-keys -t "$TEST_PANE" 'exec sleep 300' Enter
  sleep 0.3
  tab_pulse_publish_window "$TEST_WINDOW"
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" == *"$(tab_pulse_process_glyph)"* ]]
}

@test "tab_pulse_publish_window: a Claude pane that reverted to a plain shell has its stale state cleared" {
  # Same crash self-heal classify.awk covers, exercised through the actual
  # single-window publish path claude-state.sh uses. Here the pane's real
  # command genuinely is a shell (this harness's own default), so injecting
  # "working" onto it and publishing must clear the state immediately rather
  # than show a working glyph for a pane that was never really Claude.
  tab_pulse_tmux set-option -p -t "$TEST_PANE" @tab_pulse_state working
  tab_pulse_publish_window "$TEST_WINDOW"
  state_after="$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_state 2>/dev/null || true)"
  [ -z "$state_after" ]

  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" != *"$(tab_pulse_spinner_frames | cut -d' ' -f1)"* ]]
}
