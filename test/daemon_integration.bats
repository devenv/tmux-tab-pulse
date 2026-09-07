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
  # Poll rather than pin to one fixed sleep — real per-tick cost (~10-20
  # tmux subprocess calls, no batching) varies with how many options are
  # configured, so a single fixed window is inherently timing-fragile.
  result=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse 2>/dev/null || true)"
    [ -n "$result" ] && break
  done
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
  frame1="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [ -n "$frame1" ]
  # Poll rather than pin to fixed sleeps: real per-tick cost (~10-20 tmux
  # subprocess calls, no batching) varies with how many options are
  # configured, so a fixed short window is inherently timing-fragile — this
  # only needs to see ANY later frame differ, however many ticks that takes.
  changed=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    frame2="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
    if [ -n "$frame2" ] && [ "$frame2" != "$frame1" ]; then
      changed=1
      break
    fi
  done
  [ "$changed" -eq 1 ]
}

@test "the daemon reverts to idle shortly after Stop" {
  run_claude_state working
  sleep 0.2
  run_claude_state idle
  sleep 0.3
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" != *"$(tab_pulse_spinner_frames | cut -d' ' -f1)"* ]]
}

@test "the real daemon shows the agent-count glyph while a subagent is running, overriding a finished (idle) main state" {
  # End-to-end version of the exact bug reported live: main turn Stopped
  # while a Task-tool subagent is still going.
  run_claude_state working
  sleep 0.2
  run_claude_state idle
  run_claude_state agent_start
  sleep 0.3
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" == *"$(tab_pulse_agent_glyph)1"* ]]
  [[ "$result" != *"$(tab_pulse_idle_glyph)"* ]]

  run_claude_state agent_stop
  sleep 0.3
  result="$(tab_pulse_tmux show-option -w -t "$TEST_WINDOW" -v @tab_pulse)"
  [[ "$result" != *"$(tab_pulse_agent_glyph)"* ]]
}

@test "a second daemon on the same socket exits immediately instead of running alongside the first" {
  # `timeout` is a GNU coreutils command, not present on stock macOS (this
  # repo's own explicit portability target) unless Homebrew coreutils
  # happens to be installed — verified missing here without it. Backgrounded
  # + wait avoids the dependency entirely, and is a strictly stronger
  # assertion too: it confirms THIS SPECIFIC process declined the lock and
  # exited 0, not merely "something exited 0 within 2 seconds" (which would
  # also pass if the process hung for slightly under 2s for an unrelated
  # reason and got killed by the timeout with a coincidental exit code).
  # Not wrapped in `run` — verified `run wait "$pid"` doesn't compose here:
  # a direct `wait` outside `run` correctly returns 0 for a background job
  # that exits within ~1s, but the identical wait, only wrapped in `run`,
  # reports a nonzero status for the same job. bats' `run` isn't a plain
  # function call for job-control purposes.
  bash "$SCRIPTS_DIR/daemon.sh" &
  second_pid=$!
  wait "$second_pid"
  wait_status=$?
  [ "$wait_status" -eq 0 ]
}

@test "the daemon exits on its own once the tmux server it was serving is gone" {
  tab_pulse_tmux kill-server
  # Detection happens on the daemon's own next loop iteration, whose actual
  # cadence is dominated by per-tick option-read overhead (~10-20 tmux
  # subprocess calls, no batching), not the configured interval — so poll
  # rather than pin to one fixed sleep.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$DAEMON_PID" 2>/dev/null || break
    sleep 0.3
  done
  ! kill -0 "$DAEMON_PID" 2>/dev/null
}
