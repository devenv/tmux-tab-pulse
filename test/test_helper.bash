# Shared setup for bats tests that need a real (isolated) tmux server.
#
# Every tmux-backed test gets its OWN tmux server on a private socket name,
# entirely separate from any tmux server the person running the tests
# happens to have open — tests must never touch a real, in-use session.
#
# scripts/*.sh all invoke the bare `tmux` command (that's what Claude Code's
# real environment provides — there's no way to tell them "use -L this").
# So instead we put a tiny `tmux` shim earlier on PATH, for the duration of
# each test, that always injects `-L "$TAB_PULSE_TEST_SOCKET"` — every script
# under test talks to our private server without knowing it's a test.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# tab_pulse_tmux <args...>
# Talks to this test's private server directly (for assertions).
#
# -f /dev/null is load-bearing, not optional: tmux reads ~/.tmux.conf (and
# /etc/tmux.conf) by default for ANY new server, private socket or not. On
# this machine that file installs tpm and every real plugin — including
# tmux-tab-pulse's OWN real daemon — so without -f a "private, isolated" test
# server would silently run the real daemon.sh against it too, alongside
# whatever the test is trying to check in isolation.
tab_pulse_tmux() {
  command tmux -L "$TAB_PULSE_TEST_SOCKET" -f /dev/null "$@"
}

# Call from a test's `setup()`. Starts a private tmux server with one
# detached session/window/pane and installs the PATH shim, so both the
# test itself (via tab_pulse_tmux) and any script it runs (via bare `tmux`)
# reach the same private server. Sets TEST_PANE / TEST_WINDOW to that pane
# and window's ids.
tab_pulse_setup_tmux() {
  # This test process may itself be running inside a REAL tmux pane (this
  # repo's own dev session included) — in which case $TMUX is already set,
  # pointing at that real server. tab_pulse_lock_dir (helpers.sh) reads $TMUX
  # directly, bypassing the tmux binary — and therefore the PATH shim below
  # — entirely, so a script launched from here would compute its daemon
  # lock key from the REAL server's socket path, not the private test one.
  # Observed in practice: a test daemon.sh silently refused to start at all
  # because it collided with the lock already held by this machine's actual
  # running tab-pulse daemon. Unsetting it here only affects processes
  # spawned from this test forward, never the real outer session.
  unset TMUX

  TAB_PULSE_TEST_SOCKET="tab-pulse-test-$$-${RANDOM}"

  TAB_PULSE_SHIM_DIR="$(mktemp -d)"
  cat >"$TAB_PULSE_SHIM_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec $(command -v tmux) -L "$TAB_PULSE_TEST_SOCKET" -f /dev/null "\$@"
EOF
  chmod +x "$TAB_PULSE_SHIM_DIR/tmux"
  PATH="$TAB_PULSE_SHIM_DIR:$PATH"

  # Force a plain, fast, deterministic shell for every pane on this private
  # server — NOT the real $SHELL. A user's real interactive shell (oh-my-zsh,
  # starship, async prompts, ...) is slow to start and can still be mid-init
  # when a test's `send-keys` arrives, making pane_current_command flaky and
  # timing-dependent. `-g` options need a live server to attach to, so the
  # very first pane names /bin/sh explicitly; setting the defaults right
  # after covers every later split-window/new-window on this server too.
  tab_pulse_tmux new-session -d -s test -x 80 -y 24 /bin/sh
  tab_pulse_tmux set-option -g default-shell /bin/sh
  tab_pulse_tmux set-option -g default-command /bin/sh
  TEST_PANE="$(tab_pulse_tmux display-message -p -t test -F '#{pane_id}')"
  TEST_WINDOW="$(tab_pulse_tmux display-message -p -t test -F '#{window_id}')"
}

# Call from a test's `teardown()`.
tab_pulse_teardown_tmux() {
  tab_pulse_tmux kill-server >/dev/null 2>&1 || true
  rm -rf "${TAB_PULSE_SHIM_DIR:-/nonexistent}"
}
