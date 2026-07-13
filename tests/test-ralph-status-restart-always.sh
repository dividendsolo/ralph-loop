#!/bin/bash
# tests/test-ralph-status-restart-always.sh: regression for skills#51.
#
# Bug: systemd/ralph-status.service declared `Restart=on-failure`. systemd
# treats death by SIGTERM (clean exit) as not-a-failure, so an external
# `pkill` or `systemctl kill` left the dashboard permanently down until a
# human noticed and ran `systemctl --user start ralph-status`.
#
# Fix: switch to `Restart=always` (keep `RestartSec` for backoff). The
# comment header must also document the two new operator-relevant facts:
#   1. the unit is installed by COPY, so a unit-file change only takes
#      effect after re-copy + `systemctl --user daemon-reload`; and
#   2. with `Restart=always`, a plain `pkill` of the server process is a
#      valid reload path.
#
# Run: bash tests/test-ralph-status-restart-always.sh
#
# Per LEARNINGS [ENG-99]: no machine paths; the unit is read from the
# repo root, not $HOME or any system-installed copy.
#
# Per LEARNINGS [ENG-120] / [ENG-129]: assertions anchor to the specific
# lines the rule names (the `[Service]` Restart= and the deploy-comment
# block). No flattened-grep surrogates.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT="$REPO_ROOT/systemd/ralph-status.service"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$UNIT" ] || fail "unit file not found at $UNIT"

# Pull the [Service] section verbatim (from the line that opens [Service]
# through the line just before the next [Section] header). The Restart=
# directive MUST live here; a grep across the whole file would silently
# pass if `Restart=always` was added under [Install] or in a stray comment.
service_section="$(awk '
  /^\[Service\]$/ { in_section = 1; print; next }
  in_section && /^\[/ { in_section = 0; next }
  in_section { print }
' "$UNIT")"

[ -n "$service_section" ] || fail "could not locate [Service] section in $UNIT"

# --- AC 1: Restart= always, in [Service], and RestartSec kept ---
if ! grep -qx 'Restart=always' <<<"$service_section"; then
  fail "[Service] does not declare 'Restart=always' (saw: $(grep '^Restart=' <<<"$service_section" || echo none))"
fi

restart_sec_line="$(grep -E '^RestartSec=' <<<"$service_section" || true)"
[ -n "$restart_sec_line" ] || fail "[Service] dropped its RestartSec backoff (skill #51 AC requires it be retained)"
# The value must be non-empty (we don't pin a specific number; the AC only
# requires the backoff survive, not its specific value).
[[ "$restart_sec_line" =~ ^RestartSec=[^[:space:]]+ ]] || fail "RestartSec= value is empty or malformed: '$restart_sec_line'"

# --- AC 2: deploy instructions document re-copy + daemon-reload for
# unit-file changes, AND document pkill-as-reload ---
# These are comments at the top of the file (the install/deploy block).
# Pull only the leading comment block (lines starting with #) so a stray
# pkill mention buried in an unrelated comment doesn't satisfy the AC.
comment_block="$(awk '/^[^#]/ { exit } { print }' "$UNIT")"
[ -n "$comment_block" ] || fail "no comment block found at top of $UNIT"

# Re-copy + daemon-reload must be co-located in the install/deploy
# instructions. Look for both 'cp systemd/ralph-status.service' (the
# documented copy step) and 'daemon-reload' (the documented refresh step)
# in the comment block.
if ! grep -q 'cp systemd/ralph-status.service' <<<"$comment_block"; then
  fail "comment block does not document the unit copy step (cp systemd/ralph-status.service)"
fi
if ! grep -q 'daemon-reload' <<<"$comment_block"; then
  fail "comment block does not document `daemon-reload` after copying the unit"
fi

# pkill-as-reload consequence: the comment block must mention pkill AND
# reload (or restart) so an operator reading the doc knows a plain pkill
# is now a valid reload path. Both keywords must be present in the same
# block.
if ! grep -q 'pkill' <<<"$comment_block"; then
  fail "comment block does not mention pkill (operator needs to know pkill is a valid reload path)"
fi
if ! grep -qE 'reload|restart' <<<"$comment_block"; then
  fail "comment block does not document the reload/restart consequence of Restart=always"
fi

echo "PASS: ralph-status.service declares Restart=always + RestartSec, and documents re-copy + daemon-reload + pkill reload"