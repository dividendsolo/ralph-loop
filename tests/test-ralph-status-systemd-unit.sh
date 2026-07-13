#!/bin/bash
# tests/test-ralph-status-systemd-unit.sh: assert the systemd unit exists,
# points at python3 -m http.server on port 8765, and serves the right
# working directory. We do NOT install the unit on the box (the operator
# does that per the card body); we just validate the file the operator
# will install.
#
# Run: bash tests/test-ralph-status-systemd-unit.sh
# Per LEARNINGS [ENG-99]: no machine paths; this test is purely file-shape.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT="$REPO_ROOT/systemd/ralph-status.service"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$UNIT" ] || fail "$UNIT missing (heartbeat unit not shipped)"

# Must declare a [Unit] and [Service] section at minimum.
grep -q '^\[Unit\]' "$UNIT"   || fail "$UNIT: missing [Unit] section"
grep -q '^\[Service\]' "$UNIT" || fail "$UNIT: missing [Service] section"

# Must run the static server the card specifies: python3 -m http.server,
# port 8765, bound to 0.0.0.0 (Tailscale tailnet auth lives at the IP
# layer per the card).
grep -q 'python3' "$UNIT" || fail "$UNIT: does not run python3"
grep -q '\-m http\.server' "$UNIT" || fail "$UNIT: does not use -m http.server"
grep -q '8765' "$UNIT" || fail "$UNIT: port 8765 missing"
grep -q '0\.0\.0\.0' "$UNIT" || fail "$UNIT: must bind 0.0.0.0 (auth at Tailscale layer)"

# Restart on failure so a transient python crash does not leave the
# operator staring at a dead page.
grep -q 'Restart' "$UNIT" || fail "$UNIT: missing Restart policy"

# Working directory is $HOME so the unit serves ~/ralph-status.html.
grep -q 'WorkingDirectory=%h' "$UNIT" || \
  fail "$UNIT: WorkingDirectory must be %h so it serves ~/ralph-status.html"

echo "PASS: systemd/ralph-status.service is well-formed and matches the card's spec"
