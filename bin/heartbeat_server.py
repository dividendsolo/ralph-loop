#!/usr/bin/env python3
"""Live heartbeat server."""
import http.server
import subprocess
import os
import re
import json
from datetime import datetime, timezone, timedelta
from zoneinfo import ZoneInfo

HOME = os.environ.get("HOME", "/home/div")
ET = ZoneInfo("America/New_York")
TIER_NAMES = {0: "Opus 4.8", 1: "Sonnet 5", 2: "Hermes/MiniMax-M3"}

def tail_file(path, n=8):
    try:
        with open(path) as f:
            return "".join(f.readlines()[-n:]).rstrip()
    except (OSError, IOError):
        return ""

def get_last_action(log_path):
    try:
        with open(log_path) as f:
            lines = f.readlines()
        keywords = ["Picked", "NO_TICKETS", "NO_PRS", "iteration", "board clear", "FALLBACK", "card moved", "Merged", "opened PR", "exit", "retrying", "skipped", "reached"]
        for line in reversed(lines):
            line = line.rstrip()
            if not line:
                continue
            for kw in keywords:
                if kw in line:
                    return line[:120]
        return ""
    except OSError:
        return ""

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        now_utc = datetime.now(timezone.utc)
        now_et = now_utc.astimezone(ET)

        # /reset: kill everything, clear locks. Tailnet-exposed, so GET never
        # acts (URL prefetch, cross-site <img>). The confirm page submits a
        # same-origin POST; do_POST enforces the Origin check.
        if self.path.startswith("/reset"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"<html><body><h2>Reset the loop?</h2>"
                b"<p>Kills all Hermes sessions, clears locks and rate-limit files.</p>"
                b"<form method='POST' action='/reset'><button type='submit'>Yes, reset</button></form>"
                b"<p><a href='/'>Back to dashboard</a></p>"
                b"</body></html>")
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()

        # Get running Hermes sessions
        sessions = []
        try:
            out = subprocess.check_output(["ps", "aux"], timeout=5, text=True)
            for line in out.splitlines():
                if "hermes -z" not in line or "defunct" in line or "grep" in line:
                    continue
                parts = line.split()
                if len(parts) < 11:
                    continue
                pid = parts[1]
                elapsed = parts[9]
                cmd = " ".join(parts[10:])
                model = "default"
                if "-m" in cmd:
                    m = re.search(r'-m\s+(\S+)', cmd)
                    if m: model = m.group(1)
                leg = "engineer" if "engineer" in cmd.lower() else ("reviewer" if "reviewer" in cmd.lower() else "unknown")
                # Try to infer board from session age (use JSON last tick as fallback)
                sessions.append({"pid": pid, "elapsed": elapsed, "model": model, "leg": leg})
        except: pass

        # Load JSON for last completed tick data
        json_data = {}
        try:
            with open(os.path.join(HOME, "ralph-status.json")) as f:
                json_data = json.load(f)
        except: pass

        legs_info = {"engineer": {}, "reviewer": {}}
        for s in sessions:
            legs_info[s["leg"]] = s

        rows = []
        for leg in ["engineer", "reviewer"]:
            live = legs_info.get(leg, {})
            # Get board from JSON (most recent repo for this leg)
            repo = "-"
            ticket = "-"
            tier_label = "-"
            next_str = "-"
            try:
                iters = json_data.get("legs", {}).get(leg, {}).get("iterations", {})
                if iters:
                    best_repo, best = max(iters.items(), key=lambda kv: kv[1].get("last_tick", ""))
                    last_ts = best.get("last_tick", "")
                    if last_ts:
                        try:
                            tick_dt = datetime.fromisoformat(last_ts.replace("Z", "+00:00"))
                            if (now_utc - tick_dt).total_seconds() < 900:
                                repo = best_repo
                                if best.get("ticket"):
                                    ticket = best["ticket"]
                                next_dt = tick_dt.astimezone(ET) + timedelta(minutes=5)
                                next_str = next_dt.strftime("%H:%M%Z")
                        except: pass
                    t = best.get("tier")
                    if t is not None:
                        tier_label = TIER_NAMES.get(t, f"tier {t}")
            except: pass

            if live:
                elapsed = live.get("elapsed", "?")
                model = live.get("model", "?")
                log_file = "engineer-board.log" if leg == "engineer" else "review-board.log"
                action = get_last_action(os.path.join(HOME, log_file)) or "starting..."

                # While running, try to extract ticket from log in real-time
                if ticket == "-" or repo == "-":
                    try:
                        with open(os.path.join(HOME, log_file)) as f:
                            log_lines = f.readlines()

                        # First check live output file
                        live_output = os.path.join(HOME, ".hermes-live-output")
                        if os.path.exists(live_output):
                            with open(live_output) as lf:
                                live_text = "".join(lf.readlines()[-100:])
                            for pat in [r'[Pp]icked[ (]*[:\-]*\s*(ENG-\d+)', r'Claimed\s*\(?(ENG-\d+)']:
                                m = re.search(pat, live_text)
                                if m and ticket == "-":
                                    ticket = m.group(1)
                                    break

                        # Then check log for recent picks
                        for line in reversed(log_lines[-20:]):
                            if ticket != "-":
                                break
                            for pat in [r'[Pp]icked[ (]*[:\-]*\s*(ENG-\d+)', r'Claimed\s*\(?(ENG-\d+)']:
                                m = re.search(pat, line)
                                if m:
                                    ticket = m.group(1)
                                    break
                        # If still no board, extract repo from the session start log
                        if repo == "-":
                            for line in log_lines:
                                if "repo=/home/div/code/" in line:
                                    m2 = re.search(r'repo=/home/div/code/([a-zA-Z0-9_-]+)', line)
                                    if m2:
                                        repo = m2.group(1)
                                        break
                    except: pass

                # If running but no ticket picked and action is skipped/fallback, show cycling
                status_text = "RUNNING"
                if ticket == "-" and ("skipped" in action.lower() or "fallback" in action.lower()):
                    status_text = "cycling"
                # Determine path: primary vs fallback
                path_label = "primary" if "fallback" not in action.lower() else "fallback"
                rows.append(
                    f'<tr><td>{leg}</td><td style="color:#1a73e8;font-weight:600">{status_text}</td>'
                    f'<td>{repo}</td><td>{ticket}</td><td>{elapsed}</td>'
                    f'<td style="font-size:12px;color:#5f6368">{action[:80]}</td><td>{next_str}</td></tr>'
                )
            else:
                rows.append(
                    f'<tr><td>{leg}</td><td style="color:#5f6368">idle</td>'
                    f'<td>-</td><td>-</td>'
                    f'<td>-</td><td>-</td><td>-</td></tr>'
                )

        eng_log = tail_file(os.path.join(HOME, "engineer-board.log"))
        rev_log = tail_file(os.path.join(HOME, "review-board.log"))

        now_ts = now_utc.timestamp()
        warnings = []
        cleanup_msg = ""
        if len(sessions) > 2:
            # Group by leg, sort by PID (newer = higher PID)
            by_leg = {}
            for s in sorted(sessions, key=lambda x: x["pid"]):
                by_leg.setdefault(s["leg"], []).append(s)

            killed = []
            for leg, procs in by_leg.items():
                # Keep the newest (last), kill the rest
                for p in procs[:-1]:
                    try:
                        subprocess.run(["kill", "-9", p["pid"]], timeout=3, capture_output=True)
                        killed.append(f"{leg} PID {p['pid']}")
                    except: pass

            if killed:
                cleanup_msg = f"🧹 Killed {len(killed)} stale session(s): {', '.join(killed)}"
                # Re-scan sessions after cleanup
                sessions = []
                try:
                    out = subprocess.check_output(["ps", "aux"], timeout=5, text=True)
                    for line in out.splitlines():
                        if "hermes -z" not in line or "defunct" in line or "grep" in line:
                            continue
                        parts = line.split()
                        if len(parts) < 11: continue
                        pid, elapsed = parts[1], parts[9]
                        cmd = " ".join(parts[10:])
                        model = "default"
                        if "-m" in cmd:
                            m = re.search(r'-m\s+(\S+)', cmd)
                            if m: model = m.group(1)
                        leg = "engineer" if "engineer" in cmd.lower() else ("reviewer" if "reviewer" in cmd.lower() else "unknown")
                        sessions.append({"pid": pid, "elapsed": elapsed, "model": model, "leg": leg})
                except: pass
        stale_count = 0

        # Rule 1: more than 2 concurrent Heremes sessions is always wrong
        if len(sessions) > 2:
            warnings.append(f"⚠️ <b>{len(sessions)} concurrent sessions</b>; should be at most 2 (engineer + reviewer)")

        # Rule 2: any session running >5min is stuck
        for s in sessions:
            e = s.get("elapsed", "0")
            if ":" in e:
                try:
                    mins = int(e.split(":")[0])
                    if mins >= 5:
                        stale_count += 1
                        warnings.append(f"⚠️ <b>{s['leg']}</b> PID {s['pid']} running {e}; stuck {mins}min")
                except: pass
        for lock_name in [".engineer-board.lock", ".review-board.lock"]:
            lock_path = os.path.join(HOME, lock_name)
            try:
                age = now_ts - os.path.getmtime(lock_path)
                if age > 180:
                    name = lock_name.replace(".lock", "").replace("-board", "")
                    warnings.append(f"⚠️ <b>{name}</b> lock file {int(age)}s old")
            except OSError: pass

        warn_html = ""
        if warnings:
            w = "</div><div>".join(warnings)
            warn_html = f'<div style="background:#fce8e6;color:#c5221f;padding:12px;border-radius:4px;margin-bottom:16px;font-size:14px"><div>{w}</div></div>'

        html = f"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8">
