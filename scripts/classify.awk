#!/usr/bin/env awk -f
# Classifies every tmux pane into a per-window glyph. Extracted from daemon.sh
# so it can be unit-tested directly (see test/classify.bats) without a live
# tmux server or daemon loop.
#
# Invoke as (daemon.sh does exactly this):
#   printf '%s\n' "$panes" | LC_ALL=C awk -f classify.awk \
#     -v shells="$shells" -v ignores="$ignores" -v detect="$detect" \
#     -v working_style="$working_style" -v working_frame="$frame" \
#     -v attention_glyph="$attention_glyph" -v attention_style="$attention_style" \
#     -v done_glyph="$done_glyph" -v done_style="$done_style" \
#     -v agent_glyph="$agent_glyph" -v agent_style="$agent_style" \
#     -v process_glyph="$process_glyph" -v process_style="$process_style" \
#     -v idle_glyph="$idle_glyph" -v idle_style="$idle_style" \
#     -v statefile="$STATEFILE" -v statefile_new="$STATEFILE.new" \
#     -v claude_version_pattern="$claude_version_pattern" \
#     -v stale_seconds="$stale_seconds" -v agents_stale_seconds="$agents_stale_seconds" \
#     -v now="$now"
#
# LC_ALL=C in that invocation is load-bearing, not cosmetic: macOS's stock
# /usr/bin/awk does locale-aware (collation-based) string comparison under
# en_US.UTF-8, and its collation tables treat EVERY pair of Braille Patterns
# characters (the whole default spinner alphabet) as equal —
# `"⠴" == "⠦"` prints 1. That silently broke change-detection below: the
# very first working glyph got written, but every subsequent frame compared
# "equal" to it and was never written again, freezing the spinner on its
# first frame for the entire turn. Forcing the C locale makes awk compare raw
# bytes instead. This file doesn't set LC_ALL itself — the caller must.
#
# Input: tab-separated #{window_id} #{pane_id} #{pane_current_command}
# #{@tab_pulse_state} #{@tab_pulse_ts} #{@tab_pulse_agents}
# #{@tab_pulse_agents_ts}, one pane per line (every column past #3 may be
# entirely absent on shorter lines).
#
# Output, one line per event:
#   CLEAR\t<pane_id>          pane's stale @tab_pulse_state should be unset
#                             (crashed/killed Claude — reverted to a shell)
#   WIN\t<window_id>\t<glyph> window's glyph changed since last tick, write it
#   META\t<0|1>               1 if any window is currently claude-working OR
#                             has one or more subagents actively running
# Also rewrites statefile_new with every window's CURRENT glyph (whether or
# not it changed), for next tick's change-detection.
#
# Priority scale (higher wins when aggregating panes within one window):
#   5=claude-working 4=claude-attention 3.5=claude-done(unseen) 3=process
#   2=claude-idle 1=idle
# "done" persists until the pane's own next real state change (a fresh
# UserPromptSubmit, or SessionEnd) — NOT cleared just because its window
# happens to be the one currently selected/attached. An earlier version
# auto-downgraded it the instant an attached client's active window matched,
# which meant switching to the very tab you wanted to check made the pause
# marker disappear before you'd actually had a chance to look at anything.
#
# The subagent counter is tracked SEPARATELY, per window (summed across every
# pane in it) rather than folded into this scale: a subagent can be running
# regardless of what the main pane's own state says (working, done, even
# idle), so it isn't "one more rung on the ladder" — it's an independent
# signal that overrides the glyph choice below (but never attention, which
# always wins: a genuine pending question outranks background busywork).

BEGIN {
  n = split(shells, sh, " ");  for (i = 1; i <= n; i++) is_shell[sh[i]] = 1
  m = split(ignores, ig, " "); for (i = 1; i <= m; i++) is_ignore[ig[i]] = 1
  while ((getline line < statefile) > 0) {
    split(line, f, "\t")
    prevglyph[f[1]] = f[2]
  }
  close(statefile)
}
NF < 3 { next }
{
  win = $1; paneid = $2; cmd = $3
  state = (NF >= 4 ? $4 : ""); ts = (NF >= 5 ? $5 : "")
  agents = (NF >= 6 ? $6 + 0 : 0)
  agents_ts = (NF >= 7 ? $7 : "")
  if (state != "" && (cmd in is_shell)) {
    print "CLEAR\t" paneid
    state = ""
  }
  # Self-heal a stuck subagent counter the same way "working" is healed
  # below: if SubagentStop was ever missed (parent turn interrupted, Claude
  # killed mid-subagent, ...), nothing else would ever decrement it.
  if (agents > 0 && agents_stale_seconds > 0 && agents_ts != "" && (now - agents_ts) > agents_stale_seconds) {
    agents = 0
  }
  if (agents > 0) winagents[win] += agents

  pr = 1
  if (state != "") {
    if (state == "working")        pr = 5
    else if (state == "attention") pr = 4
    else if (state == "done")      pr = 3.5
    else pr = 2 # any other/unknown Claude state = claude-idle
    # Self-heal a "working" state that never got a matching Stop — e.g.
    # the user interrupted the turn (Esc/Ctrl-C), which does not fire
    # Stop, so nothing else would ever clear it. Only "working" is
    # subject to this: "attention" can legitimately sit for a long time
    # waiting on a real answer from the user and must not be auto-cleared.
    if (pr == 5 && stale_seconds > 0 && ts != "" && (now - ts) > stale_seconds) {
      pr = 2
    }
  } else if (cmd ~ claude_version_pattern) {
    # Claude Code reports its own version string as pane_current_command
    # (not "claude"), so a pane with no hook-pushed state yet (predates
    # the hooks being installed, or predates its first SessionStart/
    # UserPromptSubmit since) would otherwise be indistinguishable from
    # an arbitrary background process and get the generic process marker.
    pr = 2
  } else if (detect == "on" && !(cmd in is_shell) && !(cmd in is_ignore)) {
    pr = 3
  }
  if (!(win in maxpr) || pr > maxpr[win]) maxpr[win] = pr
}
END {
  for (w in maxpr) {
    pr = maxpr[w]
    agents = (w in winagents) ? winagents[w] : 0
    if (pr == 4) {
      glyph = attention_style attention_glyph "#[default]"
    } else if (agents > 0) {
      glyph = agent_style agent_glyph agents "#[default]"
      any_working = 1
    } else if (pr == 5) {
      glyph = working_style working_frame "#[default]"
      any_working = 1
    } else if (pr == 3.5) {
      glyph = done_style done_glyph "#[default]"
    } else if (pr == 3) {
      glyph = process_style process_glyph "#[default]"
    } else {
      glyph = idle_style idle_glyph "#[default]"
    }
    if (!(w in prevglyph) || prevglyph[w] != glyph) print "WIN\t" w "\t" glyph
    print w "\t" glyph > statefile_new
  }
  close(statefile_new)
  print "META\t" (any_working ? 1 : 0)
}
