#!/usr/bin/env bats
# Unit tests for scripts/classify.awk: pure function of its input rows and
# -v parameters, no tmux server needed. Covers both bugs fixed in this repo
# (undetected pre-hook Claude panes, stuck-working after an interrupt) plus
# the pre-existing aggregation/change-detection behavior.

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
    -v process_glyph="PROC" -v process_style="" \
    -v idle_glyph="IDLE" \
    -v statefile="$STATEFILE" -v statefile_new="$STATEFILE.new" \
    -v claude_version_pattern='^[0-9]+(\.[0-9]+){1,3}$' \
    -v stale_seconds="900" -v now="$NOW" \
    "$@" \
    -f "$SCRIPTS_DIR/classify.awk" <"$input"
}

row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

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

  run_classify_frame() {
    LC_ALL=C awk -F $'\t' \
      -v shells="zsh bash sh fish" -v ignores="nvim vim less" -v detect="on" \
      -v working_style="" -v working_frame="$1" \
      -v attention_glyph="ATTN" -v attention_style="" \
      -v process_glyph="PROC" -v process_style="" -v idle_glyph="IDLE" \
      -v statefile="$STATEFILE" -v statefile_new="$STATEFILE.new" \
      -v claude_version_pattern='^[0-9]+(\.[0-9]+){1,3}$' \
      -v stale_seconds="900" -v now="$NOW" \
      -f "$SCRIPTS_DIR/classify.awk" <"$input"
  }

  out1="$(run_classify_frame "⠴")"
  mv "$STATEFILE.new" "$STATEFILE"
  out2="$(run_classify_frame "⠦")"
  rm -f "$input"

  [[ "$out1" == *$'WIN\t@1\t⠴'* ]]
  # The second, DIFFERENT frame must still be reported as a change.
  [[ "$out2" == *$'WIN\t@1\t⠦'* ]]
}
