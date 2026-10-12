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
  GET  /            browsable index (an attendee can see it is a real system)
  GET  /health
  GET  /api/docs            list
  GET  /api/docs/<id>       full text  (THIS is what the agent calls)
  GET  /api/audit           access log
  POST /api/docs            INGEST a new document (operator only, see below)

INGEST IS DELIBERATELY NOT IN THE AGENT'S POLICY.
The records policy grants the sandbox GET on /api/docs and /api/docs/* only.
Writing is done by the BOOTH APP on the operator's behalf, from the booth node
-- never by the agent. So "the agent can read what it is cleared for, and
cannot write at all" stays literally true while the repository still grows.
"""
from __future__ import annotations

import json, os, re, time, unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DOCS = Path(os.environ.get("DOCSVC_DIR", Path.home() / "rag" / "documents"))
PORT = int(os.environ.get("DOCSVC_PORT", "8900"))
MAX_UPLOAD = int(os.environ.get("DOCSVC_MAX_BYTES", str(2 * 1024 * 1024)))
AUDIT: list[dict] = []


SYNTHETIC_BANNER = "**SYNTHETIC DOCUMENT — uploaded for demonstration. Not real data.**"
# Written into uploaded files so "is this an upload?" survives a restart. The
# in-memory flag alone would make yesterday's uploads look like seed documents
# and therefore undeletable.
UPLOAD_MARK = "<!-- booth-upload -->"


def load():
    out = {}
    for f in sorted(DOCS.glob("*.md")):
        text = f.read_text(errors="ignore")
        is_upload = UPLOAD_MARK in text[:200]
        # Strip the marker from the served text: it is bookkeeping, and the
        # agent should receive the document, not our metadata.
        clean = text.replace(UPLOAD_MARK + "\n", "", 1).replace(UPLOAD_MARK, "", 1)
        title = next((l.lstrip("# ").strip() for l in clean.splitlines()
                      if l.startswith("#")), f.stem)
        out[f.stem] = {"id": f.stem, "title": title, "text": clean,
                       "words": len(clean.split()),
                       "classification": "SYNTHETIC — uploaded for demonstration"
                                         if is_upload else "SYNTHETIC — demonstration only",
                       "uploaded": f.stat().st_mtime if is_upload else None}
    return out


LIB = load()


def audit(who, action, doc, ok):
    AUDIT.append({"t": time.time(), "who": who, "action": action,
                  "doc": doc, "granted": ok})
    del AUDIT[:-200]


_SLUG_OK = re.compile(r"[^a-z0-9]+")


def slugify(title: str, fallback: str = "document") -> str:
    s = unicodedata.normalize("NFKD", title or "").encode("ascii", "ignore").decode()
    s = _SLUG_OK.sub("-", s.lower()).strip("-")
    return (s or fallback)[:48]


def unique_id(base: str) -> str:
    """Never overwrite an existing case file."""
    cand, n = base, 2
    while (DOCS / f"{cand}.md").exists():
        cand = f"{base}-{n}"
        n += 1
    return cand




def ingest(title: str, text: str) -> dict:
    """Write a new case file to disk and return its catalogue entry.

    The synthetic marking is added HERE, server-side, if the uploaded text
    does not already carry one. This demo is shown to an audience that asks
    where the data came from, and the marking has to be on the document's
    face -- not merely promised in a caption.
    """
    text = (text or "").replace("\r\n", "\n").strip()
    if not text:
        raise ValueError("document is empty")
    if len(text.encode()) > MAX_UPLOAD:
        raise ValueError(f"document exceeds {MAX_UPLOAD // 1024} KB")

    title = " ".join((title or "").split())[:120]
    if not title:
        first = next((l.lstrip("# ").strip() for l in text.splitlines() if l.strip()), "")
        title = (first or "Uploaded document")[:120]

    body = text
    if "SYNTHETIC" not in body[:400].upper():
        body = f"{SYNTHETIC_BANNER}\n\n{body}"
    if not body.lstrip().startswith("#"):
        body = f"# {title}\n\n{body}"

    doc_id = unique_id(slugify(title))
    # The marker goes on DISK only; `body` stays clean for serving.
    (DOCS / f"{doc_id}.md").write_text(f"{UPLOAD_MARK}\n{body}")

    # Serve the CLEAN body, exactly as load() does. Storing the marked text
    # here leaked "<!-- booth-upload -->" as the first line of the document
    # the agent reads, until the next service restart re-read it from disk.
    LIB[doc_id] = {"id": doc_id, "title": title, "text": body,
                   "words": len(body.split()),
                   "classification": "SYNTHETIC — uploaded for demonstration",
                   "uploaded": time.time()}
    audit("operator (booth)", "ingest", doc_id, True)
    return {k: LIB[doc_id][k] for k in ("id", "title", "words", "classification")}


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

    def do_POST(self):
        """Ingest a new case file. Operator path only.

        The agent's policy permits GET on /api/docs and /api/docs/* -- this
        method is not in it, so a sandbox attempt to POST here is refused by
        the gateway before it arrives. Worth demonstrating if asked.
        """
        p = self.path.split("?")[0]
        if p != "/api/docs":
            return self._send(404, json.dumps({"error": "not found"}))
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = 0
        if n <= 0 or n > MAX_UPLOAD:
            audit(self._who(), "ingest", "-", False)
            return self._send(413, json.dumps({"error": "empty or oversized body"}))
        raw = self.rfile.read(n)
        try:
            payload = json.loads(raw.decode("utf-8", "replace"))
            entry = ingest(payload.get("title", ""), payload.get("text", ""))
        except ValueError as e:
            audit(self._who(), "ingest", "-", False)
            return self._send(400, json.dumps({"error": str(e)}))
        except Exception as e:
            audit(self._who(), "ingest", "-", False)
            return self._send(400, json.dumps({"error": f"could not parse upload: {e}"}))
        return self._send(201, json.dumps({"document": entry}))

    def do_DELETE(self):
        """Remove an uploaded case file. Operator path only, like ingest.

        SEED DOCUMENTS ARE PROTECTED. The three shipped case files are the
        demo's known-good corpus; deleting one mid-event leaves a booth with
        nothing recognisable to show and no way back without a redeploy.
        Only documents uploaded at the booth can be removed.
        """
        m = re.match(r"^/api/docs/([A-Za-z0-9._-]+)$", self.path.split("?")[0])
        if not m:
            return self._send(404, json.dumps({"error": "not found"}))
        doc_id = m.group(1)
        d = LIB.get(doc_id)
        if not d:
            audit(self._who(), "delete", doc_id, False)
            return self._send(404, json.dumps({"error": "no such document"}))
        if not d.get("uploaded"):
            audit(self._who(), "delete", doc_id, False)
            return self._send(403, json.dumps({
                "error": "seed documents cannot be deleted; only uploads can"}))
        try:
            (DOCS / f"{doc_id}.md").unlink(missing_ok=True)
        except Exception as e:
            audit(self._who(), "delete", doc_id, False)
            return self._send(500, json.dumps({"error": f"could not remove file: {e}"}))
        LIB.pop(doc_id, None)
        audit("operator (booth)", "delete", doc_id, True)
        return self._send(200, json.dumps({"deleted": doc_id}))

    def do_GET(self):
        p = self.path.split("?")[0]

        if p in ("/health", "/api/health"):
            return self._send(200, json.dumps({"ok": True, "documents": len(LIB)}))

        if p == "/api/docs":
            audit(self._who(), "list", "-", True)
            return self._send(200, json.dumps({"documents": [
                {k: v.get(k) for k in ("id", "title", "words", "classification", "uploaded")}
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
