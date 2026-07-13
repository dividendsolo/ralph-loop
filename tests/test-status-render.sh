#!/bin/bash
# tests/test-status-render.sh - regression for ENG-119 (ralph-loop heartbeat).
#
# Contract: bin/ralph-status <leg> <repo> <outcome> <tier> writes
# ~/ralph-status.json + ~/ralph-status.html. The JSON holds one cell per
# (leg, repo) keyed under legs.<leg>.iterations.<repo> with last_tick, outcome,
# tier. The HTML renders a table where each cell shows leg/repo/last_tick/
# next_tick/outcome/tier. Last writer wins per (leg, repo).
#
# Per LEARNINGS: this test sets up its own isolated fake HOME (no machine paths
# in assertions). Each test case asserts the OBSERVED live outcome (file
# contents, HTML nodes), not source substrings.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Build an isolated fake HOME so ralph-status reads/writes fixtures, not the
# operator's real $HOME. Mirror the layout bin/ralph-status expects.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME"

# bin/ralph-status lives in the repo bin/ dir.
STATUS="$REPO_ROOT/bin/ralph-status"
[ -x "$STATUS" ] || [ -f "$STATUS" ] || fail "bin/ralph-status not found at $STATUS"

# --- helper: assert JSON cell content via jq ---
assert_cell() {
  local json="$1" leg="$2" repo="$3" outcome="$4" tier="$5" file="$6"
  local actual_outcome actual_tier actual_tick
  actual_outcome=$(jq -r --arg l "$leg" --arg r "$repo" '.legs[$l].iterations[$r].outcome' "$file")
  actual_tier=$(jq -r --arg l "$leg" --arg r "$repo" '.legs[$l].iterations[$r].tier' "$file")
  actual_tick=$(jq -r --arg l "$leg" --arg r "$repo" '.legs[$l].iterations[$r].last_tick' "$file")
  [ "$actual_outcome" = "$outcome" ] || fail "outcome: expected '$outcome' got '$actual_outcome' ($leg/$repo)"
  [ "$actual_tier" = "$tier" ] || fail "tier: expected '$tier' got '$actual_tier' ($leg/$repo)"
  [ -n "$actual_tick" ] || fail "last_tick empty ($leg/$repo)"
  [[ "$actual_tick" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || fail "last_tick not ISO 8601: '$actual_tick' ($leg/$repo)"
  echo "OK: $leg/$repo outcome=$outcome tier=$tier tick=$actual_tick"
}

# --- AC 1: first call creates the cell with outcome=ok, tier=0 (Opus 4.8) ---
env -i HOME="$FAKE_HOME" PATH="$PATH" "$STATUS" worker skills ok 0
[ -f "$FAKE_HOME/ralph-status.json" ] || fail "ralph-status.json not written"
[ -f "$FAKE_HOME/ralph-status.html" ] || fail "ralph-status.html not written"
assert_cell "first" worker skills ok 0 "$FAKE_HOME/ralph-status.json"
# Tier 0 maps to "Opus 4.8" in the HTML
grep -q "Opus 4.8" "$FAKE_HOME/ralph-status.html" || fail "HTML missing 'Opus 4.8' for tier 0"
grep -q "skills" "$FAKE_HOME/ralph-status.html" || fail "HTML missing 'skills' repo label"
grep -q "worker" "$FAKE_HOME/ralph-status.html" || fail "HTML missing 'worker' leg label"

# --- AC 2: second call on a different (leg, repo) preserves the first ---
env -i HOME="$FAKE_HOME" PATH="$PATH" "$STATUS" worker docket failed 2
assert_cell "preserve" worker skills ok 0 "$FAKE_HOME/ralph-status.json"
assert_cell "preserve" worker docket failed 2 "$FAKE_HOME/ralph-status.json"
# Tier 2 maps to "Hermes/MiniMax-M3"
grep -q "Hermes/MiniMax-M3" "$FAKE_HOME/ralph-status.html" || fail "HTML missing 'Hermes/MiniMax-M3' for tier 2"
# Both repos appear in the HTML
[ "$(grep -c '>skills<' "$FAKE_HOME/ralph-status.html")" -ge 1 ] || fail "HTML missing skills cell"
[ "$(grep -c '>docket<' "$FAKE_HOME/ralph-status.html")" -ge 1 ] || fail "HTML missing docket cell"

# --- AC 3: outcome=no_tickets and no_prs render as idle (gray), not error ---
env -i HOME="$FAKE_HOME" PATH="$PATH" "$STATUS" reviewer rep-sheet no_tickets 0
assert_cell "no_tickets" reviewer rep-sheet no_tickets 0 "$FAKE_HOME/ralph-status.json"
grep -q "no tickets" "$FAKE_HOME/ralph-status.html" || fail "HTML missing 'no tickets' text"
# Idle outcomes use the gray color (#5f6368) on the outcome cell.
idle_style=$(grep '>no tickets<' "$FAKE_HOME/ralph-status.html" | grep -oE 'color:#[0-9a-fA-F]+' | head -1)
[ "$idle_style" = "color:#5f6368" ] || fail "idle outcome color: expected #5f6368 got '$idle_style'"
env -i HOME="$FAKE_HOME" PATH="$PATH" "$STATUS" reviewer docket no_prs 0
assert_cell "no_prs" reviewer docket no_prs 0 "$FAKE_HOME/ralph-status.json"
grep -q "no PRs" "$FAKE_HOME/ralph-status.html" || fail "HTML missing 'no PRs' text"

# --- AC 4: failed outcome renders red ---
env -i HOME="$FAKE_HOME" PATH="$PATH" "$STATUS" worker skills failed 2
assert_cell "failed" worker skills failed 2 "$FAKE_HOME/ralph-status.json"
failed_style=$(grep '>failed<' "$FAKE_HOME/ralph-status.html" | grep -oE 'color:#[0-9a-fA-F]+' | head -1)
[ "$failed_style" = "color:#c5221f" ] || fail "failed outcome color: expected #c5221f got '$failed_style'"

# --- AC 5: tier 1 maps to "Sonnet 5" ---
env -i HOME="$FAKE_HOME" PATH="$PATH" "$STATUS" reviewer docket ok 1
assert_cell "tier1" reviewer docket ok 1 "$FAKE_HOME/ralph-status.json"
grep -q "Sonnet 5" "$FAKE_HOME/ralph-status.html" || fail "HTML missing 'Sonnet 5' for tier 1"

# --- AC 6: HTML auto-refreshes every 60s ---
grep -q 'http-equiv="refresh"' "$FAKE_HOME/ralph-status.html" || fail "HTML missing meta refresh"
grep -q 'content="60"' "$FAKE_HOME/ralph-status.html" || fail "HTML refresh interval != 60s"

# --- AC 7: HTML page title ---
grep -q "<title>ralph-loop heartbeat</title>" "$FAKE_HOME/ralph-status.html" || fail "HTML page title != 'ralph-loop heartbeat'"

# --- AC 8: next_tick is computable as last_tick + 5 minutes (informational) ---
# We don't render a static next_tick per call (it changes between renders),
# but the JSON should be parseable and have last_tick populated for every cell.
env -i HOME="$FAKE_HOME" PATH="$PATH" "$STATUS" worker rep-sheet ok 0
env -i HOME="$FAKE_HOME" PATH="$PATH" "$STATUS" reviewer skills ok 0
for leg in worker reviewer; do
  for repo in skills docket rep-sheet; do
    cell=$(jq -c --arg l "$leg" --arg r "$repo" '.legs[$l].iterations[$r] // empty' "$FAKE_HOME/ralph-status.json")
    [ -n "$cell" ] || fail "missing cell for $leg/$repo"
  done
done

echo "PASS: ralph-status writes JSON + HTML, preserves cells, maps tier and outcomes correctly"
