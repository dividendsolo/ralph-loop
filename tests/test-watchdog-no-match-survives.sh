#!/bin/bash
# tests/test-watchdog-no-match-survives.sh: regression for ENG-171.
#
# Bug: bin/ralph-watchdog.sh runs under `set -euo pipefail`. The bare
# assignment `sorted=$(ps aux | grep "hermes -z" | grep -v grep | awk ...)`
# dies when no `hermes -z` is running (grep exits 1 → pipefail propagates →
# `set -e` fires on the assignment). The watchdog then never reaches the
# stale-lock cleanup or the heartbeat echo, even though that is the
# common-path case (hermes only runs briefly during a loop iteration).
#
# Run: bash tests/test-watchdog-no-match-survives.sh
# Asserts end-to-end behavior with `ps` stubbed to force the no-match case,
# NOT source substrings. Per LEARNINGS, observe the live outcome.
#
# Per LEARNINGS [ENG-99]: no machine paths. Uses a temp dir for HOME so the
# script's lock/rate-limit cleanup is exercised against fake paths and the
# real $HOME is never touched.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Build an isolated fake HOME so the script reads/writes lock + rate-limit
# files in a temp dir and the operator's real $HOME is never touched.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME" "$FAKE_HOME/bin-stubs"

# Stub `ps` so it never matches `hermes -z`. Place it FIRST on PATH so the
# script's `ps aux` resolves here and produces no matching lines. This is
# what forces the bug's no-match path deterministically (without stubbing,
# the test could pass "for the wrong reason" if a real hermes -z is live).
cat > "$FAKE_HOME/bin-stubs/ps" <<'STUB'
#!/bin/bash
# Empty ps output: any `grep` against this will exit 1, tripping
# pipefail + set -e in the bare assignment.
exit 0
STUB
chmod +x "$FAKE_HOME/bin-stubs/ps"

# Run the watchdog with ps stubbed. env -i so no parent env leaks (real
# PATH is reset so ps/awk/grep/stat are found, but ps comes from our stub).
# NOTE: capture stdout/stderr and the exit code WITHOUT letting a non-zero
# RC abort the test under `set -e`. We want to assert on the RC, not have
# the test die before the assertion.
set +e
OUT="$(env -i \
  HOME="$FAKE_HOME" \
  PATH="$FAKE_HOME/bin-stubs:/usr/bin:/bin" \
  bash "$REPO_ROOT/bin/ralph-watchdog.sh" 2>&1)"
RC=$?
set -e

# 1. Exit code must be 0 (the bug: dies with exit 1 on no-match).
[ "$RC" -eq 0 ] || fail "watchdog exited with rc=$RC on no-match (bug: dies before heartbeat); output was: $OUT"

# 2. The heartbeat line must appear in the output (the bug: never reaches
#    the final `echo` when the no-match grep kills the script).
echo "$OUT" | grep -q '^[^ ]* watchdog: killed 0 stale session(s), cleared locks$' \
  || fail "watchdog did not emit the heartbeat line on no-match; output was: $OUT"

echo "PASS: watchdog survives the no-match case and writes the heartbeat line"