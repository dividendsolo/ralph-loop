#!/bin/bash
# install.sh — install the Ralph loop onto this machine.
# Symlinks the bin scripts onto your PATH and the prompts into ~/.claude,
# so edits in this checkout stay live. Re-run any time to refresh.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST="${RALPH_BIN_DST:-$HOME/.local/bin}"
CLAUDE_DST="${RALPH_CLAUDE_DST:-$HOME/.claude}"

mkdir -p "$BIN_DST" "$CLAUDE_DST"

for f in "$SRC"/bin/*; do
  ln -sfn "$f" "$BIN_DST/$(basename "$f")"
  echo "✓ $BIN_DST/$(basename "$f") -> $f"
done

for f in "$SRC"/prompts/*.md; do
  ln -sfn "$f" "$CLAUDE_DST/$(basename "$f")"
  echo "✓ $CLAUDE_DST/$(basename "$f") -> $f"
done

echo
echo "Installed. Ensure $BIN_DST is on your PATH, then run: ralph-init"
echo "Set RALPH_REPO if your Docket checkout is not at \$HOME/code/docket."
