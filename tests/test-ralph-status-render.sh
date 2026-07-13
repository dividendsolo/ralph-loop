#!/bin/bash
# tests/test-ralph-status-render.sh: assert bin/ralph-status renders a page
# with one row per (leg, repo) cell carrying last tick, next tick, outcome,
# tier, and color cues per the heartbeat card (ENG-119).
#
# Run: bash tests/test-ralph-status-render.sh
# Per LEARNINGS [ENG-99]: no machine paths; an isolated fake HOME is set up so
# the recorder writes artifacts to a temp dir without touching the operator's
# real $HOME/ralph-status.{json,html}.
#
# Asserts behavior (the rendered HTML and JSON), not the recorder's internals:
# - a page titled `ralph-loop heartbeat`
# - one <tr> per (leg, repo) cell actually in scope for that leg
# - each row carries last tick, next tick, outcome, tier
# - color cues: green for ok, red for failed, gray for no tickets / no PRs
# - a 60s meta refresh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME"

# Stub afk.json declaring two repos for the worker, three for the reviewer.
# Worker scope = skills + rep-sheet; reviewer scope = all three.
mkdir -p "$FAKE_HOME/.claude"
cat > "$FAKE_HOME/.claude/afk.json" <<EOF
{
  "repos": {
    "$TMP/code/skills":    {"tracker":"linear"},
    "$TMP/code/rep-sheet": {"tracker":"linear"},
    "$TMP/code/docket":    {"tracker":"linear"}
  }
}
EOF

# Recorder lives at bin/ralph-status. It is the implementation under test.
[ -x "$REPO_ROOT/bin/ralph-status" ] || \
  fail "bin/ralph-status missing or not executable (heartbeat recorder not implemented yet)"

# Drive the recorder for one engineer iteration on the skills repo, ok outcome.
HOME="$FAKE_HOME" \
  "$REPO_ROOT/bin/ralph-status" record \
    --leg engineer \
    --repo skills \
    --repo-path "$TMP/code/skills" \
    --outcome ok \
    --tier "Opus 4.8"

# Drive the recorder for one reviewer iteration on docket, ok outcome.
HOME="$FAKE_HOME" \
  "$REPO_ROOT/bin/ralph-status" record \
    --leg reviewer \
    --repo docket \
    --repo-path "$TMP/code/docket" \
    --outcome ok \
    --tier "Opus 4.8"

# Also record one reviewer iteration on skills (every repo in the
# reviewer's scope).
HOME="$FAKE_HOME" \
  "$REPO_ROOT/bin/ralph-status" record \
    --leg reviewer \
    --repo skills \
    --repo-path "$TMP/code/skills" \
    --outcome ok \
    --tier "Opus 4.8"

# Also record one failed and one idle outcome so the page exercises every
# color cue class (green/red/gray). These land on the reviewer side so the
# page has rows for both reps of every class.
HOME="$FAKE_HOME" \
  "$REPO_ROOT/bin/ralph-status" record \
    --leg reviewer \
    --repo rep-sheet \
    --repo-path "$TMP/code/rep-sheet" \
    --outcome failed \
    --tier "Hermes/MiniMax-M3"
HOME="$FAKE_HOME" \
  "$REPO_ROOT/bin/ralph-status" record \
    --leg engineer \
    --repo rep-sheet \
    --repo-path "$TMP/code/rep-sheet" \
    --outcome no_tickets \
    --tier "Opus 4.8"

# Render the page from the current JSON. The recorder writes
# $HOME/ralph-status.html (canonical, served by systemd); we cat it into
# a temp path so the test doesn't depend on the operator's real $HOME.
HOME="$FAKE_HOME" "$REPO_ROOT/bin/ralph-status" render
HTML="$FAKE_HOME/ralph-status.html"
[ -s "$HTML" ] || fail "render did not write $HTML (recorder did not produce a page)"

grep -q '<title>ralph-loop heartbeat</title>' "$HTML" || \
  fail "page title missing (expected literal 'ralph-loop heartbeat')"

# 60s meta refresh per AC.
grep -q 'http-equiv="refresh"' "$HTML" && grep -q 'content="60"' "$HTML" || \
  fail "page missing 60s meta refresh"

# Each recorded (leg, repo) cell must appear as a row in the rendered table.
for cell in "engineer" "skills" "reviewer" "docket"; do
  grep -qi "$cell" "$HTML" || fail "rendered page missing cell token '$cell'"
done

# Color cue: at least one occurrence of each of green, red, and gray CSS
# classes (the recorder maps ok -> green, failed -> red, no tickets / no PRs
# -> gray).
for color in green red gray; do
  grep -qi "$color" "$HTML" || fail "page missing color cue '$color' (ok/failed/idle)"
done

# JSON artifact must exist and parse; at minimum carries the cells we wrote.
JSON="$FAKE_HOME/ralph-status.json"
[ -f "$JSON" ] || fail "ralph-status.json not written"
jq -e . "$JSON" >/dev/null 2>&1 || fail "ralph-status.json not valid JSON"

# last tick + next tick + outcome + tier keys present per cell. Engineer
# scope = skills + rep-sheet; reviewer scope = every repo in afk.json.
declare -A LEG_CELLS=(
  [engineer]="skills rep-sheet"
  [reviewer]="skills docket rep-sheet"
)
for leg in engineer reviewer; do
  for cell in ${LEG_CELLS[$leg]}; do
    keys=$(jq -r ".cells[\"$leg\"][\"$cell\"] | keys_unsorted | join(\",\")" "$JSON" 2>/dev/null || true)
    for k in last_tick next_tick outcome tier; do
      echo ",$keys," | grep -q ",$k," || \
        fail "JSON cell leg=$leg repo=$cell missing key '$k' (got: $keys)"
    done
  done
done

# Color cue: each outcome renders a <td> with the matching CSS class. We
# assert the class is on a CELL (a <td>), not the CSS rule body, so that
# way the assertion is "the page marks failed cells red", not "the
# stylesheet contains the word 'red'". Idle outcomes (no_tickets /
# no_prs) share the gray class.
grep -E '<td class="green">' "$HTML" >/dev/null || \
  fail "no <td> with class='green' for an 'ok' outcome (color cue broken)"
grep -E '<td class="red">' "$HTML" >/dev/null || \
  fail "no <td> with class='red' for a 'failed' outcome (color cue broken)"
grep -E '<td class="gray">' "$HTML" >/dev/null || \
  fail "no <td> with class='gray' for an idle outcome (color cue broken)"

# next_tick must be exactly last_tick + 5 minutes (cron is */5).
LAST=$(jq -r '.cells.engineer.skills.last_tick' "$JSON")
NEXT=$(jq -r '.cells.engineer.skills.next_tick' "$JSON")
DIFF=$(python3 -c "
from datetime import datetime
l = datetime.fromisoformat('$LAST'.replace('Z','+00:00'))
n = datetime.fromisoformat('$NEXT'.replace('Z','+00:00'))
d = int((n - l).total_seconds())
print(d)
")
[ "$DIFF" = "300" ] || fail "next_tick - last_tick = ${DIFF}s (expected 300s = cron */5)"

echo "PASS: ralph-status renders a page with all cells, color cues, and a 60s refresh"
