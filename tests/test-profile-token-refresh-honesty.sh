#!/bin/bash
# tests/test-profile-token-refresh-honesty.sh, assert that
# bin/refresh-profile-tokens.sh does NOT silently refresh the default token
# when a per-profile token file exists but refresh-linear-token.py does not
# honor the LINEAR_TOKEN_PATH env var.
#
# Background (from the ENG-133 review pass): the wrapper logs
# "refreshing token at <per-profile-path>" then runs refresh-linear-token.py
# with LINEAR_TOKEN_PATH=<per-profile-path>. The python script ignores
# LINEAR_TOKEN_PATH and rewrites its hardcoded TOKENS_DIR/linear.json path.
# On the box, that hardcoded path is ~/.hermes/mcp-tokens/linear.json --
# the DEFAULT profile's token. The wrapper thus silently refreshes the
# default token while the cron log claims a per-profile refresh succeeded.
# That is silent misinformation, the failure mode ENG-159/ENG-171 are
# meant to make loud.
#
# Per the ENG-133 agent brief: "If Hermes only supports interactive login
# per profile (no headless refresh), do NOT fake it: document that
# limitation clearly and make the per-profile TRACKER_UNREACHABLE signal
# the safety net, so a dead profile token shows red instead of idling
# silently." The wrapper must therefore either (a) skip per-profile
# refreshes with a clear "not supported, run `hermes mcp login linear`
# manually" log, or (b) actually refresh per-profile. This test pins the
# (a) behavior: skip with a clear log, do NOT run the python script when
# it cannot honor LINEAR_TOKEN_PATH.
#
# Run: bash tests/test-profile-token-refresh-honesty.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/refresh-profile-tokens.sh"
REPO_LIB="$REPO_ROOT/bin/lib-profile-resolver.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$SCRIPT" ]   || fail "missing $SCRIPT"
[ -f "$REPO_LIB" ] || fail "missing $REPO_LIB"

# Build an isolated HOME + PATH. Provide a fake `hermes-skills` wrapper
# on PATH so the resolver routes the skills iteration to it; leave
# rep-sheet and docket without wrappers so the resolver falls back to
# bare hermes for those (the bug only matters where the wrapper
# actually fires per-profile logic, i.e. the skills iteration).
TMP_HOME="$(mktemp -d)"
TMP_BIN="$(mktemp -d)"
TMP_LOG="$TMP_HOME/refresh.log"

ln -s /bin/true "$TMP_BIN/hermes-skills"

