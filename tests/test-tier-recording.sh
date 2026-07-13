#!/bin/bash
# tests/test-tier-recording.sh - regression for ENG-119 (ralph-loop heartbeat).
#
# Contract: bin/ralph-dispatch's dispatch_role records the active tier index in
# ~/.<loop>-rate-limited on every invocation. 0 = primary (Opus 4.8), 2 =
# Hermes/MiniMax-M3 fallback. The renderer (bin/ralph-status) reads this file
# to surface the current tier on the heartbeat page. Empty / missing file
# defaults to tier 0.
#
# Per LEARNINGS: asserts live outcome (state file contents) under an isolated
# fake HOME; no machine paths.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Stub CLI runners so we can run dispatch_role without invoking the real hermes
# or claude binaries (which may not exist or may hit rate limits). The stub
# returns empty stdout and exit 0.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME/.local/bin"
cat > "$FAKE_HOME/.local/bin/hermes" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$FAKE_HOME/.local/bin/claude" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$FAKE_HOME/.local/bin/hermes" "$FAKE_HOME/.local/bin/claude"

# Source the dispatcher into a fresh shell.
DISPATCH="$REPO_ROOT/bin/ralph-dispatch"
[ -f "$DISPATCH" ] || fail "bin/ralph-dispatch not found at $DISPATCH"

assert_tier() {
  local state_file="$1" expected="$2" label="$3"
  if [ -f "$state_file" ]; then
    local actual
    actual=$(cat "$state_file")
    [ "$actual" = "$expected" ] || fail "$label: state file holds '$actual', expected '$expected'"
  else
    fail "$label: state file missing (expected '$expected')"
  fi
  echo "OK: $label -> tier $expected"
}

# --- AC 1: primary dispatch writes tier 0 to state file ---
rm -f "$FAKE_HOME/.work-rate-limited" "$FAKE_HOME/.review-rate-limited"
(
  set -uo pipefail
  HOME="$FAKE_HOME"
  PATH="$FAKE_HOME/.local/bin:$PATH"
  RALPH_LOOP_NAME=work
  RALPH_LOG=/dev/null
  . "$DISPATCH"
  dispatch_role engineer "test prompt 1"
  # After primary, the function should have written tier 0
  assert_tier "$FAKE_HOME/.work-rate-limited" "0" "engineer primary"
  [ -n "${RALPH_DISPATCH_TIER:-}" ] || fail "RALPH_DISPATCH_TIER not exported after primary"
  [ "$RALPH_DISPATCH_TIER" = "0" ] || fail "RALPH_DISPATCH_TIER=$RALPH_DISPATCH_TIER expected 0"
  [ "$RALPH_DISPATCH_TIER_NAME" = "Opus 4.8" ] || fail "RALPH_DISPATCH_TIER_NAME=$RALPH_DISPATCH_TIER_NAME expected 'Opus 4.8'"
)

# --- AC 2: forced fallback writes tier 2 ---
rm -f "$FAKE_HOME/.work-rate-limited"
(
  set -uo pipefail
  HOME="$FAKE_HOME"
  PATH="$FAKE_HOME/.local/bin:$PATH"
  RALPH_LOOP_NAME=work
  RALPH_LOG=/dev/null
  RALPH_FORCE_FALLBACK=1
  . "$DISPATCH"
  dispatch_role engineer "test prompt 2"
  assert_tier "$FAKE_HOME/.work-rate-limited" "2" "engineer forced fallback"
  [ "$RALPH_DISPATCH_TIER" = "2" ] || fail "RALPH_DISPATCH_TIER=$RALPH_DISPATCH_TIER expected 2"
  [ "$RALPH_DISPATCH_TIER_NAME" = "Hermes/MiniMax-M3" ] || fail "expected tier name 'Hermes/MiniMax-M3'"
)

# --- AC 3: state file present (from a prior tick) -> skip primary, write tier 2 ---
rm -f "$FAKE_HOME/.review-rate-limited"
(
  set -uo pipefail
  HOME="$FAKE_HOME"
  PATH="$FAKE_HOME/.local/bin:$PATH"
  RALPH_LOOP_NAME=review
  RALPH_LOG=/dev/null
  # Pre-populate the state file to simulate a previous tick detecting the limit
  echo "2" > "$FAKE_HOME/.review-rate-limited"
  . "$DISPATCH"
  dispatch_role reviewer "test prompt 3"
  assert_tier "$FAKE_HOME/.review-rate-limited" "2" "reviewer pre-existing fallback"
  [ "$RALPH_DISPATCH_TIER" = "2" ] || fail "RALPH_DISPATCH_TIER=$RALPH_DISPATCH_TIER expected 2 on existing-state path"
)

echo "PASS: ralph-dispatch records tier in state file (0 primary, 2 fallback)"
