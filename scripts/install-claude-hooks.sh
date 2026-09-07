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
# (SessionStart/UserPromptSubmit/Stop/Notification/SessionEnd/SubagentStart/
# SubagentStop/StopFailure) aren't already present, rather than an
# all-or-nothing check — so if you (or something else) removed just one of
# them, re-running restores only that one instead of reporting "already
# installed" and doing nothing.
#
# Requires: jq (1.6+, for `walk`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
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

# Which of our events need (re-)installing? Not just "missing" — an event
# also needs updating if OUR OWN entries under it don't match the current
# template anymore (this plugin's Stop arg has changed more than once as its
# state model evolved). Comparing our own hook entries (flattened across
# whatever blocks they happen to live in, ignoring matcher/block structure —
# matchers only matter for telling OTHER tools' entries apart, not for
# checking whether OUR OWN args are current) against the template, rather
# than just "does our command appear at all", is what catches that: a stale
# arg value would otherwise pass a command-only check forever and never
# update on reinstall. Not merely "does the script path appear anywhere in
# the file" either — that check could both false-positive on an unrelated
# mention of the path and false-negative on partial removal (e.g.
# hand-deleting just UserPromptSubmit+Stop still said "already installed").
#
# Deliberately NOT `map(select(.hooks[]?.command == $script))` on the whole
# block array: select() over a generator (.hooks[]?) re-emits the WHOLE
# block if ANY of its inner hooks match, so a block mixing our entry with
# another tool's (uncommon, but a real shape jq itself will produce if two
# tools' installers ever both target the same block) would pass through
# untouched either way — verified: querying for `== script` and `!= script`
# on the same mixed block both return the entire block unfiltered. Pulling
# .hooks[]? out to its own generator, one level up, compares individual
# entries instead of whole blocks.
MISSING_JSON="$(jq -n \
  --slurpfile settings "$SETTINGS" \
  --slurpfile new "$RENDERED" \
  --arg script "$STATE_SCRIPT" '
    ($settings[0].hooks // {}) as $orig
    | ($new[0].hooks) as $newhooks
    | [ $newhooks | keys[] as $e
        | ([($orig[$e] // [])[].hooks[]? | select(.command == $script)]) as $ours
        | ([$newhooks[$e][].hooks[]?]) as $wanted
        | select($ours != $wanted)
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

# For each event needing (re-)installing: drop OUR OWN existing entries
# (identified by command, regardless of their args — so a stale arg value
# gets replaced, not left alongside the fresh one) and append the current
# template, on top of whatever hooks already exist there from OTHER tools
# (untouched either way, since the filter only matches our own command).
#
# Filters each block's INNER .hooks array (dropping the block itself only if
# that empties it completely) rather than the outer block array — the same
# select-over-a-generator issue as above meant a block mixing our entry with
# another tool's was kept (or dropped) as one unfiltered unit either way,
# so a mixed block would end up with the STALE version of our entry sitting
# right next to the freshly-appended new one instead of being replaced.
jq \
  --slurpfile new "$RENDERED" \
  --argjson missing "$MISSING_JSON" \
  --arg script "$STATE_SCRIPT" '
    (.hooks // {}) as $orig
    | .hooks = (
        reduce ($missing[]) as $event ($orig;
          .[$event] = (
            (($orig[$event] // [])
              | map(.hooks |= map(select(.command != $script)))
              | map(select(.hooks | length > 0)))
            + $new[0].hooks[$event]
          )
        )
      )
' "$SETTINGS" >"$TMP_OUT"

# Write via redirection (respects the destination file's existing
# permissions/inode) rather than `mv` (a rename only needs write permission
# on the containing directory, so it would silently replace even a
# read-only settings file).
cat "$TMP_OUT" >"$SETTINGS"

echo "installed/updated tmux-tab-pulse hooks in $SETTINGS"
echo "events (re-)installed: $(printf '%s' "$MISSING_JSON" | jq -r 'join(", ")')"
