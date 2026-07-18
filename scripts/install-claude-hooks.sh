#!/usr/bin/env bash
# Registers the tmux-tab-pulse Claude Code hooks (../claude-hooks.json) into
# the LIVE Claude Code settings file (~/.claude/settings.json).
#
# Why this exists as a separate step (not auto-run by the tmux plugin): Claude
# Code hook registration lives in JSON config outside tmux's control, and
# merging it needs to be explicit, backed up, and re-runnable — not something
# a tmux plugin should silently do on every reload.
#
# Requires: jq.

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

if grep -qF "$STATE_SCRIPT" "$SETTINGS" 2>/dev/null; then
  echo "tmux-tab-pulse hooks already installed in $SETTINGS — nothing to do."
  echo "(remove the entries referencing $STATE_SCRIPT and re-run to reinstall)"
  exit 0
fi

BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo pretpm)"
cp "$SETTINGS" "$BACKUP"
echo "backed up existing settings to $BACKUP"

RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

sed "s#__CLAUDE_STATE_SCRIPT__#$STATE_SCRIPT#g" "$TEMPLATE" >"$RENDERED"

TMP_OUT="$(mktemp)"
# Append our matcher-entries onto whatever hooks already exist for each event
# (rather than overwriting the whole array), so this plays nicely alongside
# any other hooks the user has configured.
jq --slurpfile new "$RENDERED" '
  (.hooks // {}) as $orig
  | .hooks = (
      reduce ($new[0].hooks | keys[]) as $event (
        $orig;
        .[$event] = (($orig[$event] // []) + $new[0].hooks[$event])
      )
    )
' "$SETTINGS" >"$TMP_OUT"

mv "$TMP_OUT" "$SETTINGS"

echo "installed tmux-tab-pulse hooks into $SETTINGS"
echo "events registered: $(jq -r '.hooks | keys | join(", ")' "$RENDERED")"
