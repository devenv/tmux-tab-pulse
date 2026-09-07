#!/usr/bin/env bash
# Background ticker for tmux-tab-pulse.
#
# One instance runs per tmux server (guarded by a lock directory below). Each
# tick it inspects EVERY pane on the server, classifies each one, aggregates
# per window (highest-priority pane wins — see classify below), writes the
# resulting styled glyph into the window's @tab_pulse option for whichever
# windows actually changed since last tick, and nudges attached clients to
# redraw the status line. tab-pulse.tmux's window-status-format then just
# reads #{@tab_pulse} — a plain format lookup, no per-window subprocess.
#
# Performance note: each `tmux set-option`/`tmux show-option` call forks a
# real tmux client process. On a server with many windows (tens to low
# hundreds — a real long-running tmux server easily gets there), doing that
# once per window per tick blows well past the configured tick interval,
# making the "500ms" spinner look frozen for seconds at a time in practice.
# So: (1) style/glyph strings are fetched ONCE per tick, not once per window,
# and (2) only windows whose fully-styled glyph actually differs from what
# was written last tick get a `set-option` call at all — tracked via a
# small on-disk previous-tick snapshot compared inside the same awk pass
# that does the aggregation, so this costs no extra subprocess.
#
# Deliberately written for bash 3.2 (macOS's stock /bin/bash): no associative
# arrays, no `read -a` reliance beyond what 3.2 supports.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/helpers.sh
. "$SCRIPT_DIR/helpers.sh"

# --- single-instance guard --------------------------------------------------
# `mkdir` is atomic even across processes racing to start at the same time,
# unlike a naive "read pidfile, then write pidfile" check.
#
# Keyed by the tmux SOCKET, not just the user (see tab_pulse_lock_dir): a
# daemon started against one server won't wrongly hold (or lose the race
# for) the lock belonging to a different tmux server run by the same user.
# Its pid file also lets claude-state.sh find and signal this exact daemon
# (see the wake-on-hook handling below).
LOCKDIR="$(tab_pulse_lock_dir)"
STATEFILE="${LOCKDIR%.lock}.state"

acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo "$$" >"$LOCKDIR/pid"
    return 0
  fi

  local existing_pid
  existing_pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [ -z "$existing_pid" ]; then
    # The lock dir exists but its pid file is empty — likely just a narrow
    # window where another process mkdir'd it a moment ago and hasn't
    # written its pid yet. Give it a beat before assuming it's abandoned.
    sleep 0.1
    existing_pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  fi
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    return 1 # another daemon is genuinely running
  fi

  # Stale lock left behind by a daemon that died without cleaning up.
  rm -rf "$LOCKDIR" 2>/dev/null
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo "$$" >"$LOCKDIR/pid"
    return 0
  fi
  return 1
}

if ! acquire_lock; then
  exit 0
fi
cleanup() { rm -rf "$LOCKDIR" "$STATEFILE" "$STATEFILE.new" 2>/dev/null; }
trap cleanup EXIT
# A bare `trap cleanup INT TERM` would run cleanup but NOT stop the script —
# bash resumes after the handler unless it exits explicitly, which would
# delete this daemon's own lock while it kept looping (and let a second
# instance start alongside it). Exiting here fires the EXIT trap too.
trap 'exit 0' INT TERM

# claude-state.sh signals SIGUSR1 (using this daemon's pid, read from the
# lock dir it just wrote above) right after a hook fires, so a fresh turn
# doesn't sit frozen on the hook's one-off instant-push glyph for however
# long is left of a slow idle-cadence sleep — see sleep_interruptible below.
# The handler itself does nothing; the mere delivery of a trapped signal is
# what makes bash's `wait` return early (verified interruptible on bash 3.2).
trap ':' USR1

# sleep(1) run as an external command blocks the whole script and can't be
# interrupted by a trap; running it in the background and blocking on `wait`
# instead lets an incoming SIGUSR1 break out of the sleep immediately.
sleep_interruptible() {
  sleep "$1" &
  local sleep_pid=$!
  wait "$sleep_pid" 2>/dev/null
  kill "$sleep_pid" 2>/dev/null
}

