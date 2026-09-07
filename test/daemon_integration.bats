#!/usr/bin/env bats
# End-to-end tests: the real daemon.sh loop against a real (private, isolated)
# tmux server, driven through claude-state.sh exactly as Claude Code's hooks
# would. Slower and slightly timing-dependent by nature (a real background
# loop) — kept to a handful of cases; the exhaustive classification behavior
# is already covered by classify.bats without any of that timing risk.

load 'test_helper'

setup() {
  tab_pulse_setup_tmux
  source "$SCRIPTS_DIR/helpers.sh"
  # Fast, tight ticks so tests don't need generous sleeps to be reliable.
  tab_pulse_tmux set-option -g '@tab-pulse-interval' '50'
  tab_pulse_tmux set-option -g '@tab-pulse-idle-interval' '100'
  tab_pulse_tmux send-keys -t "$TEST_PANE" 'exec sleep 300' Enter
  sleep 0.3

  DAEMON_LOG="$(mktemp)"
  bash "$SCRIPTS_DIR/daemon.sh" >"$DAEMON_LOG" 2>&1 &
  DAEMON_PID=$!
  # Give it a moment to acquire its lock and start its first tick.
  sleep 0.3
}

teardown() {
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  tab_pulse_teardown_tmux
  rm -f "$DAEMON_LOG"
}

run_claude_state() {
  TMUX_PANE="$TEST_PANE" bash "$SCRIPTS_DIR/claude-state.sh" "$@"
}

@test "the daemon picks up a hook-pushed working state on its own, with no manual publish" {
  run_claude_state working
  # Deliberately don't rely on claude-state.sh's own immediate publish here —
  # unset the option it would have written, so only the daemon's OWN next
  # tick can be what puts the glyph back.
  tab_pulse_tmux set-option -wu -t "$TEST_WINDOW" @tab_pulse
  sleep 0.3
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  # Not pinned to frame 1 specifically — the daemon's own animation may
  # already have advanced past it by the time this checks. Any spinner
  # frame is proof the daemon (not claude-state.sh's one-off push, which we
  # just erased above) is the one that put it there.
  [ -n "$result" ]
  [ "$result" != "$(tab_pulse_idle_glyph)" ]
  [[ "$result" == *"$(tab_pulse_working_style)"* ]]
}

@test "the spinner actually animates across ticks (not frozen on frame one)" {
  run_claude_state working
  sleep 0.2
  frame1="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  sleep 0.3
  frame2="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [ -n "$frame1" ]
  [ -n "$frame2" ]
  [ "$frame1" != "$frame2" ]
}

@test "the daemon reverts to idle shortly after Stop" {
  run_claude_state working
  sleep 0.2
  run_claude_state idle
  sleep 0.3
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" != *"$(tab_pulse_spinner_frames | cut -d' ' -f1)"* ]]
}

@test "the daemon shows done (finished, unseen) after Stop, and keeps it — nobody's attached to see it" {
  run_claude_state working
  sleep 0.2
  run_claude_state done
  sleep 0.3
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" == *"$(tab_pulse_done_glyph)"* ]]
  # It must persist across the daemon's own later ticks too, not just the
  # instant of claude-state.sh's own push — this test's tmux session is
  # never attached, so nothing should ever downgrade it on its own.
  sleep 0.5
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" == *"$(tab_pulse_done_glyph)"* ]]
}

@test "a second daemon on the same socket exits immediately instead of running alongside the first" {
  run timeout 2 bash "$SCRIPTS_DIR/daemon.sh"
  [ "$status" -eq 0 ]
}

@test "the daemon exits on its own once the tmux server it was serving is gone" {
  tab_pulse_tmux kill-server
  # Detection happens on the daemon's own next loop iteration, whose actual
  # cadence is dominated by per-tick option-read overhead (~10-20 tmux
  # subprocess calls, no batching), not the configured interval — so poll
  # rather than pin to one fixed sleep.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$DAEMON_PID" 2>/dev/null || break
    sleep 0.3
  done
  ! kill -0 "$DAEMON_PID" 2>/dev/null
}