<title>ralph-loop heartbeat</title>
<style>
body{{font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:24px;color:#202124}}
table{{border-collapse:collapse;width:100%;margin-bottom:16px}}
th,td{{border:1px solid #dadce0;padding:8px 12px;text-align:left}}
th{{background:#f8f9fa;font-weight:600}}
caption{{caption-side:top;text-align:left;font-weight:600;margin-bottom:8px;font-size:14px;color:#5f6368}}
pre, .log-pane{{font-size:12px;background:#f8f9fa;padding:12px;border:1px solid #dadce0;border-radius:4px;overflow-x:auto;white-space:pre-wrap;word-break:break-all;max-height:400px;overflow-y:auto}}
.log-container{{display:flex;gap:16px}}
.log-pane{{flex:1}}
#footer{{color:#5f6368;font-size:13px;margin-top:12px}}
</style>
<script>var t=15;function c(){{document.getElementById("cd").textContent=t;if(t--<=0)location.reload();else setTimeout(c,1000)}}</script>
</head><body onload="c()">
{warn_html}
<h2 style="margin:0 0 4px 0;font-size:18px;color:#202124">ralph-loop heartbeat</h2>
<div style="color:#5f6368;font-size:13px;margin-bottom:16px">{len(sessions)} active session(s){f' ({stale_count} stale ≥8m)' if stale_count else ''}</div>
{('<div style="background:#e8f5e9;color:#137333;padding:8px;border-radius:4px;margin-bottom:12px;font-size:13px">'+cleanup_msg+'</div>') if cleanup_msg else ''}
<table>
<thead><tr><th>agent</th><th>status</th><th>board</th><th>ticket</th><th>duration</th><th>detail</th><th>next tick</th></tr></thead>
<tbody>
{''.join(rows)}
</tbody>
</table>
<h3 style="margin-top:20px;color:#5f6368;font-size:14px">Logs</h3>
<div class="log-container">
<div class="log-pane"><strong>Engineer</strong><pre>{eng_log}</pre></div>
<div class="log-pane"><strong>Reviewer</strong><pre>{rev_log}</pre></div>
</div>
<div id="footer">refresh in <span id="cd">15</span>s &mdash; Generated: {now_et.strftime('%H:%M:%S %Z')}</div>
</body></html>"""
        self.wfile.write(html.encode())

    def do_POST(self):
        # Reset acts only on a same-origin POST: Origin (or Referer) must be
        # present AND match the Host we were addressed by. The confirm form
        # satisfies this; a cross-site POST names the attacker's origin and a
        # header-stripped request is refused too. From curl, pass it
        # explicitly: curl -X POST -H "Origin: http://<host>:8765" .../reset
        if self.path != "/reset":
            self.send_error(404)
            return
        origin = self.headers.get("Origin") or self.headers.get("Referer") or ""
        host = self.headers.get("Host", "")
        allowed = (f"http://{host}", f"https://{host}")
        if not host or not (origin in allowed or origin.startswith(tuple(a + "/" for a in allowed))):
            self.send_error(403, "cross-origin reset refused")
            return
        self._do_reset()

    def _do_reset(self):
        """Kill all Hermes sessions, clear locks and rate-limit files."""
        import os
        home = os.environ.get("HOME", "/home/div")
        killed = []
        try:
            out = subprocess.check_output(["ps", "aux"], timeout=5, text=True)
            for line in out.splitlines():
                if "hermes -z" in line and "defunct" not in line and "grep" not in line:
                    parts = line.split()
                    if len(parts) >= 2:
                        try:
                            subprocess.run(["kill", "-9", parts[1]], timeout=3, capture_output=True)
                            killed.append(parts[1])
                        except: pass
        except: pass

        # Clear lock and state files
        for f in [".engineer-board.lock", ".review-board.lock", ".work-rate-limited", ".review-rate-limited"]:
            try: os.remove(os.path.join(home, f))
            except: pass

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        msg = f"Reset complete. Killed {len(killed)} Hermes process(es), cleared locks + rate-limit files."
        self.wfile.write(f"<html><body><h2>{msg}</h2><p><a href='/'>Back to dashboard</a></body></html>".encode())

if __name__ == "__main__":
    # Served by systemd/ralph-status.service on the tailnet; auth lives at
    # the Tailscale layer. PORT/BIND env for tests and local runs.
    port = int(os.environ.get("PORT", "8765"))
    bind = os.environ.get("BIND", "0.0.0.0")
    http.server.HTTPServer((bind, port), Handler).serve_forever()