# --- spinner setup -----------------------------------------------------------
# Frames are space-separated (not one contiguous string) so we can split them
# with plain word-splitting regardless of multibyte width/locale support.
read -r -a FRAMES <<<"$(tab_pulse_spinner_frames)"
frame_count=${#FRAMES[@]}
if [ "$frame_count" -eq 0 ]; then
  FRAMES=("*")
  frame_count=1
fi
frame_index=0

: >"$STATEFILE" # start with no prior state — first tick just writes everything

while true; do
  if ! panes="$(tmux list-panes -a -F $'#{window_id}\t#{pane_id}\t#{pane_current_command}\t#{@tab_pulse_state}\t#{@tab_pulse_ts}' 2>/dev/null)"; then
    # tmux server is gone (or unreachable) — nothing left to serve.
    break
  fi

  shells="$(tab_pulse_shells)"
  ignores="$(tab_pulse_ignore_commands)"
  if tab_pulse_process_detection_enabled; then detect=on; else detect=off; fi

  # Fetched ONCE per tick, not once per window — these are global options,
  # identical for every window, so re-querying them per window (as an
  # earlier version of this script did) is pure repeated subprocess cost.
  working_style="$(tab_pulse_working_style)"
  attention_glyph="$(tab_pulse_attention_glyph)"
  attention_style="$(tab_pulse_attention_style)"
  process_glyph="$(tab_pulse_process_glyph)"
  process_style="$(tab_pulse_process_style)"
  idle_glyph="$(tab_pulse_idle_glyph)"
  claude_version_pattern="$(tab_pulse_claude_version_pattern)"
  stale_seconds="$(tab_pulse_working_stale_seconds)"
  now="$(date +%s)"

  # One awk pass does everything: classify each pane, aggregate per window_id
  # -> max-priority pane (higher wins — 5=claude-working, 4=claude-attention,
  # 3=process, 2=claude-idle, 1=idle), build that window's fully-styled
  # glyph, and compare it against the previous tick's snapshot (loaded from
  # STATEFILE) to decide whether it actually needs writing this time. Also
  # flags "CLEAR" panes: ones that still carry a Claude @tab_pulse_state but
  # whose foreground command has reverted to a plain shell — meaning Claude
  # exited without ever firing SessionEnd (e.g. killed, Ctrl-C'd) and left a
  # stale state behind. Those get their pane option unset below so they stop
  # being treated as a Claude pane, and count as idle/process for this tick.
  #
  # Logic lives in classify.awk (see that file for why LC_ALL=C below is
  # load-bearing, not cosmetic) so it can be unit-tested directly — see
  # test/classify.bats — without a live tmux server or daemon loop.
  aggregated="$(printf '%s\n' "$panes" | LC_ALL=C awk -F $'\t' \
    -v shells="$shells" -v ignores="$ignores" -v detect="$detect" \
    -v working_style="$working_style" -v working_frame="${FRAMES[$frame_index]}" \
    -v attention_glyph="$attention_glyph" -v attention_style="$attention_style" \
    -v process_glyph="$process_glyph" -v process_style="$process_style" \
    -v idle_glyph="$idle_glyph" -v statefile="$STATEFILE" -v statefile_new="$STATEFILE.new" \
    -v claude_version_pattern="$claude_version_pattern" \
    -v stale_seconds="$stale_seconds" -v now="$now" \
    -f "$SCRIPT_DIR/classify.awk"
  )"

  any_working=0
  changed=0
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
    CLEAR)
      tmux set-option -pu -t "$a" @tab_pulse_state >/dev/null 2>&1
      ;;
    WIN)
      tmux set-option -w -t "$a" @tab_pulse "$b" >/dev/null 2>&1
      changed=1
      ;;
    META)
      [ "$a" = "1" ] && any_working=1
      ;;
    esac
  done <<<"$aggregated"

  mv -f "$STATEFILE.new" "$STATEFILE" 2>/dev/null

  if [ "$changed" -eq 1 ]; then
    tmux refresh-client -S >/dev/null 2>&1
  fi

  frame_index=$(((frame_index + 1) % frame_count))

  if [ "$any_working" -eq 1 ]; then
    sleep_interruptible "$(tab_pulse_interval_seconds)"
  else
    sleep_interruptible "$(tab_pulse_idle_interval_seconds)"
  fi
done

cleanup
