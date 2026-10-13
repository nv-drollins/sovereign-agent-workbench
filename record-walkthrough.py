#!/usr/bin/env python3
"""Record a walkthrough of the Sovereign Agent Workbench.

Captures the REAL booth UI from a virtual display while driving it over the
Chrome DevTools Protocol. Nothing is staged: every answer, policy flip and
HTTP code in the video is produced live by the running cluster.

    bash record-walkthrough.sh          # wrapper handles Xvfb + Chrome

Beats, in order:
    1  opening on the idle booth              (the claim)
    2  pick a document, ask, watch it answer  (it works)
    3  click the lock -> the policy popup     (what is enforced)
    4  revoke access                          (the gate closes)
    5  same question -> the agent refuses      (contained, not broken)
    6  restore access                          (and it is back)

The waiting phases are TIME-LAPSED rather than cut, so the run stays
continuous and the proof survives -- a cut looks like an edit.
"""
from __future__ import annotations

import json, os, subprocess, sys, time, urllib.request
from pathlib import Path

BOOTH = os.environ.get("BOOTH_URL", "")
if not BOOTH:
    sys.exit("set BOOTH_URL, e.g. BOOTH_URL=http://<booth-node>:8500")
CDP = os.environ.get("CDP_URL", "http://127.0.0.1:9222")
DISPLAY = os.environ.get("REC_DISPLAY", ":77")
OUT = Path(os.environ.get("REC_DIR", "/tmp/sovereign-walkthrough"))
OUT.mkdir(parents=True, exist_ok=True)

DOC = os.environ.get("REC_DOC", "grant-award")
QUESTION = os.environ.get(
    "REC_QUESTION",
    "What are the three most important deadlines, and what happens if each is missed?")


# ----------------------------------------------------------------- CDP ----
def _ws_url() -> str:
    with urllib.request.urlopen(f"{CDP}/json/list", timeout=10) as r:
        for t in json.load(r):
            if t.get("type") == "page" and "8500" in (t.get("url") or ""):
                return t["webSocketDebuggerUrl"]
    raise SystemExit("no booth page found in Chrome; is it open at the booth URL?")


def js(expr: str, timeout: int = 30):
    """Evaluate JS in the booth page. websocket-client is not installed, so
    drive CDP over a raw websocket via the stdlib-friendly `websockets` lib."""
    import asyncio
    import websockets

    async def _go():
        async with websockets.connect(_ws_url(), max_size=None,
                                      open_timeout=15, close_timeout=5) as ws:
            await ws.send(json.dumps({
                "id": 1, "method": "Runtime.evaluate",
                "params": {"expression": expr, "returnByValue": True,
                           "awaitPromise": True}}))
            while True:
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
                if msg.get("id") == 1:
                    res = msg.get("result", {}).get("result", {})
                    return res.get("value")
    return asyncio.run(_go())


def api(path: str) -> dict:
    with urllib.request.urlopen(f"{BOOTH}{path}", timeout=30) as r:
        return json.load(r)


def post(path: str, timeout: int = 240) -> dict:
    rq = urllib.request.Request(f"{BOOTH}{path}", method="POST", data=b"")
    with urllib.request.urlopen(rq, timeout=timeout) as r:
        return json.load(r)


# ------------------------------------------------------------- capture ----
def record(name: str, seconds: float) -> Path:
    """Capture the virtual display for N seconds."""
    out = OUT / f"{name}.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "0",
         "-video_size", "1920x1080", "-framerate", "15", "-i", DISPLAY,
         "-t", str(seconds), "-c:v", "libx264", "-preset", "veryfast",
         "-crf", "22", "-pix_fmt", "yuv420p", str(out)],
        check=True)
    return out


def record_until(name: str, done, limit: float = 240.0, poll: float = 2.0) -> Path:
    """Record while `done()` is false, so a slow run is never cut mid-answer."""
    out = OUT / f"{name}.mp4"
    p = subprocess.Popen(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "0",
         "-video_size", "1920x1080", "-framerate", "15", "-i", DISPLAY,
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "22",
         "-pix_fmt", "yuv420p", str(out)],
        stdin=subprocess.PIPE)
    t0 = time.time()
    try:
        while time.time() - t0 < limit:
            time.sleep(poll)
            if done():
                time.sleep(3.0)      # let the final state settle on screen
                break
    finally:
        # 'q' (not SIGKILL) so ffmpeg finalises the moov atom and the file plays
        try:
            p.communicate(input=b"q", timeout=15)
        except Exception:
            p.terminate()
            p.wait(timeout=10)
    return out


