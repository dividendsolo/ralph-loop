#!/bin/bash
# tests/test-heartbeat-session-matcher.sh - regression for skills#49
# (heartbeat: session detection misses per-profile hermes invocations).
#
# Bug: bin/heartbeat_server.py filtered `ps aux` rows with the literal
# substring "hermes -z". Per-profile dispatch routes through a wrapper
# (`hermes-skills`) that execs `hermes -p skills -z`, so the substring
# never matched and the dashboard showed "0 active session(s)" while a
# real engineer session was live.
#
# Fix: extract an is_hermes_session_line(line) matcher that catches both
# the bare `hermes -z ...` shape and the wrapper `hermes -p <repo> -z ...`
# shape, and still excludes defunct + self-grep noise. Use the matcher at
# all three sites in bin/heartbeat_server.py.
#
# Also covered: the page title + heading rename (skills#49 second slice).
#
# Per LEARNINGS: isolated fake HOME, ps stubbed so the test asserts the
# OBSERVED live outcome (served HTML body / matcher return value), not
# source substrings. Live ps is never read; the test is deterministic.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME" "$FAKE_HOME/bin-stubs"

# --- AC1 (matcher unit): three sample cmdlines, assert match/match/no-match ---
# Use the live cmdline shape we observed on the box for skills#49:
#   bare:        "hermes -z <prompt> --yolo --accept-hooks"
#   wrapper:     ".../hermes -p skills -z <prompt> --yolo --accept-hooks"
#   non-hermes:  "/usr/sbin/cron -f"
# Plus the self-grep and defunct exclusions. The matcher is invoked via the
# heartbeat_server module so the import path matches what bin/heartbeat_server.py
# uses in production.
MATCHER_OUT="$(env -i HOME="$FAKE_HOME" PATH="/usr/bin:/bin" REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import sys, os
sys.path.insert(0, os.environ["REPO_ROOT"])
import importlib.util
spec = importlib.util.spec_from_file_location("heartbeat_server", os.path.join(os.environ["REPO_ROOT"], "bin", "heartbeat_server.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Bare hermes -z (no -p). Should match.
bare = "hermes -z Use the engineer skill ... --yolo --accept-hooks"
# Wrapped path: the post-exec cmdline visible in `ps aux` after the per-profile
# wrapper execs the underlying binary. Should match.
wrapped = "/home/div/.hermes/hermes-agent/venv/bin/python3 /home/div/.hermes/hermes-agent/venv/bin/hermes -p skills -z Use the engineer skill ... --yolo --accept-hooks"
# A real non-Hermes process. Must NOT match.
cron = "/usr/sbin/cron -f"
# Self-grep noise: would have matched under the old substring check via "hermes -z" being absent.
grep_self = "div 123 1.0 ps aux | grep hermes -z | grep -v grep"
# A defunct process whose args happen to mention "hermes -z" (rare but cheap).
zombie = "div 124 0.0 [hermes -z] <defunct>"

results = {
    "bare": mod.is_hermes_session_line(bare),
    "wrapped": mod.is_hermes_session_line(wrapped),
    "cron": mod.is_hermes_session_line(cron),
    "grep_self": mod.is_hermes_session_line(grep_self),
    "zombie": mod.is_hermes_session_line(zombie),
}
for k, v in results.items():
    print(f"{k}={v}")
PY
)" || fail "matcher import/eval failed"
echo "matcher results: $MATCHER_OUT"

# Parse results
bare_match=$(echo "$MATCHER_OUT"      | grep -oE '^bare=True'      | head -1 || true)
wrapped_match=$(echo "$MATCHER_OUT"   | grep -oE '^wrapped=True'   | head -1 || true)
cron_match=$(echo "$MATCHER_OUT"      | grep -oE '^cron=False'     | head -1 || true)
grep_match=$(echo "$MATCHER_OUT"      | grep -oE '^grep_self=False' | head -1 || true)
zombie_match=$(echo "$MATCHER_OUT"    | grep -oE '^zombie=False'   | head -1 || true)

[ -n "$bare_match" ]    || fail "bare 'hermes -z ...' must match the matcher (got False)"
[ -n "$wrapped_match" ] || fail "wrapped 'hermes -p skills -z ...' must match the matcher (got False)"
[ -n "$cron_match" ]    || fail "non-hermes process must NOT match the matcher"
[ -n "$grep_match" ]    || fail "self-grep line must NOT match the matcher"
[ -n "$zombie_match" ]  || fail "defunct process must NOT match the matcher"

# --- AC2 (dashboard live): with a fake session line on the wire, the served
# page counts it. Stub `ps` so the server sees a wrapped hermes session only. ---
cat > "$FAKE_HOME/bin-stubs/ps" <<'STUB'
#!/bin/bash
# Mimic `ps aux` header + one real-looking wrapped session + one non-hermes.
cat <<'PS'
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  0.0  0.1  12345  1000 ?        Ss   Jul13   0:01 /usr/sbin/cron -f
div      22151  0.5  0.5 100000 20000 ?        Sl   18:00   0:02 /home/div/.hermes/hermes-agent/venv/bin/python3 /home/div/.hermes/hermes-agent/venv/bin/hermes -p skills -z Use the engineer skill --yolo --accept-hooks
PS
STUB
chmod +x "$FAKE_HOME/bin-stubs/ps"

# Seed the JSON the renderer reads so the dashboard has a row to show
# (mirrors how engineer-ralph writes ~/ralph-status.json in production).
mkdir -p "$FAKE_HOME"
env -i HOME="$FAKE_HOME" PATH="$PATH" "$REPO_ROOT/bin/ralph-status" \
  worker skills ok 0 >/dev/null

PORT=18987
HOME="$FAKE_HOME" PORT="$PORT" BIND=127.0.0.1 \
PATH="$FAKE_HOME/bin-stubs:/usr/bin:/bin" \
python3 "$REPO_ROOT/bin/heartbeat_server.py" \
  > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

# Wait for the server to accept.
for _ in $(seq 1 40); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then break; fi
  sleep 0.1
done

body="$(curl -fsS "http://127.0.0.1:$PORT/")"

# The header text reads "1 active session(s)". The wrapped hermes -p skills -z
# line is counted, proving the per-profile dispatch path is now detected.
echo "$body" | grep -q '1 active session(s)' \
  || fail "dashboard did not count the wrapped hermes session; expected '1 active session(s)' in body"

# --- AC3 (rename): served page title + heading read "Remote Agent Dashboard" ---
echo "$body" | grep -q '<title>Remote Agent Dashboard</title>' \
  || fail "served page title != 'Remote Agent Dashboard'"
echo "$body" | grep -q '>Remote Agent Dashboard<' \
  || fail "served page heading != 'Remote Agent Dashboard'"

# The OLD title string must be gone from the live HTML.
echo "$body" | grep -q 'ralph-loop heartbeat' \
  && fail "served page still contains the OLD 'ralph-loop heartbeat' string"

# The page rendered by bin/ralph-status (the static-file renderer) must also
# carry the new title; the server we just hit reads from the live process, not
# from ~/ralph-status.html, so we re-render and grep the static file too.
echo "$body" > "$TMP/live.html"
# Re-render the static HTML via the renderer so we can also assert on it.
env -i HOME="$FAKE_HOME" PATH="$PATH" "$REPO_ROOT/bin/ralph-status" \
  worker skills ok 0 >/dev/null
[ -f "$FAKE_HOME/ralph-status.html" ] || fail "ralph-status.html not written"
grep -q '<title>Remote Agent Dashboard</title>' "$FAKE_HOME/ralph-status.html" \
  || fail "rendered ralph-status.html title != 'Remote Agent Dashboard'"
grep -q 'ralph-loop heartbeat' "$FAKE_HOME/ralph-status.html" \
  && fail "rendered ralph-status.html still contains 'ralph-loop heartbeat'"

echo "PASS: matcher handles bare + wrapped + non-hermes; dashboard counts per-profile session; page renamed to 'Remote Agent Dashboard'"