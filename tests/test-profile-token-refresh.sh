#!/bin/bash
# tests/test-profile-token-refresh.sh, assert that bin/refresh-profile-tokens.sh
# iterates each `hermes-<repo>` wrapper on PATH and invokes the per-profile
# token-refresh, logging the per-profile outcome.
#
# Run: bash tests/test-profile-token-refresh.sh
# Asserts shell behavior in an isolated PATH; does NOT touch live hermes or
# real refresh scripts.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/refresh-profile-tokens.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$SCRIPT" ] || fail "missing $SCRIPT (per-profile refresh wrapper this card adds)"

# --- AC: script is non-empty, executable-shape, and lists the three repos ---

[ -s "$SCRIPT" ] || fail "$SCRIPT is empty"

# The script must enumerate the three target profiles: skills, rep-sheet, docket.
for repo in skills rep-sheet docket; do
  grep -qF "$repo" "$SCRIPT" \
    || fail "$SCRIPT does not reference repo '$repo' in its profile list"
done

# --- AC: script sources the resolver so wrapper presence drives iteration ---

grep -qF "lib-profile-resolver.sh" "$SCRIPT" \
  || fail "$SCRIPT does not source the resolver library"

# --- AC: script logs per-profile outcome (skipped when wrapper absent) ---

grep -qF 'TZ=America/New_York' "$SCRIPT" \
  || fail "$SCRIPT does not stamp log lines with Eastern time"

grep -qE "(skipped|no[[:space:]]wrapper|wrapper.*absent|refreshed|ERROR)" "$SCRIPT" \
  || fail "$SCRIPT does not log a per-profile outcome (skipped/refreshed/ERROR)"

# --- AC: script exits non-zero if any profile refresh fails (loud, not silent) ---

grep -qE "exit[[:space:]]+[1-9]" "$SCRIPT" \
  || fail "$SCRIPT never exits non-zero, silent failures defeat ENG-159/ENG-171"

echo "OK: refresh-profile-tokens.sh enumerates the three profiles, sources the resolver, logs per-profile outcome, and exits non-zero on failure"

# --- AC: when NO wrappers are present, the script exits 0 with a single
# informational line and zero refreshes, this is the expected steady state
# until the human post-merge half creates the profiles ---

TMP_HOME="$(mktemp -d)"
TMP_BIN="$(mktemp -d)"
TMP_LOG="$TMP_HOME/refresh.log"

# Keep system utilities (date, mkdir, python3, printf, mktemp) on PATH;
# the script under test needs them. We deliberately do NOT add any
# hermes-* fake wrappers so the resolver returns the bare 'hermes'
# fallback for every repo (the steady-state expectation of this test).
SYSTEM_PATH=""
IFS=':' read -ra parts <<< "$PATH"
for p in "${parts[@]}"; do
  case "$p" in
    /tmp/tmp.*|*/hermes*|*/.local/bin|*/.hermes/*) continue ;;
  esac
  SYSTEM_PATH="${SYSTEM_PATH:+$SYSTEM_PATH:}$p"
done

HOME="$TMP_HOME" PATH="$TMP_BIN:$SYSTEM_PATH" bash "$SCRIPT" >"$TMP_LOG" 2>&1
rc=$?

# Expect a clean exit when nothing was found, the loop is healthy, it just
# has no profiles yet. Per the brief: TRACKER_UNREACHABLE (from the legs, not
# this wrapper) is the safety net for dead per-profile tokens.
[ "$rc" = "0" ] || fail "no-wrapper steady state: expected exit 0, got $rc"

# And the log should make the steady state visible.
grep -qE "(no[[:space:]]+profile|skipped|nothing to refresh|0[[:space:]]+refreshed)" "$TMP_LOG" \
  || fail "no-wrapper steady state: log should show nothing-refreshed message (got: $(cat "$TMP_LOG"))"

rm -rf "$TMP_HOME" "$TMP_BIN"

echo "OK: refresh-profile-tokens.sh exits 0 with an informative log when no wrappers exist"


# --- AC: when a wrapper AND its per-profile token exist, and the refresh
# script honors LINEAR_TOKEN_PATH, the wrapper reports a real per-profile
# refresh and exits 0 ---

TMP_HOME="$(mktemp -d)"
TMP_BIN="$(mktemp -d)"
TMP_LOG="$TMP_HOME/refresh.log"

ln -s /bin/true "$TMP_BIN/hermes-skills"

# Mock refresh-linear-token.py that HONORS LINEAR_TOKEN_PATH: rewrites
# exactly the file it is pointed at (like the real script post-patch).
cat > "$TMP_BIN/refresh-linear-token.py" <<'PYEOF'
#!/usr/bin/env python3
import json, os, time
tok = os.path.expanduser(os.environ.get("LINEAR_TOKEN_PATH") or "~/.hermes/mcp-tokens/linear.json")
os.makedirs(os.path.dirname(tok), exist_ok=True)
with open(tok, "w") as f:
    json.dump({"access_token": "fresh", "refresh_token": "rotated", "t": time.time()}, f)
PYEOF
chmod +x "$TMP_BIN/refresh-linear-token.py"

PER_PROFILE_DIR="$TMP_HOME/.hermes/profiles/skills/mcp-tokens"
mkdir -p "$PER_PROFILE_DIR"
echo '{"access_token":"old","refresh_token":"r"}' > "$PER_PROFILE_DIR/linear.json"

set +e
HOME="$TMP_HOME" PATH="$TMP_BIN:$SYSTEM_PATH" \
  REFRESH_LINEAR_TOKEN_SCRIPT="$TMP_BIN/refresh-linear-token.py" \
  bash "$SCRIPT" >"$TMP_LOG" 2>&1
rc=$?
set -e

[ "$rc" = "0" ] || fail "per-profile happy path: expected exit 0, got $rc (log: $(cat "$TMP_LOG"))"
grep -q "repo='skills' refreshed OK" "$TMP_LOG" \
  || fail "per-profile happy path: no 'refreshed OK' for skills (log: $(cat "$TMP_LOG"))"
grep -q '"access_token": "fresh"' "$PER_PROFILE_DIR/linear.json" \
  || fail "per-profile happy path: per-profile token file was not rewritten"
[ ! -e "$TMP_HOME/.hermes/mcp-tokens/linear.json" ] \
  || fail "per-profile happy path: default token was written although only a per-profile token existed"

rm -rf "$TMP_HOME" "$TMP_BIN"

echo "OK: refresh-profile-tokens.sh genuinely refreshes a per-profile token via LINEAR_TOKEN_PATH"

echo "PASS: per-profile token refresh wrapper"