def dur(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", str(path)],
        capture_output=True, text=True).stdout.strip()
    return float(out or 0)


def timelapse(src: Path, factor: float, name: str) -> Path:
    """Speed a waiting phase up instead of cutting it: the run stays
    continuous, which is what makes it believable."""
    out = OUT / f"{name}.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
         "-vf", f"setpts=PTS/{factor},fps=15", "-c:v", "libx264",
         "-preset", "veryfast", "-crf", "22", "-pix_fmt", "yuv420p",
         "-an", str(out)], check=True)
    return out


# --------------------------------------------------------------- beats ----
def main():
    clips: list[Path] = []
    print(f"recording to {OUT}")

    # Reset the page so the opening frame is the idle booth, not a stale run.
    js("reset(); window.scrollTo(0,0); 'ok'")
    js("closePolicy && closePolicy(); 'ok'")
    time.sleep(2)

    print("1/6  opening")
    clips.append(record("01-open", 7))

    print("2/6  select the document and the question")
    js(f"""(()=>{{
      const d=[...document.querySelectorAll('#docs .doc')]
        .find(x=>x.querySelector('.t'));
      DOC={json.dumps(DOC)}; Q={json.dumps(QUESTION)}; load(); return 'set';
    }})()""")
    time.sleep(2)
    clips.append(record("02-select", 5))

    print("3/6  run the agent (live)")
    start_runs = api("/api/state")["ledger"]["runs"]

    def answered():
        r = api("/api/state").get("run") or {}
        return r.get("status") in ("done", "error")

    js("document.getElementById('run').click(); 'go'")
    raw_run = record_until("03-run-raw", answered, limit=240)
    run = api("/api/state")["run"]
    print(f"     answered in {run.get('elapsed', 0):.1f}s, status={run.get('status')}")

    # Time-lapse the thinking phase to a fixed output length so the pacing is
    # the same whether the model took 8 seconds or 40.
    raw_len = dur(raw_run)
    target = 12.0
    factor = max(1.0, round(raw_len / target, 3))
    clips.append(timelapse(raw_run, factor, "03-run") if factor > 1.05 else raw_run)
    print(f"     {raw_len:.1f}s -> {min(raw_len, target):.1f}s (x{factor})")

    print("4/6  the answer, at real speed")
    clips.append(record("04-answer", 9))

    print("5/6  the policy behind the lock")
    js("document.getElementById('gate').click(); 'open'")
    time.sleep(4)
    clips.append(record("05-policy", 9))
    js("closePolicy(); 'closed'")
    time.sleep(1.5)

    print("6/6  revoke -> refuse -> restore")
    js("document.getElementById('accbtn').click(); 'revoking'")

    def revoked():
        return api("/api/access")["doc_access"] is False

    raw_rev = record_until("06-revoke-raw", revoked, limit=180)
    rl = dur(raw_rev)
    clips.append(timelapse(raw_rev, max(1.0, round(rl / 8.0, 3)), "06-revoke")
                 if rl > 9 else raw_rev)

    # the same question, now refused
    def refused():
        r = api("/api/state").get("run") or {}
        return r.get("phase") == "denied" or r.get("status") == "error"

    js("document.getElementById('run').click(); 'go'")
    clips.append(record_until("07-refused", refused, limit=120))
    time.sleep(1)
    clips.append(record("08-refused-hold", 7))

    print("     restoring access")
    js("document.getElementById('accbtn').click(); 'granting'")

    def granted():
        return api("/api/access")["doc_access"] is True

    raw_grant = record_until("09-grant-raw", granted, limit=180)
    gl = dur(raw_grant)
    clips.append(timelapse(raw_grant, max(1.0, round(gl / 6.0, 3)), "09-grant")
                 if gl > 7 else raw_grant)
    clips.append(record("10-close", 6))

    # ------------------------------------------------------------ stitch --
    listfile = OUT / "clips.txt"
    listfile.write_text("".join(f"file '{c.resolve()}'\n" for c in clips))
    final = OUT / "walkthrough.mp4"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat",
                    "-safe", "0", "-i", str(listfile), "-c:v", "libx264",
                    "-preset", "medium", "-crf", "21", "-pix_fmt", "yuv420p",
                    str(final)], check=True)

    print(f"\n  {final}  ({dur(final):.1f}s)")
    print(f"  runs this session: {start_runs} -> {api('/api/state')['ledger']['runs']}")
    return final


if __name__ == "__main__":
    main()
