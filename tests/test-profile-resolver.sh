#!/bin/bash
# tests/test-profile-resolver.sh, assert that bin/lib-profile-resolver.sh
# returns the per-repo wrapper `hermes-<repo>` when present on PATH and falls
# back to bare `hermes` when absent, and that the legs log the chosen command.
#
# Run: bash tests/test-profile-resolver.sh
# Asserts shell behavior in an isolated PATH; does NOT touch live hermes or
# real profile wrappers.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/bin/lib-profile-resolver.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$LIB" ] || fail "missing $LIB (the resolver library this card adds)"

# Source the library so we can call its functions directly.
# shellcheck disable=SC1090
. "$LIB"

# --- AC: resolver returns wrapper when present, fallback when absent ---

make_fake_path() {
  # Build a temporary dir with the requested fake binaries symlinked into it,
  # then echo a PATH-shaped string: <fake-bin>:<cleaned-real-PATH>. The fake
  # bin is prepended so its symlinks resolve first; the cleaned real PATH
  # keeps core utilities (date, rm, ln, mktemp) reachable but strips anything
  # that could leak a real hermes-* binary into the resolver's view.
  local dir
  dir="$(mktemp -d)"
  for name in "$@"; do
    ln -s /bin/true "$dir/$name"
  done
  local clean_path=""
  IFS=':' read -ra parts <<< "$PATH"
  for p in "${parts[@]}"; do
    # Skip our own previous fake bins (so successive cases stay isolated)
    # and any system path that could carry a real hermes wrapper.
    case "$p" in
      /tmp/tmp.*|*/hermes*|*/.local/bin|*/.hermes/*) continue ;;
    esac
    clean_path="${clean_path:+$clean_path:}$p"
  done
  echo "$dir:$clean_path"
}

# Path state the cases below mutate. We track the baseline real PATH so each
# case starts from a known-clean state regardless of what previous cases did.
REAL_PATH_BASE=""
collect_real_path() {
  local p=""
  IFS=':' read -ra parts <<< "$PATH"
  for x in "${parts[@]}"; do
    case "$x" in
      /tmp/tmp.*|*/hermes*|*/.local/bin|*/.hermes/*) continue ;;
    esac
    p="${p:+$p:}$x"
  done
  REAL_PATH_BASE="$p"
}
collect_real_path

# Case A: wrapper present
FAKE_BIN=$(make_fake_path hermes hermes-skills hermes-rep-sheet hermes-docket)
PATH="$FAKE_BIN" got=$(resolve_hermes_cmd skills)
[ "$got" = "hermes-skills" ] || fail "case A (skills wrapper present): expected 'hermes-skills' got '$got'"

PATH="$FAKE_BIN" got=$(resolve_hermes_cmd rep-sheet)
[ "$got" = "hermes-rep-sheet" ] || fail "case A (rep-sheet wrapper present): expected 'hermes-rep-sheet' got '$got'"

PATH="$FAKE_BIN" got=$(resolve_hermes_cmd docket)
[ "$got" = "hermes-docket" ] || fail "case A (docket wrapper present): expected 'hermes-docket' got '$got'"

rm -rf "$FAKE_BIN"

# Case B: no wrapper present (only bare hermes on PATH)
FAKE_BIN=$(make_fake_path hermes)
PATH="$FAKE_BIN:$REAL_PATH_BASE" got=$(resolve_hermes_cmd skills)
[ "$got" = "hermes" ] || fail "case B (no skills wrapper): expected 'hermes' got '$got'"

PATH="$FAKE_BIN:$REAL_PATH_BASE" got=$(resolve_hermes_cmd rep-sheet)
[ "$got" = "hermes" ] || fail "case B (no rep-sheet wrapper): expected 'hermes' got '$got'"

PATH="$FAKE_BIN:$REAL_PATH_BASE" got=$(resolve_hermes_cmd docket)
[ "$got" = "hermes" ] || fail "case B (no docket wrapper): expected 'hermes' got '$got'"

rm -rf "$FAKE_BIN"

# Case C: PATH completely empty (no hermes at all), resolver still returns
# the bare 'hermes' fallback so the loop tries the default and surfaces its
# own TRACKER_UNREACHABLE rather than the resolver itself failing.
EMPTY_BIN=$(mktemp -d)
PATH="$EMPTY_BIN:$REAL_PATH_BASE" got=$(resolve_hermes_cmd skills)
[ "$got" = "hermes" ] || fail "case C (empty PATH): expected 'hermes' got '$got'"
rm -rf "$EMPTY_BIN"

echo "OK: resolve_hermes_cmd picks wrapper when present, falls back to bare hermes"

# --- AC: resolver is deterministic and rejects empty/odd repo names ---

# Empty repo name: would produce wrapper 'hermes-' which command -v would
# happily resolve if such a binary existed. We want the resolver to reject
# this so the loop surfaces a real bug rather than silently picking a wrong
# wrapper.
FAKE_BIN=$(make_fake_path hermes hermes-)
PATH="$FAKE_BIN" got=$(resolve_hermes_cmd "" 2>/dev/null) && \
  fail "case D (empty repo): expected non-zero exit, got rc=0 output='$got'"

# Repo name with a slash (would map to a wrapper like 'hermes-skills/extra',
# invalid filename): resolver must reject.
PATH="$FAKE_BIN" got=$(resolve_hermes_cmd "skills/extra" 2>/dev/null) && \
  fail "case D (slash in repo): expected non-zero exit, got rc=0 output='$got'"
rm -rf "$FAKE_BIN"

echo "OK: resolve_hermes_cmd rejects empty / odd repo names"

# --- AC: legs (engineer-ralph, review-ralph) source the resolver and call it ---

for leg in engineer-ralph review-ralph; do
  leg_path="$REPO_ROOT/bin/$leg"
  [ -f "$leg_path" ] || fail "missing $leg_path"

  # The leg must NOT still INVOKE bare 'hermes -z' unconditionally, it must
  # route via resolve_hermes_cmd (via ralph-dispatch which sources the
  # resolver), so a wrapper swap is a one-PATH change. Comments and string
  # literals describing the command shape are fine; we only flag actual
  # invocations: `hermes -z` appearing as the first non-whitespace, non-comment
  # token on a code line.
  if grep -nE '^[[:space:]]*[^[:space:]#]' "$leg_path" | grep -qE '\bhermes[[:space:]]+-z\b'; then
    fail "$leg still invokes bare 'hermes -z' on a code line, must route via resolve_hermes_cmd"
  fi

  # The leg must export RALPH_REPO_NAME so ralph-dispatch can pick the
  # per-profile wrapper.
  grep -qF 'RALPH_REPO_NAME=' "$leg_path" \
    || fail "$leg does not export RALPH_REPO_NAME (resolver needs it)"

  # The leg must log the per-repo dispatch context, in Eastern-time format.
  grep -qF 'TZ=America/New_York' "$leg_path" \
    || fail "$leg does not stamp log lines with Eastern time"
  grep -qE 'resolve_hermes_cmd|ralph-dispatch' "$leg_path" \
    || fail "$leg does not call into ralph-dispatch (the resolver host)"
done

echo "OK: both legs source the resolver, log the choice, and route via it (no bare 'hermes -z' left)"

echo "PASS: per-profile resolver routing"