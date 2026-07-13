#!/bin/bash
# tests/test-heartbeat-reset-guard.sh - the tailnet-exposed heartbeat server
# must NOT act on a bare GET /reset (browser URL prefetch would kill the
# loop); it must serve a confirm page instead, and only /reset?confirm=1
# performs the reset. Also pins the PORT/BIND env contract the systemd
# unit and tests rely on.
#
# Run: bash tests/test-heartbeat-reset-guard.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$REPO_ROOT/bin/heartbeat_server.py"

fail() { echo "FAIL: $1" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 0; }
[ -f "$SERVER" ] || fail "missing $SERVER"

TMP_HOME="$(mktemp -d)"
PORT=18988

HOME="$TMP_HOME" PORT="$PORT" BIND=127.0.0.1 python3 "$SERVER" >/dev/null 2>&1 &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP_HOME"; }
trap cleanup EXIT

# Wait for the port to accept.
for _ in $(seq 1 20); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then break; fi
  sleep 0.25
done

# Dashboard renders.
body=$(curl -s "http://127.0.0.1:$PORT/")
printf '%s' "$body" | grep -q "ralph-loop heartbeat" || fail "dashboard did not render"

# Bare /reset must only confirm, never act.
reset_page=$(curl -s "http://127.0.0.1:$PORT/reset")
printf '%s' "$reset_page" | grep -q "confirm=1" || fail "bare GET /reset did not serve a confirm page"
printf '%s' "$reset_page" | grep -qi "reset complete" && fail "bare GET /reset ACTED (killed sessions) instead of confirming"

# NOTE: /reset?confirm=1 is deliberately NOT exercised here — _do_reset
# kills real `hermes -z` processes via ps, and this test may run on the
# live box between loop ticks. The guard is the safety property; the
# action path is unchanged code.

echo "PASS: heartbeat /reset is confirm-gated"
