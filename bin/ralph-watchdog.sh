#!/bin/bash
# ralph-watchdog: self-heal stuck ralph sessions.
set -euo pipefail
HOME=/home/div

now=$(date -u +%s)
killed=0

# Kill any Hermes session running >10 min
for pid in $(ps aux | grep "hermes -z" | grep -v grep | awk '{print $2}' || true); do
  start=$(stat -c %Y /proc/$pid 2>/dev/null || echo 0)
  age=$((now - start))
  if [ "$age" -gt 600 ]; then
    kill -9 "$pid" 2>/dev/null && killed=$((killed+1))
  fi
done

# Kill >2 concurrent Hermes sessions (keep newest 2)
# ENG-171: append `|| true` so a no-match grep (the common path: hermes
# only runs briefly during a loop iteration) does not trip `set -e` via
# `pipefail` and kill the script before the heartbeat line.
sorted=$(ps aux | grep "hermes -z" | grep -v grep | awk '{print $2}' | sort -n || true)
count=$(echo "$sorted" | wc -l)
if [ "$count" -gt 2 ]; then
  echo "$sorted" | head -n -2 | while read pid; do
    kill -9 "$pid" 2>/dev/null && killed=$((killed+1))
  done
fi

# Clear stale lock files >10 min old
for lock in "$HOME/.engineer-board.lock" "$HOME/.review-board.lock"; do
  [ -f "$lock" ] && [ $((now - $(stat -c %Y "$lock"))) -gt 600 ] && rm -f "$lock"
done

# Clear stale rate-limit files
rm -f "$HOME/.work-rate-limited" "$HOME/.review-rate-limited"

echo "$(date -u +%FT%TZ) watchdog: killed $killed stale session(s), cleared locks"
