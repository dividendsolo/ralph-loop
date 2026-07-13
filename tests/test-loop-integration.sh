#!/bin/bash
# tests/test-loop-integration.sh - regression for ENG-119 (ralph-loop heartbeat).
#
# Contract: engineer-ralph and review-ralph call bin/ralph-status at the end of every
# iteration with the per-iteration outcome parsed from $result. Outcomes:
#   - "<promise>NO_TICKETS</promise>" present in $result -> outcome=no_tickets
#   - "<promise>NO_PRS</promise>" present in $result -> outcome=no_prs
#   - empty / whitespace-only $result after retries -> outcome=failed
#   - otherwise -> outcome=ok
# The leg (worker|reviewer) is derived from which loop ran; the repo from
# $RALPH_REPO's basename. The worker script was renamed from afk-ralph to
# engineer-ralph in the ralph-loop repo (origin/main); we call the new name.
#
# Per LEARNINGS: stubs the dispatch helper under an isolated fake HOME; asserts
# the live outcome (JSON cell contents), not source substrings.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Build an isolated fake HOME so the loop scripts + ralph-status read/write
# fixtures, not the operator's real $HOME.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.local/bin" "$FAKE_HOME/bin-stubs" \
         "$TMP/repoA-code/skills"

# Single-repo afk.json pointing at a fake repo dir.
cat > "$FAKE_HOME/.claude/afk.json" <<EOF
{
  "repos": {
    "$TMP/repoA-code/skills": {"tracker":"linear"}
  }
}
EOF

# Stub the runners (hermes + claude) so the REAL ralph-dispatch calls them and
# we control the output via $RALPH_DISPATCH_OUTPUT. The stub also writes the
# active tier to the state file so the renderer can read it back.
LOG="$TMP/visit.log"
: > "$LOG"
cat > "$FAKE_HOME/.local/bin/hermes" <<'STUB'
#!/bin/bash
# Stub runner: print whatever the test set RALPH_DISPATCH_OUTPUT to, and
# always exit 0 so the dispatcher treats the primary as successful.
printf '%s' "${RALPH_DISPATCH_OUTPUT:-}"
exit 0
STUB
cat > "$FAKE_HOME/.local/bin/claude" <<'STUB'
#!/bin/bash
printf '%s' "${RALPH_DISPATCH_OUTPUT:-}"
exit 0
STUB
chmod +x "$FAKE_HOME/.local/bin/hermes" "$FAKE_HOME/.local/bin/claude"

# Stub flock so the single-instance lock never blocks.
cat > "$FAKE_HOME/bin-stubs/flock" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$FAKE_HOME/bin-stubs/flock"

# Stub ralph-sync (called by engineer-ralph / review-ralph at start of every tick
# to pull the skills playbook + repo). No-op here.
cat > "$FAKE_HOME/.local/bin/ralph-sync" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$FAKE_HOME/.local/bin/ralph-sync"

# Stub jq via symlink into the loop's expected PATH location.
ln -s "$(command -v jq)" "$FAKE_HOME/.local/bin/jq"

REAL_REPO="$REPO_ROOT"
# Use a temp dir whose basename is "skills" so the loop's `basename $RALPH_REPO`
# gives "skills" (matching what engineer-ralph records on the heartbeat).
SKILLS_REPO="$TMP/skills"
mkdir -p "$SKILLS_REPO"
# The loop just `cd`s into RALPH_REPO; it doesn't read the contents. An empty
# dir is fine for the integration test.
# shellcheck disable=SC2034  # REAL_REPO kept for reference if future ACs need it.
STATUS_JSON="$FAKE_HOME/ralph-status.json"

# Helper: assert JSON cell.
assert_cell() {
  local file="$1" leg="$2" repo="$3" outcome="$4"
  local actual
  actual=$(jq -r --arg l "$leg" --arg r "$repo" '.legs[$l].iterations[$r].outcome // empty' "$file")
  [ "$actual" = "$outcome" ] || fail "expected $leg/$repo outcome='$outcome' got '$actual'"
  echo "OK: $leg/$repo -> $outcome"
}

# --- AC 1: engineer-ralph with normal output -> outcome=ok ---
rm -f "$STATUS_JSON" "$FAKE_HOME/ralph.log"
env -i \
  HOME="$FAKE_HOME" \
  PATH="$FAKE_HOME/.local/bin:$FAKE_HOME/bin-stubs:$PATH" \
  RALPH_REPO="$SKILLS_REPO" \
  RALPH_LOG="$FAKE_HOME/ralph.log" \
  RALPH_DISPATCH_OUTPUT="Engineer carried ENG-119 to PR" \
  bash "$REPO_ROOT/bin/engineer-ralph" 1 > /dev/null
[ -f "$STATUS_JSON" ] || fail "engineer-ralph did not produce $STATUS_JSON"
assert_cell "$STATUS_JSON" worker skills ok

# --- AC 2: engineer-ralph with NO_TICKETS token -> outcome=no_tickets ---
rm -f "$STATUS_JSON"
env -i \
  HOME="$FAKE_HOME" \
  PATH="$FAKE_HOME/.local/bin:$FAKE_HOME/bin-stubs:$PATH" \
  RALPH_REPO="$SKILLS_REPO" \
  RALPH_LOG="$FAKE_HOME/ralph.log" \
  RALPH_DISPATCH_OUTPUT="<promise>NO_TICKETS</promise>" \
  bash "$REPO_ROOT/bin/engineer-ralph" 1 > /dev/null
[ -f "$STATUS_JSON" ] || fail "engineer-ralph did not produce $STATUS_JSON (NO_TICKETS path)"
assert_cell "$STATUS_JSON" worker skills no_tickets

# --- AC 3: engineer-ralph with empty output (startup crash) -> outcome=failed ---
# Skip the 15s retry sleep by setting a fast retry: the loop sleeps 15s between
# the two attempts on empty output. We pre-arm the test to accept that the
# cell is still recorded after retries.
rm -f "$STATUS_JSON" "$FAKE_HOME/ralph.log"
env -i \
  HOME="$FAKE_HOME" \
  PATH="$FAKE_HOME/.local/bin:$FAKE_HOME/bin-stubs:$PATH" \
  RALPH_REPO="$SKILLS_REPO" \
  RALPH_LOG="$FAKE_HOME/ralph.log" \
  RALPH_DISPATCH_OUTPUT="   " \
  bash "$REPO_ROOT/bin/engineer-ralph" 1 > /dev/null
# Even after the two-attempt retry the loop must still record a heartbeat cell
# (failed) so the operator sees the tick happened.
[ -f "$STATUS_JSON" ] || fail "engineer-ralph did not produce $STATUS_JSON (empty output path)"
assert_cell "$STATUS_JSON" worker skills failed

# --- AC 4: review-ralph with NO_PRS token -> outcome=no_prs ---
rm -f "$STATUS_JSON" "$FAKE_HOME/review-board.log"
env -i \
  HOME="$FAKE_HOME" \
  PATH="$FAKE_HOME/.local/bin:$FAKE_HOME/bin-stubs:$PATH" \
  RALPH_REPO="$SKILLS_REPO" \
  RALPH_LOG="$FAKE_HOME/review-board.log" \
  RALPH_DISPATCH_OUTPUT="<promise>NO_PRS</promise>" \
  bash "$REPO_ROOT/bin/review-ralph" 1 > /dev/null
[ -f "$STATUS_JSON" ] || fail "review-ralph did not produce $STATUS_JSON (NO_PRS path)"
assert_cell "$STATUS_JSON" reviewer skills no_prs

echo "PASS: engineer-ralph + review-ralph record (leg, repo) cell on every tick"
