#!/usr/bin/env bash
# Registers the tmux-tab-pulse Claude Code hooks (../claude-hooks.json) into
# the LIVE Claude Code settings file (~/.claude/settings.json).
#
# Why this exists as a separate step (not auto-run by the tmux plugin): Claude
# Code hook registration lives in JSON config outside tmux's control, and
# merging it needs to be explicit, backed up, and re-runnable — not something
# a tmux plugin should silently do on every reload.
#
# Idempotent per EVENT: re-running only installs whichever of our events
# (SessionStart/UserPromptSubmit/Stop/Notification/SessionEnd) aren't already
# present, rather than an all-or-nothing check — so if you (or something else)
# removed just one of them, re-running restores only that one instead of
# reporting "already installed" and doing nothing.
#
# Requires: jq (1.6+, for `walk`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_SCRIPT="$SCRIPT_DIR/claude-state.sh"
TEMPLATE="$REPO_DIR/claude-hooks.json"
SETTINGS="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq)" >&2
  exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
  echo "error: hooks template not found at $TEMPLATE" >&2
  exit 1
fi

chmod +x "$STATE_SCRIPT" "$SCRIPT_DIR/daemon.sh" 2>/dev/null || true

mkdir -p "$(dirname "$SETTINGS")"
if [ ! -f "$SETTINGS" ]; then
  echo "{}" >"$SETTINGS"
fi

RENDERED="$(mktemp)"
TMP_OUT="$(mktemp)"
trap 'rm -f "$RENDERED" "$TMP_OUT"' EXIT

# Substitute the placeholder via jq itself (walk + gsub over every string
# leaf) rather than sed — sed's `s#...#...#` delimiter would break if the
# install path ever contained a `#`, and its replacement text would need
# escaping for `&`/backslashes; jq's --arg passes the path as an opaque
# string with none of that risk.
jq --arg script "$STATE_SCRIPT" '
  walk(if type == "string" then gsub("__CLAUDE_STATE_SCRIPT__"; $script) else . end)
' "$TEMPLATE" >"$RENDERED"

# Which of our events are missing from the current settings file? An event
# only counts as "present" if some existing hook entry under that exact key
# already points at our own script — not merely if the script path appears
# anywhere in the file (the old check used a whole-file grep, which could
# both false-positive on an unrelated mention of the path and false-negative
# detect partial removal, e.g. if just UserPromptSubmit+Stop were deleted by
# hand it still said "already installed").
MISSING_JSON="$(jq -n \
  --slurpfile settings "$SETTINGS" \
  --slurpfile new "$RENDERED" \
  --arg script "$STATE_SCRIPT" '
    ($settings[0].hooks // {}) as $orig
    | ($new[0].hooks) as $newhooks
    | [ $newhooks | keys[] as $e
        | select((($orig[$e] // []) | any(.hooks[]?.command == $script)) | not)
        | $e
      ]
')"

if [ "$(printf '%s' "$MISSING_JSON" | jq 'length')" -eq 0 ]; then
  echo "tmux-tab-pulse hooks already installed in $SETTINGS for every event — nothing to do."
  exit 0
fi

BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo pretpm)"
cp "$SETTINGS" "$BACKUP"
echo "backed up existing settings to $BACKUP"

# Append our entries only for the missing events (leaving any event that
# already has our hook untouched, so this never creates duplicates), on top
# of whatever hooks already exist for that event from other sources.
jq \
  --slurpfile new "$RENDERED" \
  --argjson missing "$MISSING_JSON" '
    (.hooks // {}) as $orig
    | .hooks = (
        reduce ($missing[]) as $event ($orig;
          .[$event] = (($orig[$event] // []) + $new[0].hooks[$event])
        )
      )
' "$SETTINGS" >"$TMP_OUT"

# Write via redirection (respects the destination file's existing
# permissions/inode) rather than `mv` (a rename only needs write permission
# on the containing directory, so it would silently replace even a
# read-only settings file).
cat "$TMP_OUT" >"$SETTINGS"

echo "installed tmux-tab-pulse hooks into $SETTINGS"
echo "events newly registered: $(printf '%s' "$MISSING_JSON" | jq -r 'join(", ")')"
