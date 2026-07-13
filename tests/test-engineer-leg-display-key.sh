#!/bin/bash
# tests/test-engineer-leg-display-key.sh - regression for skills#13 (ralph-loop
# heartbeat). The live dashboard must show the engineer leg's row from
# `legs.worker.iterations` (the key engineer-ralph writes on every tick, per
# the loop-integration test contract). PR #7's PR carried a `record_heartbeat
# engineer` call that left stale rows under `legs.engineer.iterations`; the
# main line never used that key, so the live page has been showing `-` for the
# engineer row even when fresh worker writes were sitting under `legs.worker`.
#
# Contract:
#   - `bin/engineer-ralph` writes to legs.worker.iterations.<repo>.
#   - The dashboard's engineer row resolves repo/ticket/tier from THAT key
#     (not from a stale legs.engineer tree).
#
# Per LEARNINGS [ENG-99, ENG-129]: this is a STRUCTURAL assertion about WHERE
# the renderer reads the engineer row from, not just that some row renders.
# The test stubs both keys in the JSON and asserts the engineer row uses the
# worker key, not the engineer key.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available on this host"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME"

# Seed the JSON with BOTH keys. The worker key has fresh data (today's tick,
# real ticket id, real tier); the engineer key has stale data (5 days old, no
# ticket, tier 0). The dashboard's engineer row MUST resolve from the worker
# key, NOT from the stale engineer key.
NOW_TS="$(date -u +%FT%TZ)"
STALE_TS="2026-07-08T01:25:53Z"
cat > "$FAKE_HOME/ralph-status.json" <<EOF
{
  "legs": {
    "engineer": {
      "iterations": {
        "skills": {"last_tick": "$STALE_TS", "outcome": "no_tickets", "tier": 0, "ticket": "", "detail": ""}
      }
    },
    "worker": {
      "iterations": {
        "skills": {"last_tick": "$NOW_TS", "outcome": "ok", "tier": 2, "ticket": "ENG-999", "detail": "exit 0"}
      }
    },
    "reviewer": {
      "iterations": {
        "skills": {"last_tick": "$NOW_TS", "outcome": "no_prs", "tier": 0, "ticket": "", "detail": "exit 0"}
      }
    }
  }
}
EOF

# Render the page under HOME=$FAKE_HOME so it picks up the seeded JSON. Use a
# short script-equivalent: import the module's render logic by calling the
# server with HOME set, but cheaper. Call the same Python entrypoint with
# HOME=$FAKE_HOME and capture stdout. The server normally binds a socket; we
# exec it with a one-shot wrapper that calls the page-rendering helper
# directly. heartbeat_server.py doesn't expose a CLI render, so spawn it as a
# process under a temp http.server and curl /.
# heartbeat_server.py reads PORT + BIND env vars (default 8765 / 0.0.0.0). For
# tests we bind a high, unused port on 127.0.0.1 only so the server never
# accidentally exposes the test fixture to LAN/Tailscale.
PORT=18766
BIND=127.0.0.1
HOME="$FAKE_HOME" PORT="$PORT" BIND="$BIND" \
  python3 "$REPO_ROOT/bin/heartbeat_server.py" \
  > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

# Wait for server.
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/" > "$TMP/page.html" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
[ -s "$TMP/page.html" ] || fail "server did not respond on 127.0.0.1:$PORT"

# Structural assertion: the engineer row must show ENG-999 (from the worker
# key), NOT show the stale legs.engineer entry. The reviewer row keeps using
# legs.reviewer.
#
# Extract both rows. The page renders one <tr> per leg in a fixed order: first
# the engineer row, then the reviewer row.
ENGINEER_ROW="$(python3 -c "
import re, sys
html = open('$TMP/page.html').read()
m = re.search(r'<tr><td>engineer</td>(.*?)</tr>', html, re.DOTALL)
if not m: sys.exit('no engineer row')
print(m.group(0))
")"
REVIEWER_ROW="$(python3 -c "
import re, sys
html = open('$TMP/page.html').read()
m = re.search(r'<tr><td>reviewer</td>(.*?)</tr>', html, re.DOTALL)
if not m: sys.exit('no reviewer row')
print(m.group(0))
")"

echo "engineer row:"
echo "$ENGINEER_ROW"
echo "reviewer row:"
echo "$REVIEWER_ROW"

# The engineer row MUST surface the worker-keyed ticket (ENG-999) and the
# worker-keyed tier label (Hermes/MiniMax-M3). It MUST NOT carry the stale
# engineer-key values (no ticket, tier 0 -> 'Opus 4.8' for stale row).
grep -q 'ENG-999' <<<"$ENGINEER_ROW" \
  || fail "engineer row missing worker-keyed ticket ENG-999; got: $ENGINEER_ROW"
grep -q 'Hermes/MiniMax-M3' <<<"$ENGINEER_ROW" \
  || fail "engineer row missing worker-keyed tier label 'Hermes/MiniMax-M3'; got: $ENGINEER_ROW"

# Negative assertion: if the renderer still read legs.engineer, the row would
# show '-' for ticket and '-' / 'Opus 4.8' for tier. Catch that regression
# explicitly so a future revert shows up red.
if grep -q '<td>-</td>' <<<"$ENGINEER_ROW" && ! grep -q 'ENG-999' <<<"$ENGINEER_ROW"; then
  fail "engineer row resolved from stale legs.engineer key, not legs.worker"
fi

# The reviewer row must still resolve from legs.reviewer (not legs.worker or
# legs.engineer). The fallback list is per-leg; this guards a future change
# that broadens the engineer lookup and accidentally pulls worker rows into
# the reviewer column.
grep -q '<td>skills</td>' <<<"$REVIEWER_ROW" \
  || fail "reviewer row missing board column; got: $REVIEWER_ROW"
grep -q '<td>Opus 4.8</td>' <<<"$REVIEWER_ROW" \
  || fail "reviewer row missing reviewer-keyed tier 'Opus 4.8'; got: $REVIEWER_ROW"

echo "PASS: engineer row resolves from legs.worker; reviewer row from legs.reviewer"