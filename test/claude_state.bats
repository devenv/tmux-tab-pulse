#!/usr/bin/env bats
# Tests for scripts/claude-state.sh — the Claude Code hook receiver — against
# a real (private, isolated) tmux server.

load 'test_helper'

setup() {
  tab_pulse_setup_tmux
  source "$SCRIPTS_DIR/helpers.sh"
  # Give the pane a real non-shell foreground command first (see helpers.bats
  # for why: the harness's own pane runs /bin/sh, which is itself in the
  # default @tab-pulse-shells list, so an unpatched shell pane would trip the
  # crash-cleanup CLEAR path the instant any state is pushed onto it).
  tab_pulse_tmux send-keys -t "$TEST_PANE" 'exec sleep 300' Enter
  sleep 0.3
}

teardown() {
  tab_pulse_teardown_tmux
}

run_claude_state() {
  TMUX_PANE="$TEST_PANE" bash "$SCRIPTS_DIR/claude-state.sh" "$@"
}

@test "pushing 'working' sets @tab_pulse_state and a timestamp on the pane" {
  run run_claude_state working
  [ "$status" -eq 0 ]
  [ "$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_state)" = "working" ]
  ts="$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_ts)"
  [ -n "$ts" ]
  [ "$ts" -gt 0 ]
}

@test "pushing 'working' immediately publishes the spinner glyph on the window" {
  run run_claude_state working
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" == *"$(tab_pulse_spinner_frames | cut -d' ' -f1)"* ]]
}

@test "pushing 'attention' immediately publishes the attention glyph on the window" {
  run run_claude_state attention
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" == *"$(tab_pulse_attention_glyph)"* ]]
}

@test "pushing 'done' (Stop) immediately publishes the done glyph" {
  run run_claude_state done
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" == *"$(tab_pulse_done_glyph)"* ]]
}

@test "pushing 'clear' (SessionEnd) removes both the state and timestamp" {
  run_claude_state working
  run run_claude_state clear
  [ "$status" -eq 0 ]
  state="$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_state 2>/dev/null || true)"
  ts="$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_ts 2>/dev/null || true)"
  [ -z "$state" ]
  [ -z "$ts" ]
}

@test "pushing with no state argument behaves the same as 'clear'" {
  run_claude_state working
  run run_claude_state
  [ "$status" -eq 0 ]
  state="$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_state 2>/dev/null || true)"
  [ -z "$state" ]
}

@test "with no TMUX_PANE set, it exits 0 and touches nothing" {
  # Explicitly unset, not just "don't pass a new value" — bats itself may be
  # running inside a REAL tmux pane (this repo's own dev session included),
  # whose ambient TMUX_PANE would otherwise leak in and point the script at
  # a pane that has nothing to do with this test.
  run env -u TMUX_PANE bash "$SCRIPTS_DIR/claude-state.sh" working
  [ "$status" -eq 0 ]
  # No window option should have been created at all.
  run tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse
  [ "$status" -ne 0 ]
}

@test "agent_start increments the subagent counter without touching the main state" {
  run_claude_state working
  run run_claude_state agent_start
  [ "$status" -eq 0 ]
  [ "$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_agents)" = "1" ]
  # Main state must be untouched by a subagent event.
  [ "$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_state)" = "working" ]
}

@test "agent_start then agent_stop returns the counter to 0" {
  run_claude_state agent_start
  run_claude_state agent_start
  run run_claude_state agent_stop
  [ "$status" -eq 0 ]
  [ "$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_agents)" = "1" ]
  run_claude_state agent_stop
  [ "$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_agents)" = "0" ]
}

@test "an extra agent_stop never drives the counter negative" {
  run run_claude_state agent_stop
  [ "$status" -eq 0 ]
  [ "$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_agents)" = "0" ]
}

@test "a running subagent publishes the agent-count glyph, overriding a stale done state" {
  # Regression test: the exact bug reported live (a session's main turn
  # already Stopped while a Task-tool subagent it spawned is still running).
  run_claude_state done
  run run_claude_state agent_start
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" == *"$(tab_pulse_agent_glyph)1"* ]]
  [[ "$result" != *"$(tab_pulse_done_glyph)"* ]]
}

@test "SessionEnd (clear) resets the subagent counter too" {
  run_claude_state agent_start
  run run_claude_state clear
  [ "$status" -eq 0 ]
  count="$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_agents 2>/dev/null || true)"
  [ -z "$count" ]
}

@test "a second UserPromptSubmit after Stop refreshes the timestamp forward" {
  run_claude_state working
  first_ts="$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_ts)"
  run_claude_state idle
  sleep 1
  run_claude_state working
  second_ts="$(tab_pulse_tmux show-option -p -t "$TEST_PANE" -v @tab_pulse_ts)"
  [ "$second_ts" -gt "$first_ts" ]
}
