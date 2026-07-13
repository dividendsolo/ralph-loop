#!/usr/bin/env python3
"""Patch heartbeat_server.py: limit log scanning and remove catch-all ENG-\d+ regex."""
import re

with open("/home/div/code/ralph-loop/bin/heartbeat_server.py") as f:
    content = f.read()

# Pattern 1: remove r'ENG-\\d+' from live-output scraping
content = content.replace(
    "for pat in [r'[Pp]icked[ (]*[:\\-]*\\s*(ENG-\\d+)', r'Claimed\\s*\\(?(ENG-\\d+)', r'ENG-\\d+']:",
    "for pat in [r'[Pp]icked[ (]*[:\\-]*\\s*(ENG-\\d+)', r'Claimed\\s*\\(?(ENG-\\d+)']:"
)

# Pattern 2: limit log_lines scan to last 20 + remove catch-all
content = content.replace(
    "# Then check log for recent picks\n        for line in reversed(log_lines):",
    "# Then check log for recent picks (last 20 lines only)\n        for line in reversed(log_lines[-20:]):"
)
content = content.replace(
    "for pat in [r'[Pp]icked[ (]*[:\\-]*\\s*(ENG-\\d+)', r'Claimed\\s*\\(?(ENG-\\d+)', r'ENG-\\d+']:\n                m = re.search(pat, line)",
    "for pat in [r'[Pp]icked[ (]*[:\\-]*\\s*(ENG-\\d+)', r'Claimed\\s*\\(?(ENG-\\d+)']:\n                m = re.search(pat, line)"
)

with open("/home/div/code/ralph-loop/bin/heartbeat_server.py", "w") as f:
    f.write(content)

print("Patched OK")