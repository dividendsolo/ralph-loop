#!/bin/bash
# tests/test-board-pre-check.sh - regression for skills#15 (board pre-check).
#
# Contract (mirrors the four acceptance criteria on skills#15):
#   AC1: Idle tick (no cards in watched columns) spawns zero hermes processes
#        and emits a skip log line instead.
#   AC2: A card present in a watched column causes the loop to dispatch the
#        agent exactly as it did before the pre-check existed.
#   AC3: Pre-check failure (auth/network/non-200) surfaces as a red/failed
#        heartbeat, never as a silent skip and never as "empty".
#   AC4: The pre-check itself is pure shell: no hermes, no MCP, no LLM spawn.
#
# Per LEARNINGS:
#   - Isolate HOME; stub `gh` and `curl` so the pre-check exercises its OWN
#     tracker-calling logic without talking to the live GitHub/Linear APIs.
#   - Assert observed outcomes (JSON heartbeat cell, log line presence), not
#     source substrings.
#   - The contract the test names is the ACs the card publishes, not the
#     current implementation detail; if the implementation refactors the
#     mechanism but preserves AC1-4, the assertions still pass.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# Isolated fake HOME. The pre-check, bin/ralph-status, and bin/engineer-board
# all key off $HOME; isolating it here is what keeps the test from poking the
# operator's real board.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.local/bin" "$FAKE_HOME/bin-stubs" \
         "$FAKE_HOME/code/docket-fake" "$FAKE_HOME/code/skills-fake" \
         "$TMP/real-repo"

# A fake afk.json naming two repo directories (one github, one linear). The
# pre-check resolves the repo -> tracker from this file.
cat > "$FAKE_HOME/.claude/afk.json" <<EOF
{
  "repos": {
    "$FAKE_HOME/code/skills-fake": {
      "tracker": "github",
      "github": {"repo": "fake/skills-fake", "project": "Skills"}
    },
    "$FAKE_HOME/code/docket-fake": {
      "tracker": "linear",
      "linear": {"team": "Engineering", "project": "docket"}
    }
  }
}
EOF

# Stub `gh` and `curl` on a directory that gets prepended to PATH for the
# duration of each test. Each stub takes its mode from a marker file under
# $TMP/stub-mode/<name>; that lets a single binary simulate "empty",
# "non-empty", "auth failure", "network failure" without forking per-case
# scripts.
mkdir -p "$TMP/stub-mode"
STUBDIR="$FAKE_HOME/bin-stubs"

make_gh_stub() {
  cat > "$STUBDIR/gh" <<'STUB'
#!/bin/bash
# Stub gh: behavior controlled by $GH_STUB_MODE.
# Modes: empty | non-empty | auth-failure | network-failure
mode="${GH_STUB_MODE:-empty}"
case "$1" in
  auth)
    # gh auth status / gh auth token. The test treats auth-failure as a
    # hard failure of the whole pre-check, so the auth command here only
    # reports healthy in non-failure modes.
    case "$mode" in
      auth-failure|network-failure) echo "auth stub: failing" >&2; exit 1 ;;
      *)                           exit 0 ;;
    esac ;;
  project)
    case "$mode" in
      empty)          echo '[]' ;;
      non-empty)      echo '[{"id":"x","status":"Ready for Agent"}]' ;;
      auth-failure)   echo '{"message":"Bad credentials"}' >&2; exit 1 ;;
      network-failure) echo "connection refused" >&2; exit 1 ;;
    esac ;;
  *)
    echo "gh stub: unsupported subcommand $1" >&2; exit 2 ;;
esac
STUB
  chmod +x "$STUBDIR/gh"
}

make_curl_stub() {
  cat > "$STUBDIR/curl" <<'STUB'
#!/bin/bash
# Stub curl: behavior controlled by $CURL_STUB_MODE.
mode="${CURL_STUB_MODE:-empty}"
case "$mode" in
  empty)          echo '{"data":{"issuesV2":{"nodes":[]}}}' ;;
  non-empty)      echo '{"data":{"issuesV2":{"nodes":[{"id":"abc","title":"x"}]}}}' ;;
  auth-failure)   echo '{"errors":[{"message":"Not authenticated"}]}' >&2; exit 1 ;;
  network-failure) echo "could not resolve host" >&2; exit 1 ;;
esac
STUB
  chmod +x "$STUBDIR/curl"
}

make_hermes_stub() {
  cat > "$STUBDIR/hermes" <<'STUB'
#!/bin/bash
# Marker file: if this stub ever runs, the pre-check failed to gate the agent.
echo "HERMES_SPAWNED_AT $(date -u +%FT%TZ) args: $*" >> "${HERMES_SPAWN_LOG:-/dev/null}"
echo "<promise>NO_TICKETS</promise>"
STUB
  chmod +x "$STUBDIR/hermes"
}

