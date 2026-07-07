#!/bin/bash
# tests/test-multi-basename.sh — regression for ENG-126 B1.
#
# Bug: bin/work-board and bin/review-board captured jq's multi-line output into
# a scalar (REPO=$(jq ...)). When the afk.json had two repos whose basename
# matched the iteration name (e.g., two checkouts both ending in /skills), jq
# returned BOTH paths newline-joined; the scalar held the whole blob; the
# subsequent `[ ! -d "$REPO" ]` saw a string that was neither directory and
# silently skipped BOTH. Fix: iterate with `while IFS= read -r REPO; do ... done
# < <(jq ...)`.
#
# Run: bash tests/test-multi-basename.sh
# Asserts end-to-end behavior with stubbed afk-ralph / review-ralph, NOT source
# substrings — per LEARNINGS, do not assert on the author's mental model of the
# loop shape, observe the live outcome.
#
# Per LEARNINGS [ENG-99]: no machine paths; the test sets up its own isolated
# fake HOME and overrides the iteration order via a fixture afk.json.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Build an isolated fake HOME so the scripts read a fixture afk.json + write
# log/lock files into a temp dir (no clobber of the operator's real $HOME).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.local/bin" "$FAKE_HOME/bin-stubs"

# Two checkouts per name — the bug manifests only when jq returns >1 match for
# the basename. Real afk.json never has this; the test deliberately constructs
# it to demonstrate the regression. Paths MUST end in /<basename> so the jq
# filter `test("/" + $n + "$")` matches both.
mkdir -p "$TMP/repoA-code/skills" "$TMP/repoB-code/skills" "$TMP/repoA-code/rep-sheet" "$TMP/repoB-code/rep-sheet"
cat > "$FAKE_HOME/.claude/afk.json" <<EOF
{
  "repos": {
    "$TMP/repoA-code/skills":    {"tracker":"linear"},
    "$TMP/repoB-code/skills":    {"tracker":"linear"},
    "$TMP/repoA-code/rep-sheet": {"tracker":"linear"},
    "$TMP/repoB-code/rep-sheet": {"tracker":"linear"}
  }
}
EOF

# Stub afk-ralph and review-ralph: log RALPH_REPO so the test can assert both
# matching repos were visited. Place them under $FAKE_HOME/.local/bin because
# the scripts unconditionally export PATH=$HOME/.local/bin:..., which strips
# any other PATH we set up here.
LOG="$TMP/visit.log"
: > "$LOG"
cat > "$FAKE_HOME/.local/bin/afk-ralph" <<'STUB'
#!/bin/bash
echo "afk-ralph  RALPH_REPO=${RALPH_REPO:-unset}" >> "$TMP_VISIT_LOG"
STUB
cat > "$FAKE_HOME/.local/bin/review-ralph" <<'STUB'
#!/bin/bash
echo "review-ralph  RALPH_REPO=${RALPH_REPO:-unset}" >> "$TMP_VISIT_LOG"
STUB
chmod +x "$FAKE_HOME/.local/bin/afk-ralph" "$FAKE_HOME/.local/bin/review-ralph"

# Stub `flock` so the single-instance lock never blocks. Place it where the
# test's PATH will look first; the script's export PATH doesn't include this
# dir so we must prepend it via the env passed to env -i.
cat > "$FAKE_HOME/bin-stubs/flock" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$FAKE_HOME/bin-stubs/flock"

# The scripts export PATH=$HOME/.local/bin:...; we symlink jq into that dir so
# the export picks it up.
JQ_PATH="$(command -v jq)"
[ -n "$JQ_PATH" ] || fail "jq not on PATH; install jq first"
ln -s "$JQ_PATH" "$FAKE_HOME/.local/bin/jq"

env -i \
  HOME="$FAKE_HOME" \
  PATH="$FAKE_HOME/bin-stubs:$PATH" \
  TMP_VISIT_LOG="$LOG" \
  WORK_ITERS=1 \
  bash "$REPO_ROOT/bin/work-board"

env -i \
  HOME="$FAKE_HOME" \
  PATH="$FAKE_HOME/bin-stubs:$PATH" \
  TMP_VISIT_LOG="$LOG" \
  REVIEW_ITERS=1 \
  bash "$REPO_ROOT/bin/review-board"

echo "--- visit log ---"
cat "$LOG"
echo "--- end log ---"

# Both repoA and repoB must appear in the visit log for both names.
for name in skills rep-sheet; do
  for variant in repoA repoB; do
    if ! grep -q "RALPH_REPO=$TMP/$variant-code/$name" "$LOG"; then
      fail "expected afk-ralph/review-ralph to be invoked for $TMP/$variant-code/$name, but it wasn't (bug: multi-basename silent skip)"
    fi
  done
done

echo "PASS: both work-board and review-board visit every matching repo, not just the first"