#!/bin/bash
# tests/test-static-server.sh - regression for ENG-119 (ralph-loop heartbeat).
#
# Contract: bin/ralph-status writes ~/ralph-status.html; a static HTTP server
# (python3 -m http.server) must serve it on demand so the operator's tailnet
# browser can fetch it. This test starts the server in the background, GETs
# the rendered page, and asserts it contains the expected cells. The systemd
# unit (systemd/ralph-status.service) is the production deploy; this test
# covers the renderer-to-server path with the same command line.
#
# Per LEARNINGS: isolated fake HOME, asserts live outcome (response body),
# not source substrings. Skipped if python3 -m http.server is unavailable.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available on this host"
  exit 0
fi

TMP="$(mktemp -d)"
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME"

SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# Use a high, random-looking port to avoid collisions with anything else on
# the box. 18765 is arbitrary; the production port is 8765 but we don't want
# to fight for it in CI.
PORT=18765

# First, seed ralph-status.json so the rendered page has something to show.
env -i HOME="$FAKE_HOME" PATH="$PATH" "$REPO_ROOT/bin/ralph-status" \
  worker skills ok 0
env -i HOME="$FAKE_HOME" PATH="$PATH" "$REPO_ROOT/bin/ralph-status" \
  reviewer docket no_prs 2

[ -f "$FAKE_HOME/ralph-status.html" ] || fail "ralph-status.html not written"

# Start the static server in the background, serving from FAKE_HOME.
# Use --bind 127.0.0.1 so we never accidentally expose the test to LAN/Tailscale.
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FAKE_HOME" \
  > "$TMP/server.log" 2>&1 &
SERVER_PID=$!

# Wait for the server to be ready (poll up to ~5s).
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/ralph-status.html" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

# --- AC: page is served with the expected content ---
body="$(curl -fsS "http://127.0.0.1:$PORT/ralph-status.html")"
echo "$body" | grep -q '<title>Remote Agent Dashboard</title>' \
  || fail "served page missing title"
echo "$body" | grep -q 'http-equiv="refresh"' \
  || fail "served page missing meta refresh"
echo "$body" | grep -q '>worker<' \
  || fail "served page missing worker leg cell"
echo "$body" | grep -q '>skills<' \
  || fail "served page missing skills repo cell"
echo "$body" | grep -q '>Opus 4.8<' \
  || fail "served page missing tier label"

# --- AC: JSON is served too (so the operator can curl raw) ---
json="$(curl -fsS "http://127.0.0.1:$PORT/ralph-status.json")"
echo "$json" | grep -q '"worker"' || fail "JSON missing worker leg"
echo "$json" | grep -q '"skills"' || fail "JSON missing skills repo"

echo "PASS: static server serves the heartbeat page + JSON"