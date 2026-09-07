#!/usr/bin/env awk -f
# Classifies every tmux pane into a per-window glyph. Extracted from daemon.sh
# so it can be unit-tested directly (see test/classify.bats) without a live
# tmux server or daemon loop.
#
# Invoke as (daemon.sh does exactly this):
#   printf '%s\n' "$panes" | LC_ALL=C awk -F $'\t' -f classify.awk \
#     -v shells="$shells" -v ignores="$ignores" -v detect="$detect" \
#     -v working_style="$working_style" -v working_frame="$frame" \
#     -v attention_glyph="$attention_glyph" -v attention_style="$attention_style" \
#     -v quota_glyph="$quota_glyph" -v quota_style="$quota_style" \
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
# claude_version_pattern's caller must DOUBLE its backslashes (e.g.
# '^[0-9]+(\\.[0-9]+){1,3}$', not '\.') — `awk -v` does its own escape-sequence
# processing on the assigned string before the regex engine ever sees it, so
# a single-escaped `\.` arrives as a bare `.` (a wildcard, matching ANY
# character) and silently over-matches. Verified: the single-escaped form
# let "2x1x263" match. helpers.sh's default already double-escapes.
#
# Input: tab-separated #{window_id} #{pane_id} #{pane_current_command}
# #{@tab_pulse_state} #{@tab_pulse_ts} #{@tab_pulse_agents}
# #{@tab_pulse_agents_ts}, one pane per line (every column past #3 may be
# entirely absent on shorter lines).
#
# Output, one line per event:
#   CLEAR\t<pane_id>          pane's stale @tab_pulse_state/agents should be
#                             unset (crashed/killed Claude — reverted to a
#                             shell, whether or not it had a state pushed:
#                             a pane can carry a nonzero agent count with no
#                             main state at all if SubagentStart fired before
#                             any SessionStart/UserPromptSubmit ever did)
#   WIN\t<window_id>\t<glyph> window's glyph changed since last tick, write it
#   META\t<0|1>               1 if any window is currently claude-working OR
#                             has one or more subagents actively running
# Also rewrites statefile_new with every window's CURRENT glyph (whether or
# not it changed), for next tick's change-detection.
#
# Priority scale (higher wins when aggregating panes within one window):
#   6=claude-quota-error 5=claude-working 4=claude-attention 3=process
#   2=claude-idle 1=idle
# "quota-error" (Claude Code's StopFailure hook, matchers rate_limit /
# billing_error) outranks EVERYTHING, attention included: a turn that ended
# via a rate limit or a billing/spend-cap hit is a more urgent signal than
# "still generating" or "a routine pending question" — you likely need to
# switch models or wait, not just answer a prompt.
#
# A finished turn (Stop) folds into plain claude-idle rather than getting
# its own tier — an earlier version distinguished "finished, unseen" from
# "idle" with its own glyph, auto-clearing the instant an attached client's
# active window matched, which meant switching to the very tab you wanted
# to check made the marker disappear before you'd had a chance to look at
# anything. Simplified back to one idle state entirely rather than fixing
# the clearing trigger.
#
# quota-error and attention are tracked as SEPARATE per-window flags (win-
# quota/winattention below), not folded into the pr/maxpr ladder — a window
# with one pane genuinely working (pr=5) and a SIBLING pane awaiting your
# input would otherwise have maxpr settle on 5, masking the attention pane
# entirely despite attention supposedly being the more urgent signal. The
# subagent counter gets the same independent-flag treatment for the same
# reason: a subagent can be running regardless of what the main pane's own
# state says (working, idle, ...). Precedence among these THREE independent
# signals is quota > attention > agents; only when none of them apply does
# the ordinary pr/maxpr ladder (working > process > idle) decide the glyph.

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
  if ((state != "" || agents > 0) && (cmd in is_shell)) {
    # Claude exited without ever firing SessionEnd (killed, Ctrl-C'd) —
    # whatever subagents it had are gone too, not just its main state. Also
    # reachable with state=="" but agents>0: SubagentStart can fire before
    # any SessionStart/UserPromptSubmit ever does (hooks installed mid-
    # session), leaving a pane with only an agent count and no main state —
    # that pane needs the same crash cleanup once it reverts to a shell. The
    # CLEAR consumer (daemon.sh / tab_pulse_publish_window) unsets all four
    # pane options to match; zeroing state/agents here as well keeps THIS
    # tick's own aggregation consistent with that instead of counting a
    # crashed pane's stale leftovers for the one tick before the unset takes
    # effect.
    print "CLEAR\t" paneid
    state = ""
    agents = 0
  }
  # Self-heal a stuck subagent counter the same way "working" is healed
  # below: if SubagentStop was ever missed (parent turn interrupted, Claude
  # killed mid-subagent, ...), nothing else would ever decrement it.
  if (agents > 0 && agents_stale_seconds > 0 && agents_ts != "" && (now - agents_ts) > agents_stale_seconds) {
    agents = 0
  }
  if (agents > 0) winagents[win] += agents
  if (state == "quota_error")    winquota[win] = 1
  if (state == "attention")      winattention[win] = 1

  pr = 1
  if (state != "") {
    # quota_error and attention are handled entirely via the winquota/
    # winattention flags above, checked ahead of this ladder in END — they
    # fold into the same pr=2 ("claude-idle") bucket here, since maxpr's
    # only remaining job is choosing among working/process/idle for windows
    # where neither flag applies.
    pr = (state == "working") ? 5 : 2
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
    if (w in winquota) {
      glyph = quota_style quota_glyph "#[default]"
    } else if (w in winattention) {
      glyph = attention_style attention_glyph "#[default]"
    } else if (agents > 0) {
      glyph = agent_style agent_glyph agents "#[default]"
      any_working = 1
    } else if (pr == 5) {
      glyph = working_style working_frame "#[default]"
      any_working = 1
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
