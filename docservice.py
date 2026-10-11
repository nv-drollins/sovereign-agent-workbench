#!/usr/bin/env python3
"""Document repository — the service the agent must go through to read a case file.

WHY THIS EXISTS (it is the point of the whole demo)
Before this, the booth app read documents off local disk and pasted the text
into the prompt. The agent never "accessed" anything, so there was nothing
meaningful to revoke -- the containment beat was showing the agent losing the
MODEL, which is not the story.

Now the document lives behind a real service on its own node and its own port.
The agent must FETCH it. Revoke the OpenShell policy for that port and the
agent genuinely cannot read the case file -- it says so in its own words,
while still being able to think. That is the beat:

    "The agent is fine. Its permission to reach the records system is gone."

Every fetch is logged with who/what/when, so the booth can show an audit trail
-- the thing a records officer actually asks about.

Endpoints:
  GET /            browsable index (an attendee can see it is a real system)
  GET /health
  GET /api/docs            list
  GET /api/docs/<id>       full text  (THIS is what the agent calls)
  GET /api/audit           access log
"""
from __future__ import annotations

import json, os, re, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DOCS = Path(os.environ.get("DOCSVC_DIR", Path.home() / "rag" / "documents"))
PORT = int(os.environ.get("DOCSVC_PORT", "8900"))
AUDIT: list[dict] = []


def load():
    out = {}
    for f in sorted(DOCS.glob("*.md")):
        text = f.read_text(errors="ignore")
        title = next((l.lstrip("# ").strip() for l in text.splitlines()
                      if l.startswith("#")), f.stem)
        out[f.stem] = {"id": f.stem, "title": title, "text": text,
                       "words": len(text.split()),
                       "classification": "SYNTHETIC — demonstration only"}
    return out


LIB = load()


def audit(who, action, doc, ok):
    AUDIT.append({"t": time.time(), "who": who, "action": action,
                  "doc": doc, "granted": ok})
    del AUDIT[:-200]


class H(BaseHTTPRequestHandler):
    server_version = "RecordsRepository/1.0"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        if not isinstance(body, bytes):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _who(self):
        ua = self.headers.get("User-Agent", "")
        if "curl" in ua or "python" in ua.lower():
            return "agent (sandbox)"
        return "browser"

    def do_GET(self):
        p = self.path.split("?")[0]

        if p in ("/health", "/api/health"):
            return self._send(200, json.dumps({"ok": True, "documents": len(LIB)}))

        if p == "/api/docs":
            audit(self._who(), "list", "-", True)
            return self._send(200, json.dumps({"documents": [
                {k: v[k] for k in ("id", "title", "words", "classification")}
                for v in LIB.values()]}))

        m = re.match(r"^/api/docs/([A-Za-z0-9._-]+)$", p)
        if m:
            d = LIB.get(m.group(1))
            audit(self._who(), "read", m.group(1), bool(d))
            if not d:
                return self._send(404, json.dumps({"error": "no such document"}))
            return self._send(200, json.dumps(d))

        if p == "/api/audit":
            return self._send(200, json.dumps({"entries": AUDIT[-40:]}))

        if p == "/":
            rows = "".join(
                f"<tr><td><b>{v['title']}</b><br><span class=m>{v['id']} · "
                f"{v['words']} words · {v['classification']}</span></td>"
                f"<td><a href='/api/docs/{v['id']}'>fetch</a></td></tr>"
                for v in LIB.values())
            html = f"""<!doctype html><meta charset=utf-8>
<title>Records Repository</title>
<style>body{{background:#0b0f0c;color:#e8f0e6;font:15px system-ui;padding:26px}}
h1{{font-size:20px}} .m{{color:#8fa392;font-size:12px}}
table{{border-collapse:collapse;margin-top:14px;width:100%;max-width:760px}}
td{{border-bottom:1px solid #1f2d23;padding:10px 8px}}
a{{color:#76b900}}</style>
<h1>Records Repository <span class=m>— node {os.uname().nodename}, port {PORT}</span></h1>
<p class=m>Documents are served only from this machine. Every fetch is audited.</p>
<table>{rows}</table>"""
            return self._send(200, html, "text/html; charset=utf-8")

        self._send(404, json.dumps({"error": "not found"}))


if __name__ == "__main__":
    print(f"records repository: {len(LIB)} documents on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
