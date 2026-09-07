#!/usr/bin/env bats
# Unit tests for scripts/classify.awk: pure function of its input rows and
# -v parameters, no tmux server needed. Covers every bug fixed in this repo
# to date (undetected pre-hook Claude panes, stuck-working after an
# interrupt, the attention/quota-vs-agents priority inversion, the
# awk -v escape-stripping bug in the version pattern, crashed panes with
# only a stale agent count) plus the pre-existing aggregation/change-
# detection behavior.

load 'test_helper'

setup() {
  STATEFILE="$(mktemp)"
  : >"$STATEFILE"
  NOW="$(date +%s)"
}

teardown() {
  rm -f "$STATEFILE" "$STATEFILE.new"
}

# run_classify <input-lines-file> [extra -v args...]
# Invokes classify.awk exactly as daemon.sh does (LC_ALL=C, tab-separated),
# with sane defaults for every glyph/style so assertions can grep for the
# distinctive glyph character rather than a whole styled string.
run_classify() {
  local input="$1"
  shift
  LC_ALL=C awk -F $'\t' \
    -v shells="zsh bash sh fish" \
    -v ignores="nvim vim less" \
    -v detect="on" \
    -v working_style="" -v working_frame="SPIN" \
    -v attention_glyph="ATTN" -v attention_style="" \
    -v quota_glyph="QUOTA" -v quota_style="" \
    -v agent_glyph="AGENTS" -v agent_style="" \
    -v process_glyph="PROC" -v process_style="" \
    -v idle_glyph="IDLE" \
    -v statefile="$STATEFILE" -v statefile_new="$STATEFILE.new" \
    -v claude_version_pattern='^[0-9]+(\\.[0-9]+){1,3}$' \
    -v stale_seconds="900" -v agents_stale_seconds="900" -v now="$NOW" \
    "$@" \
    -f "$SCRIPTS_DIR/classify.awk" <"$input"
}

# row <window> <pane> <cmd> <state> <ts> [agents] [agents_ts]
# The last two default to empty (treated as 0/falsy by classify.awk) when
# omitted, so every pre-existing 5-arg call site stays valid unchanged.
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }

@test "fresh working pane: window glyph is the spinner frame" {
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "working" "$NOW" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'WIN\t@1\tSPIN'* ]]
}

@test "attention pane: window glyph is the attention marker" {
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "attention" "$NOW" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tATTN'* ]]
}

@test "quota_error pane: window glyph is the quota-error marker" {
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "quota_error" "$NOW" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tQUOTA'* ]]
}

@test "quota_error outranks attention, working, and a running subagent" {
  input="$(mktemp)"
  {
    row "@1" "%1" "2.1.263" "quota_error" "$NOW"
    row "@1" "%2" "2.1.263" "attention" "$NOW"
    row "@1" "%3" "2.1.263" "working" "$NOW" "3" "$NOW"
  } >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tQUOTA'* ]]
}

@test "no-hook-state Claude pane (version-string command) classifies as idle, not the process marker" {
  # Regression test: bug #1 (undetected pre-hook Claude pane). Before the
  # fix this showed the generic process marker (PROC), indistinguishable
  # from an arbitrary running command.
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "" "" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tIDLE'* ]]
  [[ "$output" != *PROC* ]]
}

@test "claude_version_pattern's dot is a LITERAL dot, not a wildcard (awk -v escape-stripping regression)" {
  # Regression test: awk -v does its own escape-sequence processing on the
  # assigned string before the regex engine sees it, so a single-escaped
  # \. in the pattern (as passed on the command line) arrives as a bare .
  # (matching ANY character) — verified this let a command shaped like
  # "2x1x263" (dots replaced by any other single character) match and get
  # treated as claude-idle instead of correctly falling through to the
  # process marker. The fix doubles the backslash in every caller
  # (helpers.sh's default, and this test's own -v above).
  input="$(mktemp)"
  row "@1" "%1" "2x1x263" "" "" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tPROC'* ]]
  [[ "$output" != *IDLE* ]]
}

@test "unrelated running command (not version-string-shaped) still gets the process marker" {
  input="$(mktemp)"
  row "@1" "%1" "long-running-build.sh" "" "" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tPROC'* ]]
}

@test "a bare shell pane is idle, not a process" {
  input="$(mktemp)"
  row "@1" "%1" "zsh" "" "" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tIDLE'* ]]
  [[ "$output" != *PROC* ]]
}

@test "an ignored interactive command (vim) is idle, not a process" {
  input="$(mktemp)"
  row "@1" "%1" "vim" "" "" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tIDLE'* ]]
  [[ "$output" != *PROC* ]]
}