make_gh_stub
make_curl_stub
make_hermes_stub

PRE_CHECK="$REPO_ROOT/bin/pre-check-board"
[ -f "$PRE_CHECK" ] || fail "bin/pre-check-board not found at $PRE_CHECK (RED step assumes implementation exists; run after RED->GREEN)"
[ -x "$PRE_CHECK" ] || fail "bin/pre-check-board is not executable"

# Test environment: stubbed PATH, isolated HOME, marker for hermes-spawn log.
export PATH="$STUBDIR:$PATH"
export HOME="$FAKE_HOME"

# ----------------------------------------------------------------------
# AC1: idle tick (empty watched columns) -> zero hermes spawns, skip log line.
# ----------------------------------------------------------------------
export GH_STUB_MODE=empty
export CURL_STUB_MODE=empty
export HERMES_SPAWN_LOG="$TMP/hermes-spawn.log"

rm -f "$HERMES_SPAWN_LOG"

# Call the pre-check for the GitHub-tracked skills-fake repo, in the
# "engineer" mode (checks Ready for Agent + Changes Requested + In Progress).
set +e
"$PRE_CHECK" engineer "$FAKE_HOME/code/skills-fake" >"$TMP/ac1.out" 2>&1
rc=$?
set -e

if [ -s "$HERMES_SPAWN_LOG" ]; then
  fail "AC1: hermes spawned on idle tick (log: $(cat "$HERMES_SPAWN_LOG"))"
fi
# RC 0 with empty stdout means "empty, skip the agent"; AC1 demands the caller
# receives that signal so it can log a skip line instead of dispatching.
[ "$rc" = "0" ] || fail "AC1: pre-check returned $rc on idle tick (want 0)"
[ ! -s "$TMP/ac1.out" ] || fail "AC1: pre-check produced stdout on idle tick (want silence): $(cat "$TMP/ac1.out")"
pass "AC1: idle tick -> zero hermes spawns, silent skip"

# ----------------------------------------------------------------------
# AC2: card appears -> pre-check exits non-zero (or prints sentinel) so the
# caller proceeds to dispatch the agent exactly as before.
# ----------------------------------------------------------------------
export GH_STUB_MODE=non-empty
set +e
"$PRE_CHECK" engineer "$FAKE_HOME/code/skills-fake" >"$TMP/ac2.out" 2>"$TMP/ac2.err"
rc=$?
set -e

# Either exit non-zero OR a documented sentinel string in stdout: the contract
# is "caller proceeds", however the implementation signals that.
if [ "$rc" = "0" ] && ! grep -q 'WORK_PRESENT\|work-present\|has-work' "$TMP/ac2.out"; then
  fail "AC2: pre-check returned 0 with no work-present sentinel; caller cannot distinguish empty from non-empty"
fi
pass "AC2: non-empty board -> caller can detect work-present and dispatch"

# ----------------------------------------------------------------------
# AC3: pre-check failure (auth / network / non-200) surfaces as
# TRACKER_UNREACHABLE: NOT a silent skip, NOT treated as empty.
# ----------------------------------------------------------------------
export GH_STUB_MODE=auth-failure
set +e
"$PRE_CHECK" engineer "$FAKE_HOME/code/skills-fake" >"$TMP/ac3.out" 2>"$TMP/ac3.err"
rc=$?
set -e

# The contract is: failure is a DISTINCT signal. RC must not be 0 (which would
# look identical to "empty -> skip"), and stderr/stdout must carry a marker so
# the caller's red-state path can fire.
if [ "$rc" = "0" ]; then
  fail "AC3: pre-check returned 0 on auth failure; caller would treat this as 'empty' and silently skip"
fi
if ! grep -qi 'TRACKER_UNREACHABLE\|unreachable\|tracker_unreachable' "$TMP/ac3.out" "$TMP/ac3.err"; then
  fail "AC3: pre-check failed silently; no TRACKER_UNREACHABLE marker in stdout/stderr (out=$(cat "$TMP/ac3.out"), err=$(cat "$TMP/ac3.err"))"
fi
pass "AC3: tracker failure -> distinct signal (not silent skip, not empty)"