# Build a clean system PATH that does NOT carry a real `hermes-<repo>`,
# so the resolver only ever sees the one fake wrapper above.
SYSTEM_PATH=""
IFS=':' read -ra parts <<< "$PATH"
for p in "${parts[@]}"; do
  case "$p" in
    /tmp/tmp.*|*/hermes*|*/.local/bin|*/.hermes/*) continue ;;
  esac
  SYSTEM_PATH="${SYSTEM_PATH:+$SYSTEM_PATH:}$p"
done

# Mock refresh-linear-token.py: a script that mirrors the real one's
# bug. It writes a sentinel file to its hardcoded TOKENS_DIR/linear.json
# (the default profile's token path) regardless of the LINEAR_TOKEN_PATH
# env var. If the wrapper invokes this mock when a per-profile token
# exists, the wrapper has just refreshed the default token silently --
# the bug.
TMP_BIN_PY="$(mktemp -d)"
cat > "$TMP_BIN_PY/refresh-linear-token.py" <<'PYEOF'
#!/usr/bin/env python3
"""Mock refresh-linear-token.py. Mirrors the real script's bug: ignores
LINEAR_TOKEN_PATH and rewrites its hardcoded TOKENS_DIR/linear.json.
Writes a sentinel so the test can detect the silent default-refresh."""
import json, os, time
TOKENS_DIR = os.path.expanduser("~/.hermes/mcp-tokens")
TOK = os.path.join(TOKENS_DIR, "linear.json")
os.makedirs(TOKENS_DIR, exist_ok=True)
sent = {"sentinel": "default-refresh-fired", "t": time.time(),
        "linear_token_path_env": os.environ.get("LINEAR_TOKEN_PATH", "")}
with open(TOK, "w") as f:
    json.dump(sent, f)
print(f"[mock-refresh] wrote default token at {TOK} (LINEAR_TOKEN_PATH was {os.environ.get('LINEAR_TOKEN_PATH', '<unset>')})", flush=True)
PYEOF
chmod +x "$TMP_BIN_PY/refresh-linear-token.py"

# Seed the fake HOME with a per-profile token file for skills only.
# No default token file. The wrapper, when it sees the per-profile file,
# should NOT call the mock python script (because the mock would write
# the default file, which is the silent-default-refresh bug).
PER_PROFILE_DIR="$TMP_HOME/.hermes/profiles/skills/mcp-tokens"
mkdir -p "$PER_PROFILE_DIR"
PER_PROFILE_PATH="$PER_PROFILE_DIR/linear.json"
echo '{"access_token":"old-per-profile","refresh_token":"r"}' > "$PER_PROFILE_PATH"
PER_PROFILE_BEFORE_MTIME=$(stat -c '%Y' "$PER_PROFILE_PATH")
PER_PROFILE_BEFORE_CONTENT=$(cat "$PER_PROFILE_PATH")

# Pin REFRESH_LINEAR_TOKEN_SCRIPT to our mock so the wrapper resolves
# to it. Combined with PATH so python3 can find it. Then run the
# wrapper and capture the real exit code (no `|| true` masking).
set +e
HOME="$TMP_HOME" PATH="$TMP_BIN_PY:$TMP_BIN:$SYSTEM_PATH" \
  REFRESH_LINEAR_TOKEN_SCRIPT="$TMP_BIN_PY/refresh-linear-token.py" \
  bash "$SCRIPT" >"$TMP_LOG" 2>&1
rc=$?
set -e

DEFAULT_TOKEN="$TMP_HOME/.hermes/mcp-tokens/linear.json"

# ASSERTION 1: the mock must NOT have been called -- no default token
# file should exist. If the wrapper ran the mock while only a
# per-profile token was present, the mock would have written the
# default file, which is exactly the silent-default-refresh bug.
if [ -e "$DEFAULT_TOKEN" ]; then
  fail "wrapper invoked refresh-linear-token.py while only a per-profile token existed; the python script (real or mocked) ignores LINEAR_TOKEN_PATH and would have refreshed the DEFAULT token silently. Log: $(cat "$TMP_LOG")"
fi

# ASSERTION 2: the per-profile token file must be untouched.
PER_PROFILE_AFTER_CONTENT=$(cat "$PER_PROFILE_PATH")
[ "$PER_PROFILE_BEFORE_CONTENT" = "$PER_PROFILE_AFTER_CONTENT" ] \
  || fail "wrapper modified the per-profile token file (fake refresh)"

# ASSERTION 3: the wrapper's log must honestly describe what happened.
# It must NOT print "refreshing token at <per-profile-path>" without
# also naming the limitation. Acceptable phrasings include "skipped",
# "does not honor", "manually", "not supported", or an explicit error
# that names the limitation. A bare "refreshing token at <per-profile>"
# line in the log is the silent-misinformation bug.
if grep -qE "refreshing token at .*profiles/skills/mcp-tokens/linear\.json" "$TMP_LOG"; then
  if ! grep -qE "(skipped|does not (support|honor)|not yet supported|manually|interactively)" "$TMP_LOG"; then
    fail "wrapper logged 'refreshing token at <per-profile-path>' without a 'skipped' / 'does not honor' / 'manually' disclaimer (silent misinformation)"
  fi
fi

# ASSERTION 4: the wrapper must exit non-zero. The brief is explicit:
# loud failure on dead per-profile tokens. Idling at exit 0 is the
# silent-idle bug that ENG-159/ENG-171 are designed to surface as red.
[ "$rc" != "0" ] \
  || fail "wrapper exited 0 when only a per-profile token existed and it could not refresh; loud failure required by the brief (TRACKER_UNREACHABLE safety net)"

rm -rf "$TMP_HOME" "$TMP_BIN" "$TMP_BIN_PY"

echo "OK: refresh-profile-tokens.sh refuses to silently refresh the default when only a per-profile token exists"
echo "PASS: per-profile token refresh honesty"