@test "the idle glyph is wrapped in its own style, like every other glyph" {
  input="$(mktemp)"
  row "@1" "%1" "zsh" "" "" >"$input"
  run run_classify "$input" -v idle_style="DIM"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tDIMIDLE'* ]]
}

@test "process detection off: an unrelated running command is idle instead of a process" {
  input="$(mktemp)"
  row "@1" "%1" "long-running-build.sh" "" "" >"$input"
  run run_classify "$input" -v detect="off"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tIDLE'* ]]
  [[ "$output" != *PROC* ]]
}

@test "stale working pane (past the threshold) self-heals to idle" {
  # Regression test: bug #2 (stuck spinner after an interrupted turn).
  old_ts=$((NOW - 1000))
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "working" "$old_ts" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tIDLE'* ]]
  [[ "$output" != *SPIN* ]]
}

@test "stale attention pane is NEVER auto-cleared" {
  # A genuinely pending question must not silently disappear just because
  # it's been a while — only "working" gets the staleness self-heal.
  old_ts=$((NOW - 1000))
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "attention" "$old_ts" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tATTN'* ]]
  [[ "$output" != *IDLE* ]]
}

@test "working pane within the staleness threshold stays working" {
  recent_ts=$((NOW - 10))
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "working" "$recent_ts" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tSPIN'* ]]
}

@test "staleness check disabled (stale_seconds=0) never self-heals" {
  old_ts=$((NOW - 1000000))
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "working" "$old_ts" >"$input"
  run run_classify "$input" -v stale_seconds="0"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tSPIN'* ]]
}

@test "a pane that still carries Claude state but reverted to a plain shell is CLEARed" {
  # Self-heal for a Claude process that exited without ever firing
  # SessionEnd (killed, Ctrl-C'd) — the crash-cleanup path, unrelated to the
  # two bugs above but pre-existing behavior this refactor must preserve.
  input="$(mktemp)"
  row "@1" "%1" "zsh" "working" "$NOW" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'CLEAR\t%1'* ]]
  [[ "$output" == *$'WIN\t@1\tIDLE'* ]]
}

@test "a pane with ONLY a stale agent count (no main state) reverted to a shell is also CLEARed" {
  # Regression test: the CLEAR check used to be gated on state != "", so a
  # pane that only ever had SubagentStart fire (no SessionStart/
  # UserPromptSubmit ever set its main state — reachable if the hooks were
  # installed mid-session) never got cleared once it reverted to a shell.
  # Verified before the fix: this exact input showed AGENTS2 forever,
  # correctly self-healing only after the full staleness window.
  input="$(mktemp)"
  row "@1" "%1" "zsh" "" "" "2" "$NOW" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'CLEAR\t%1'* ]]
  [[ "$output" == *$'WIN\t@1\tIDLE'* ]]
  [[ "$output" != *AGENTS* ]]
}

@test "a CLEARed (crashed) pane's leftover agent count doesn't count either" {
  # Regression test: a crashed Claude pane (reverted to a shell) used to
  # still contribute its stale agent count to the window for this tick,
  # since the CLEAR check only blanked `state`, not `agents` — read before
  # the check, added to winagents unconditionally after it.
  input="$(mktemp)"
  row "@1" "%1" "zsh" "working" "$NOW" "2" "$NOW" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'CLEAR\t%1'* ]]
  [[ "$output" == *$'WIN\t@1\tIDLE'* ]]
  [[ "$output" != *AGENTS* ]]
}

@test "highest-priority pane in a window wins: working beats a sibling process pane" {
  input="$(mktemp)"
  {
    row "@1" "%1" "long-running-build.sh" "" ""
    row "@1" "%2" "2.1.263" "working" "$NOW"
  } >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tSPIN'* ]]
}

@test "META reports whether any window is working" {
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "working" "$NOW" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'META\t1'* ]]
}

@test "META reports no working when nothing is" {
  input="$(mktemp)"
  row "@1" "%1" "zsh" "" "" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'META\t0'* ]]
}

@test "unchanged glyph across ticks is not re-emitted as a WIN event" {
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "working" "$NOW" >"$input"

  run run_classify "$input"
  [[ "$output" == *$'WIN\t@1\tSPIN'* ]]
  mv "$STATEFILE.new" "$STATEFILE"

  run run_classify "$input"
  rm -f "$input"
  [[ "$output" != *WIN* ]]
  [[ "$output" == *$'META\t1'* ]]
}

@test "a changed glyph across ticks IS re-emitted as a WIN event" {
  input1="$(mktemp)"
  row "@1" "%1" "2.1.263" "working" "$NOW" >"$input1"
  run run_classify "$input1"
  mv "$STATEFILE.new" "$STATEFILE"

  input2="$(mktemp)"
  row "@1" "%1" "2.1.263" "attention" "$NOW" >"$input2"
  run run_classify "$input2"
  rm -f "$input1" "$input2"
  [[ "$output" == *$'WIN\t@1\tATTN'* ]]
}

