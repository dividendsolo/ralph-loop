#!/bin/bash
# tests/test-iteration-order.sh -- assert that bin/engineer-board and bin/review-board
# enumerate their target repos in the operator-pinned priority order:
#   skills > rep-sheet > docket.
#
# Run: bash tests/test-iteration-order.sh
# Asserts source-file content (the iteration list), not the live cron tick.
# Per LEARNINGS: does NOT hardcode any machine path.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Print each token between `in` and `; do` on the `for NAME in ...; do` line.
extract_iteration_order() {
  awk '
    /for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+/ && /;[[:space:]]+do/ {
      line = $0
      sub(/.*for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+/, "", line)
      sub(/[[:space:]]*;[[:space:]]+do.*/, "", line)
      n = split(line, parts, /[[:space:]]+/)
      for (i = 1; i <= n; i++) print parts[i]
    }
  ' "$1"
}

assert_priority_order() {
  local label="$1" file="$2"; shift 2
  local expected=("$@") actual
  [ -f "$file" ] || fail "$label: $file missing"
  actual=$(extract_iteration_order "$file") || true
  [ -n "$actual" ] || fail "$label: no `for NAME in ...; do` line in $file"

  local actual_arr=()
  while IFS= read -r line; do actual_arr+=("$line"); done <<< "$actual"

  if [ "${#actual_arr[@]}" -ne "${#expected[@]}" ]; then
    fail "$label: expected ${#expected[@]} (${expected[*]}) got ${#actual_arr[@]} (${actual_arr[*]})"
  fi
  for i in "${!expected[@]}"; do
    [ "${actual_arr[$i]}" = "${expected[$i]}" ] || \
      fail "$label: pos $i expected '${expected[$i]}' got '${actual_arr[$i]}' (${actual_arr[*]})"
  done
  echo "OK: $label = ${actual_arr[*]}"
}

assert_priority_order "engineer-board" "$REPO_ROOT/bin/engineer-board" skills rep-sheet
assert_priority_order "review-board"   "$REPO_ROOT/bin/review-board"   skills rep-sheet docket
echo "PASS: both scripts enumerate repos in priority order"
