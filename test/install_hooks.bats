#!/usr/bin/env bats
# Tests for scripts/install-claude-hooks.sh's idempotency claims. No tmux
# needed — this script only touches a settings.json file.

# $BATS_TEST_DIRNAME (not ${BASH_SOURCE[0]}) — bats-core runs a test from a
# COPY of this file in its own tmpdir, so BASH_SOURCE would resolve to that
# copy's location, not this repo.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/install-claude-hooks.sh"
STATE_SCRIPT="$REPO_ROOT/scripts/claude-state.sh"
EVENTS="SessionStart UserPromptSubmit Stop Notification SessionEnd"

setup() {
  SETTINGS_DIR="$(mktemp -d)"
  export CLAUDE_SETTINGS_PATH="$SETTINGS_DIR/settings.json"
}

teardown() {
  rm -rf "$SETTINGS_DIR"
}

@test "requires jq" {
  # Sanity-check the tool the installer itself depends on is actually here —
  # every other test in this file is meaningless if jq silently isn't.
  command -v jq
}

@test "creates settings.json from scratch when none exists" {
  [ ! -e "$CLAUDE_SETTINGS_PATH" ]
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_SETTINGS_PATH" ]
  for event in $EVENTS; do
    jq -e ".hooks[\"$event\"]" "$CLAUDE_SETTINGS_PATH" >/dev/null
  done
}

@test "backs up the existing file before writing" {
  printf '{"hooks":{}}\n' >"$CLAUDE_SETTINGS_PATH"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  backups=("$SETTINGS_DIR"/settings.json.bak.*)
  [ -e "${backups[0]}" ]
}

@test "preserves unrelated existing settings" {
  printf '{"hooks":{},"env":{"SOME_FLAG":"1"}}\n' >"$CLAUDE_SETTINGS_PATH"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.env.SOME_FLAG' "$CLAUDE_SETTINGS_PATH")" = "1" ]
}

@test "preserves an existing unrelated hook on the same event" {
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"some-other-tool"}]}]}}\n' \
    >"$CLAUDE_SETTINGS_PATH"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  # Both the pre-existing entry and our own must be present, not one
  # replacing the other.
  [ "$(jq '[.hooks.Stop[].hooks[].command] | length' "$CLAUDE_SETTINGS_PATH")" -eq 2 ]
  jq -e '[.hooks.Stop[].hooks[].command] | index("some-other-tool")' "$CLAUDE_SETTINGS_PATH" >/dev/null
}

@test "running it twice is a no-op the second time" {
  bash "$INSTALLER" >/dev/null
  before="$(cat "$CLAUDE_SETTINGS_PATH")"
  # The first run above already made one backup (of the freshly-created
  # "{}" placeholder) — count backups before/after the SECOND run rather
  # than checking mere existence, so that pre-existing backup can't mask a
  # spurious extra one this run.
  backups_before=$(ls "$SETTINGS_DIR"/settings.json.bak.* 2>/dev/null | wc -l)

  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
  after="$(cat "$CLAUDE_SETTINGS_PATH")"
  [ "$before" = "$after" ]

  backups_after=$(ls "$SETTINGS_DIR"/settings.json.bak.* 2>/dev/null | wc -l)
  [ "$backups_after" -eq "$backups_before" ]
}

@test "restores only a manually-removed event, not the whole set, on re-run" {
  bash "$INSTALLER" >/dev/null
  # Simulate the user hand-deleting just one event's hook entry.
  jq 'del(.hooks.UserPromptSubmit)' "$CLAUDE_SETTINGS_PATH" >"$CLAUDE_SETTINGS_PATH.tmp"
  mv "$CLAUDE_SETTINGS_PATH.tmp" "$CLAUDE_SETTINGS_PATH"
  jq -e '.hooks.UserPromptSubmit == null' "$CLAUDE_SETTINGS_PATH" >/dev/null

  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UserPromptSubmit"* ]]
  jq -e '.hooks.UserPromptSubmit' "$CLAUDE_SETTINGS_PATH" >/dev/null
  # The events that were NEVER removed must be untouched, not reported as
  # newly installed a second time.
  [[ "$output" != *"Stop, SessionStart"* ]]
}

@test "a stale arg value from an older template version gets replaced, not left alongside the new one" {
  # Regression test: an earlier version of this plugin pushed "idle" on
  # Stop; this one pushes "done". A command-only presence check would call
  # Stop "already installed" forever and never pick up the new arg — seed
  # exactly that stale shape and confirm a re-run corrects it in place.
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s","args":["idle"]}]}]}}\n' \
    "$STATE_SCRIPT" >"$CLAUDE_SETTINGS_PATH"

  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stop"* ]]
  [ "$(jq '[.hooks.Stop[].hooks[] | select(.command == $script)] | length' \
    --arg script "$STATE_SCRIPT" "$CLAUDE_SETTINGS_PATH")" -eq 1 ]
  [ "$(jq -r '.hooks.Stop[].hooks[] | select(.command == $script) | .args[0]' \
    --arg script "$STATE_SCRIPT" "$CLAUDE_SETTINGS_PATH")" = "done" ]
}
