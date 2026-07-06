#!/bin/bash
# install.sh — install the Ralph loop onto this machine.
# Symlinks the bin scripts onto your PATH so edits in this checkout stay live.
# Re-run any time to refresh. The agent procedure lives in the engineer/reviewer
# skills (installed by ~/code/skills/install.sh), not here.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST="${RALPH_BIN_DST:-$HOME/.local/bin}"

mkdir -p "$BIN_DST"

for f in "$SRC"/bin/*; do
  ln -sfn "$f" "$BIN_DST/$(basename "$f")"
  echo "✓ $BIN_DST/$(basename "$f") -> $f"
done

echo
echo "Installed. Ensure $BIN_DST is on your PATH, then run: ralph-init"
echo "Set RALPH_REPO if your Docket checkout is not at \$HOME/code/docket."
