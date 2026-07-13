#!/bin/bash
# tests/test-ralph-status-self-heal.sh: assert that after the dispatcher
# writes the rate-limit state file, the rendered page shows the fallback
# tier (Hermes/MiniMax-M3) for that leg, and that the tier flips back to
# the primary (Opus 4.8) when the state file is cleared.
#
# Run: bash tests/test-ralph-status-self-heal.sh
# Per LEARNINGS [ENG-99]: no machine paths; isolated fake HOME.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME"
mkdir -p "$TMP/code/skills"

cat > "$FAKE_HOME/.claude/afk.json" <<EOF
{"repos":{"$TMP/code/skills":{"tracker":"linear"}}}
EOF

[ -x "$REPO_ROOT/bin/ralph-status" ] || \
  fail "bin/ralph-status missing or not executable"

# State 1: no rate-limit state file. The recorder must default to the
# primary tier for this leg (Opus 4.8) per the dispatcher's behaviour
# when no state file is present.
HOME="$FAKE_HOME" \
  "$REPO_ROOT/bin/ralph-status" record \
    --leg engineer \
    --repo skills \
    --repo-path "$TMP/code/skills" \
    --outcome ok

HOME="$FAKE_HOME" "$REPO_ROOT/bin/ralph-status" render > "$TMP/page1.html"
TIER1=$(jq -r '.cells.engineer.skills.tier' "$FAKE_HOME/ralph-status.json")
[ "$TIER1" = "Opus 4.8" ] || \
  fail "with no state file, tier should default to 'Opus 4.8', got '$TIER1'"

# State 2: simulate a rate-limit cascade. The dispatcher writes
# ~/.work-rate-limited (empty file = fallback active). The loop's
# record_heartbeat call must pick this up and stamp 'Hermes/MiniMax-M3'.
touch "$FAKE_HOME/.work-rate-limited"
HOME="$FAKE_HOME" \
  "$REPO_ROOT/bin/ralph-status" record \
    --leg engineer \
    --repo skills \
    --repo-path "$TMP/code/skills" \
    --outcome ok

HOME="$FAKE_HOME" "$REPO_ROOT/bin/ralph-status" render
TIER2=$(jq -r '.cells.engineer.skills.tier' "$FAKE_HOME/ralph-status.json")
[ "$TIER2" = "Hermes/MiniMax-M3" ] || \
  fail "with state file present, tier should be 'Hermes/MiniMax-M3', got '$TIER2'"
grep -q "Hermes/MiniMax-M3" "$FAKE_HOME/ralph-status.html" || \
  fail "rendered page does not show fallback tier text"

# State 3: rate-limit resets. The loop's `rm -f $HOME/.work-rate-limited`
# at the start of every tick clears the state file; the recorder must
# flip back to the primary tier within the next tick.
rm -f "$FAKE_HOME/.work-rate-limited"
HOME="$FAKE_HOME" \
  "$REPO_ROOT/bin/ralph-status" record \
    --leg engineer \
    --repo skills \
    --repo-path "$TMP/code/skills" \
    --outcome ok

HOME="$FAKE_HOME" "$REPO_ROOT/bin/ralph-status" render >/dev/null
TIER3=$(jq -r '.cells.engineer.skills.tier' "$FAKE_HOME/ralph-status.json")
[ "$TIER3" = "Opus 4.8" ] || \
  fail "after state-file cleared, tier should self-heal to 'Opus 4.8', got '$TIER3'"

echo "PASS: tier cell self-heals between Opus 4.8 and Hermes/MiniMax-M3 based on state file"