# ----------------------------------------------------------------------
# AC4: the pre-check is pure shell/curl/gh. No hermes/MCP/LLM ever spawns
# during a pre-check, regardless of the outcome.
# ----------------------------------------------------------------------
rm -f "$HERMES_SPAWN_LOG"
export GH_STUB_MODE=non-empty
"$PRE_CHECK" engineer "$FAKE_HOME/code/skills-fake" >/dev/null 2>&1 || true
export GH_STUB_MODE=empty
"$PRE_CHECK" engineer "$FAKE_HOME/code/skills-fake" >/dev/null 2>&1 || true
export GH_STUB_MODE=auth-failure
"$PRE_CHECK" engineer "$FAKE_HOME/code/skills-fake" >/dev/null 2>&1 || true

if [ -s "$HERMES_SPAWN_LOG" ]; then
  fail "AC4: hermes spawned during pre-check (log: $(cat "$HERMES_SPAWN_LOG"))"
fi
pass "AC4: pre-check never spawns hermes/MCP/LLM (pure shell)"

# ----------------------------------------------------------------------
# Wired-in integration: bin/engineer-board must consult the pre-check and
# skip the agent entirely when the board is empty. Stub engineer-ralph so
# any spawn is detectable.
# ----------------------------------------------------------------------
# Replace the hermes stub with a louder one for this section.
cat > "$STUBDIR/hermes" <<'STUB'
#!/bin/bash
echo "HERMES_SPAWNED $*" >> "${HERMES_SPAWN_LOG:-/dev/null}"
STUB
chmod +x "$STUBDIR/hermes"

# Stub engineer-ralph itself so any accidental dispatch is observable.
mkdir -p "$STUBDIR-fakebin"
cat > "$STUBDIR-fakebin/engineer-ralph" <<'STUB'
#!/bin/bash
echo "ENGINEER_RALPH_SPAWNED $*" >> "${HERMES_SPAWN_LOG:-/dev/null}"
STUB
chmod +x "$STUBDIR-fakebin/engineer-ralph"

# Re-prepend the fakebin to PATH so engineer-board finds the stub.
export PATH="$STUBDIR-fakebin:$STUBDIR:$PATH"

# Make a minimal fake repo dir for engineer-board's [ -d "$REPO" ] check.
echo "placeholder" > "$FAKE_HOME/code/skills-fake/README.md"

rm -f "$HERMES_SPAWN_LOG"
export GH_STUB_MODE=empty
export RALPH_REPO="$FAKE_HOME/code/skills-fake"
export RALPH_LOG="$TMP/board.log"
export RALPH_ITERS=1

set +e
"$REPO_ROOT/bin/engineer-board" >"$TMP/board.out" 2>&1
rc=$?
set -e

if [ -s "$HERMES_SPAWN_LOG" ]; then
  fail "WIRE: agent spawned on empty board (log: $(cat "$HERMES_SPAWN_LOG"))"
fi
# The board log should record the skip, not an agent run.
grep -q "skipping\|pre-check\|empty\|no work" "$RALPH_LOG" \
  || fail "WIRE: no skip/pre-check/empty line in board log (log: $(cat "$RALPH_LOG"))"
pass "WIRE: engineer-board skipped dispatch on empty board and logged a skip line"

# ----------------------------------------------------------------------
# Wired-in integration, red state: when the pre-check itself fails, the
# heartbeat must record outcome=failed (red), NOT outcome=no_tickets (gray
# idle) and NOT no-op silence.
# ----------------------------------------------------------------------
rm -f "$HERMES_SPAWN_LOG"
export GH_STUB_MODE=auth-failure
# A clean ralph-status.json baseline so we can read the heartbeat cell after.
echo '{"legs":{}}' > "$FAKE_HOME/ralph-status.json"
# Wire fakebin earlier than the real bin path so the loop uses stubs.
"$REPO_ROOT/bin/engineer-board" >"$TMP/board.out" 2>&1 || true

# The heartbeat recorder must have stamped a cell. Assert via the live JSON.
HEARTBEAT="$FAKE_HOME/ralph-status.json"
if [ ! -s "$HEARTBEAT" ]; then
  fail "WIRE-RED: no heartbeat json written (out=$(cat "$TMP/board.out"))"
fi
# The cell must be outcome=failed, not no_tickets.
outcome=$(jq -r '.legs.worker.iterations["skills-fake"].outcome // empty' "$HEARTBEAT")
[ "$outcome" = "failed" ] || fail "WIRE-RED: heartbeat outcome=$outcome, want 'failed' (json=$(cat "$HEARTBEAT"))"
detail=$(jq -r '.legs.worker.iterations["skills-fake"].detail // empty' "$HEARTBEAT")
echo "$detail" | grep -qi 'tracker_unreachable\|unreachable' \
  || fail "WIRE-RED: heartbeat detail does not name the tracker failure: '$detail'"
pass "WIRE-RED: tracker failure recorded as outcome=failed with tracker_unreachable detail"

echo
echo "all board-pre-check assertions passed"