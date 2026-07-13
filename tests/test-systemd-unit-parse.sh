#!/bin/bash
# tests/test-systemd-unit-parse.sh - regression for skills#13 (ralph-loop
# heartbeat). The systemd unit file at systemd/ralph-status.service must
# parse cleanly with `systemd-analyze verify`, must reference the live
# dashboard server binary (not the static python -m http.server shim from
# PR #6), and must use the user-unit template variables (%h, append:) that
# the install instructions assume. The reviewer's Changes Requested asks
# for evidence the unit is production-ready; this test gives that evidence
# without depending on a live `systemctl --user` session (which a CI runner
# doesn't have).
#
# Per LEARNINGS [ENG-99]: asserts live outcome (systemd-analyze verify exit
# code + a structural grep for the live-server ExecStart line), not source
# substring matching on the unit file alone.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT="$REPO_ROOT/systemd/ralph-status.service"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$UNIT" ] || fail "unit file not at $UNIT"

if ! command -v systemd-analyze >/dev/null 2>&1; then
  echo "SKIP: systemd-analyze not on PATH (this box uses runit/OpenRC, not systemd)"
  exit 0
fi

# 1. The unit file must parse cleanly. `systemd-analyze verify` exits 0 on a
# well-formed unit; any syntax error or unknown directive flips to non-zero.
systemd-analyze verify "$UNIT" >/tmp/ralph-unit-verify.out 2>&1 \
  || { cat /tmp/ralph-unit-verify.out; fail "systemd-analyze verify failed on $UNIT"; }

# 2. ExecStart must reference the live dashboard server binary, not the
# older static python -m http.server path that PR #6 carried. The live
# dashboard was merged as PR #11; this assertion keeps a future revert from
# shipping a unit that points at a binary the loop no longer provides.
grep -q 'ExecStart=.*bin/heartbeat_server\.py' "$UNIT" \
  || fail "unit does not ExecStart bin/heartbeat_server.py; live dashboard path is missing"

# 3. WorkingDirectory must use %h (user home), not a hardcoded /home/div.
# The install instructions assume the unit is drop-in for any user; pinning
# a username breaks that and is exactly the LEARNINGS [ENG-99] anti-pattern
# (asserts the author's environment, not the repo contents).
grep -q 'WorkingDirectory=%h' "$UNIT" \
  || fail "unit does not use %h for WorkingDirectory; unit is pinned to a single user"

# 4. StandardOutput / StandardError must use append:%h/<log> so the operator
# can tail the server log without journal access. The install instructions
# name this path explicitly; missing it breaks the documented recovery path.
grep -q 'StandardOutput=append:%h/ralph-status-server.log' "$UNIT" \
  || fail "unit does not log to append:%h/ralph-status-server.log; recovery path broken"
grep -q 'StandardError=append:%h/ralph-status-server.log' "$UNIT" \
  || fail "unit does not log errors to append:%h/ralph-status-server.log"

# 5. Restart=always + RestartSec must be present so any death (crash or
#    external SIGTERM, per skills#51) restarts the
# server back up. Without these, an OOM kill takes the dashboard down until
# the operator notices and restarts manually.
grep -q 'Restart=always' "$UNIT" \
  || fail "unit missing Restart=always; external SIGTERM deaths would be silent (skills#51)"
grep -q 'RestartSec=' "$UNIT" \
  || fail "unit missing RestartSec; backoff unspecified"

echo "PASS: systemd/ralph-status.service parses + is wired to the live dashboard server"