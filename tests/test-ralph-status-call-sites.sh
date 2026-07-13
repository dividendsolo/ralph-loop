#!/bin/bash
# tests/test-ralph-status-call-sites.sh: assert the loops actually record
# heartbeat cells (leg, repo, outcome) for every (leg, repo) they iterate.
#
# Run: bash tests/test-ralph-status-call-sites.sh
# Per LEARNINGS [ENG-99]: no machine paths; fake HOME + stubbed runners.
# Per LEARNINGS [ENG-120]: assert observable behavior (the JSON after a
# tick), not the loop's source substrings.
#
# This test catches the ENG-162 audit's biggest hole: the live loops never
# actually called record_heartbeat, so the heartbeat page stayed frozen.
#
# PATH strategy: the loops export PATH=$HOME/.local/bin:..., OVERWRITING
# whatever was passed in. So the stubs MUST live under $FAKE_HOME/.local/bin
# to be picked up.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.local/bin" "$FAKE_HOME/.hermes-stubs"
mkdir -p "$TMP/code/skills" "$TMP/code/rep-sheet" "$TMP/code/docket"

# afk.json: three repos registered. Worker scope filter narrows to two.
cat > "$FAKE_HOME/.claude/afk.json" <<EOF
{
  "repos": {
    "$TMP/code/skills":    {"tracker":"linear"},
    "$TMP/code/rep-sheet": {"tracker":"linear"},
    "$TMP/code/docket":    {"tracker":"linear"}
  }
}
EOF

# Recorder must exist (we assert the JSON gets populated after the tick).
[ -x "$REPO_ROOT/bin/ralph-status" ] || \
  fail "bin/ralph-status missing or not executable"

# Stub `hermes` for the WORKER. The worker loop greps for
# <promise>NO_TICKETS</promise> in the agent's output to exit early.
cat > "$FAKE_HOME/.local/bin/hermes" <<'STUB'
#!/bin/bash
echo "<promise>NO_TICKETS</promise>"
STUB
chmod +x "$FAKE_HOME/.local/bin/hermes"

# Stub `flock` so the single-instance lock never blocks.
cat > "$FAKE_HOME/.local/bin/flock" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$FAKE_HOME/.local/bin/flock"

# Need jq real (symlink).
JQ_PATH="$(command -v jq 2>/dev/null || true)"
[ -n "$JQ_PATH" ] || fail "jq not on PATH; install jq first"
ln -s "$JQ_PATH" "$FAKE_HOME/.local/bin/jq"

# Symlink the real ralph-sync (the loop shells out to it before the
# iteration); it skips repos that aren't git checkouts, so the fake
# $TMP/code/skills is fine.
ln -s "$REPO_ROOT/bin/ralph-sync" "$FAKE_HOME/.local/bin/ralph-sync"

# The board cron entrypoints (`engineer-board`, `review-board`) shell out
# to `engineer-ralph` / `review-ralph` by bare name, so they must be on
# PATH for the cron to find them. On the live box they live in
# ~/.local/bin (installed by ./install.sh). In this test we symlink the
# real scripts so the test exercises the actual loop, not a stub.
ln -s "$REPO_ROOT/bin/engineer-ralph" "$FAKE_HOME/.local/bin/engineer-ralph"
ln -s "$REPO_ROOT/bin/review-ralph"   "$FAKE_HOME/.local/bin/review-ralph"

# Run the worker loop for one iteration against the skills stub repo.
HOME="$FAKE_HOME" \
  RALPH_REPO="$TMP/code/skills" \
  RALPH_ITERS=1 \
  bash "$REPO_ROOT/bin/engineer-board" > "$TMP/engineer.out" 2>&1 || true

# Re-stub `hermes` to return NO_PRS for the reviewer loop (the reviewer
# loop greps for <promise>NO_PRS</promise> in the agent's output to exit
# early). The worker stub is gone so the reviewer run sees the right
# token.
cat > "$FAKE_HOME/.local/bin/hermes" <<'STUB'
#!/bin/bash
echo "<promise>NO_PRS</promise>"
STUB
chmod +x "$FAKE_HOME/.local/bin/hermes"

# Run the reviewer loop once.
HOME="$FAKE_HOME" \
  RALPH_REPO="$TMP/code/skills" \
  REVIEW_ITERS=1 \
  bash "$REPO_ROOT/bin/review-board" > "$TMP/reviewer.out" 2>&1 || true

# After both ticks, the heartbeat JSON must exist.
JSON="$FAKE_HOME/ralph-status.json"
[ -f "$JSON" ] || {
  echo "--- engineer-board output ---"
  cat "$TMP/engineer.out"
  echo "--- review-board output ---"
  cat "$TMP/reviewer.out"
  echo "--- end ---"
  fail "ralph-status.json not written by the loops (heartbeat not wired)"
}
jq -e . "$JSON" >/dev/null 2>&1 || fail "ralph-status.json not valid JSON"

echo "--- heartbeat JSON ---"
cat "$JSON"
echo "--- end JSON ---"

# Engineer leg must have a cell for every repo in its scope (skills +
# rep-sheet). Docket is out of scope.
for cell in skills rep-sheet; do
  jq -e ".cells.engineer[\"$cell\"]" "$JSON" >/dev/null 2>&1 || \
    fail "engineer cell '$cell' missing from heartbeat JSON (loop did not record)"
done
if jq -e '.cells.engineer.docket' "$JSON" >/dev/null 2>&1; then
  fail "engineer recorded a cell for 'docket', but worker scope is skills + rep-sheet only"
fi

# Reviewer leg must have a cell for every repo in afk.json.
for cell in skills rep-sheet docket; do
  jq -e ".cells.reviewer[\"$cell\"]" "$JSON" >/dev/null 2>&1 || \
    fail "reviewer cell '$cell' missing from heartbeat JSON (loop did not record)"
done

# Every recorded cell must carry last_tick + next_tick + outcome + tier +
# repo_path.
for leg in engineer reviewer; do
  for cell in $(jq -r ".cells[\"$leg\"] | keys[]" "$JSON"); do
    keys=$(jq -r ".cells[\"$leg\"][\"$cell\"] | keys_unsorted | join(\",\")" "$JSON")
    for k in last_tick next_tick outcome tier repo_path; do
      echo ",$keys," | grep -q ",$k," || \
        fail "cell $leg/$cell missing key '$k' (got: $keys)"
    done
  done
done

# Every recorded cell must carry a valid outcome. The stub hermes returns
# NO_TICKETS, so every cell should be no_tickets (worker) or no_prs
# (reviewer).
for leg in engineer reviewer; do
  for cell in $(jq -r ".cells[\"$leg\"] | keys[]" "$JSON"); do
    outcome=$(jq -r ".cells[\"$leg\"][\"$cell\"].outcome" "$JSON")
    case "$leg:$outcome" in
      engineer:no_tickets|reviewer:no_prs) ;;
      *) fail "cell $leg/$cell outcome='$outcome' (expected engineer=no_tickets or reviewer=no_prs)" ;;
    esac
  done
done

# Tier must be 'Opus 4.8' (no rate-limit state file in this fixture).
for leg in engineer reviewer; do
  for cell in $(jq -r ".cells[\"$leg\"] | keys[]" "$JSON"); do
    tier=$(jq -r ".cells[\"$leg\"][\"$cell\"].tier" "$JSON")
    [ "$tier" = "Opus 4.8" ] || \
      fail "cell $leg/$cell tier='$tier' (expected 'Opus 4.8', no rate-limit cascade in fixture)"
  done
done

echo "PASS: loops record heartbeat cells for every (leg, repo) in their scope"