@test "a legacy/unrecognized state (e.g. stale 'done' from an older hook config) folds into plain idle" {
  # A finished turn no longer gets its own state — Stop pushes plain "idle"
  # directly (see claude-hooks.json). This just confirms any OTHER unknown
  # state string (a stale hook config from a previous version of this
  # plugin, still installed on some already-running session) degrades
  # gracefully to claude-idle rather than erroring or showing something odd.
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "done" "$NOW" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tIDLE'* ]]
}

@test "a subagent running overrides plain idle too" {
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "idle" "$NOW" "2" "$NOW" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tAGENTS2'* ]]
}

@test "agent counts from multiple panes in one window are summed" {
  input="$(mktemp)"
  {
    row "@1" "%1" "2.1.263" "idle" "$NOW" "1" "$NOW"
    row "@1" "%2" "2.1.263" "idle" "$NOW" "2" "$NOW"
  } >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tAGENTS3'* ]]
}

@test "attention always wins over a running subagent" {
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "attention" "$NOW" "1" "$NOW" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tATTN'* ]]
  [[ "$output" != *AGENTS* ]]
}

@test "attention on one pane wins even when a SIBLING pane is working with agents attached" {
  # Regression test: attention/quota used to be compared only via the
  # window's overall max priority (maxpr), and working(5) > attention(4) in
  # that scale — so a working sibling pane masked an attention pane in the
  # same window entirely, and the agents>0 override (checked before the
  # pr==5 branch) masked it further. Verified before the fix: this exact
  # input rendered AGENTS2, never ATTN. Now tracked as an independent
  # per-window flag, checked ahead of both.
  input="$(mktemp)"
  {
    row "@1" "%1" "2.1.263" "working" "$NOW" "2" "$NOW"
    row "@1" "%2" "2.1.263" "attention" "$NOW"
  } >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tATTN'* ]]
  [[ "$output" != *AGENTS* ]]
  [[ "$output" != *SPIN* ]]
}

@test "quota_error on one pane wins even when a sibling pane has attention and agents" {
  input="$(mktemp)"
  {
    row "@1" "%1" "2.1.263" "quota_error" "$NOW"
    row "@1" "%2" "2.1.263" "attention" "$NOW" "3" "$NOW"
  } >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tQUOTA'* ]]
  [[ "$output" != *ATTN* ]]
  [[ "$output" != *AGENTS* ]]
}

@test "a stale agent count (past the threshold) self-heals to 0" {
  old_ts=$((NOW - 1000))
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "idle" "$NOW" "1" "$old_ts" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" != *AGENTS* ]]
  [[ "$output" == *$'WIN\t@1\tIDLE'* ]]
}

@test "a fresh agent count within the staleness threshold is trusted" {
  recent_ts=$((NOW - 10))
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "idle" "$NOW" "1" "$recent_ts" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'WIN\t@1\tAGENTS1'* ]]
}

@test "META reports working when only a subagent count, no main working state, is active" {
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "idle" "$NOW" "1" "$NOW" >"$input"
  run run_classify "$input"
  rm -f "$input"
  [[ "$output" == *$'META\t1'* ]]
}

@test "the braille spinner alphabet compares correctly under LC_ALL=C (locale-collation regression guard)" {
  # macOS's stock /usr/bin/awk does locale-aware (collation-based) string
  # comparison under en_US.UTF-8, whose collation tables treat EVERY pair of
  # Braille Patterns characters as equal ("⠴" == "⠦" prints 1 there). That
  # silently broke change-detection: the first working glyph got written,
  # every later frame compared "equal" to it, and the spinner froze on frame
  # one for the whole turn. This proves invoking with LC_ALL=C (as daemon.sh
  # does) avoids that even when the ambient locale is UTF-8.
  input="$(mktemp)"
  row "@1" "%1" "2.1.263" "working" "$NOW" >"$input"

  # run_classify already forwards extra args, so overriding just
  # working_frame per call is enough — no need for a second, separately
  # hand-maintained awk invocation that can (and did) drift out of sync
  # with run_classify's own defaults as new -v params were added.
  out1="$(run_classify "$input" -v working_frame="⠴")"
  mv "$STATEFILE.new" "$STATEFILE"
  out2="$(run_classify "$input" -v working_frame="⠦")"
  rm -f "$input"

  [[ "$out1" == *$'WIN\t@1\t⠴'* ]]
  # The second, DIFFERENT frame must still be reported as a change.
  [[ "$out2" == *$'WIN\t@1\t⠦'* ]]
}
