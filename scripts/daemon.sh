#!/usr/bin/env bash
# Background ticker for tmux-tab-pulse.
#
# One instance runs per tmux server (guarded by a lock directory below). Each
# tick it inspects EVERY pane on the server, classifies each one, aggregates
# per window (highest-priority pane wins — see classify below), writes the
# resulting styled glyph into the window's @tab_pulse option, and nudges
# attached clients to redraw the status line. tab-pulse.tmux's
# window-status-format then just reads #{@tab_pulse} — a plain format lookup,
# no per-window subprocess.
#
# Deliberately written for bash 3.2 (macOS's stock /bin/bash): no associative
# arrays, no `read -a` reliance beyond what 3.2 supports.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
. "$SCRIPT_DIR/helpers.sh"

# --- single-instance guard --------------------------------------------------
# `mkdir` is atomic even across processes racing to start at the same time,
# unlike a naive "read pidfile, then write pidfile" check.
#
# Keyed by the tmux SOCKET, not just the user: `run-shell -b` inherits $TMUX
# (set by tmux to "socketpath,pid,session"), so a daemon started against one
# server won't wrongly hold (or lose the race for) the lock belonging to a
# different tmux server run by the same user.
socket_path="${TMUX%%,*}"
if [ -z "$socket_path" ]; then
  socket_path="$(tmux display-message -p '#{socket_path}' 2>/dev/null)"
fi
lock_key="$(printf '%s' "${socket_path:-default}" | tr -c 'A-Za-z0-9' '_')"
LOCKDIR="${TMPDIR:-/tmp}/tmux-tab-pulse-$(id -u)-${lock_key}.lock"

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
cleanup() { rm -rf "$LOCKDIR" 2>/dev/null; }
trap cleanup EXIT
# A bare `trap cleanup INT TERM` would run cleanup but NOT stop the script —
# bash resumes after the handler unless it exits explicitly, which would
# delete this daemon's own lock while it kept looping (and let a second
# instance start alongside it). Exiting here fires the EXIT trap too.
trap 'exit 0' INT TERM

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

while true; do
  panes="$(tmux list-panes -a -F $'#{window_id}\t#{pane_id}\t#{pane_current_command}\t#{@tab_pulse_state}' 2>/dev/null)"
  if [ $? -ne 0 ]; then
    # tmux server is gone (or unreachable) — nothing left to serve.
    break
  fi

  shells="$(tab_pulse_shells)"
  ignores="$(tab_pulse_ignore_commands)"
  if tab_pulse_process_detection_enabled; then detect=on; else detect=off; fi

  # Aggregate per window_id -> max priority pane. Done in one awk pass rather
  # than nested bash loops (cheap even with many panes, and bash-3.2-safe
  # since it avoids associative arrays entirely). Also flags "CLEAR" panes:
  # ones that still carry a Claude @tab_pulse_state but whose foreground
  # command has reverted to a plain shell — meaning Claude exited without
  # ever firing SessionEnd (e.g. killed, Ctrl-C'd) and left a stale state
  # behind. Those get their pane option unset below so they stop being
  # treated as a Claude pane, and count as idle/process for this tick.
  aggregated="$(printf '%s\n' "$panes" | awk -F $'\t' -v shells="$shells" -v ignores="$ignores" -v detect="$detect" '
    BEGIN {
      n = split(shells, sh, " ");  for (i = 1; i <= n; i++) is_shell[sh[i]] = 1
      m = split(ignores, ig, " "); for (i = 1; i <= m; i++) is_ignore[ig[i]] = 1
    }
    NF < 3 { next }
    {
      win = $1; paneid = $2; cmd = $3; state = (NF >= 4 ? $4 : "")
      if (state != "" && (cmd in is_shell)) {
        print "CLEAR\t" paneid
        state = ""
      }
      pr = 1
      if (state != "") {
        if (state == "working")        pr = 5
        else if (state == "attention") pr = 4
        else                           pr = 2   # any other/unknown Claude state = claude-idle
      } else if (detect == "on" && !(cmd in is_shell) && !(cmd in is_ignore)) {
        pr = 3
      }
      if (!(win in maxpr) || pr > maxpr[win]) maxpr[win] = pr
    }
    END {
      for (w in maxpr) print "WIN\t" w "\t" maxpr[w]
    }
  ')"

  any_working=0
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
    CLEAR)
      tmux set-option -pu -t "$a" @tab_pulse_state >/dev/null 2>&1
      ;;
    WIN)
      win="$a"
      pr="$b"
      [ -n "$win" ] || continue
      [ "$pr" = "5" ] && any_working=1
      glyph="$(tab_pulse_glyph_for_priority "$pr" "${FRAMES[$frame_index]}")"
      tmux set-option -w -t "$win" @tab_pulse "$glyph" >/dev/null 2>&1
      ;;
    esac
  done <<<"$aggregated"

  tmux refresh-client -S >/dev/null 2>&1

  frame_index=$(((frame_index + 1) % frame_count))

  if [ "$any_working" -eq 1 ]; then
    sleep "$(tab_pulse_interval_seconds)"
  else
    sleep "$(tab_pulse_idle_interval_seconds)"
  fi
done

cleanup
