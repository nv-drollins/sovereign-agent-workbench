#!/usr/bin/env python3
"""Intake agent — parses an uploaded document into a catalogue entry.

WHAT IT IS FOR
The records repository only grew by editing files on disk. This service lets
an operator drop a document in at the booth and have it catalogued live: the
model reads it, writes a one-line summary, and proposes questions a visitor
can actually ask. The new entry then appears under "1. PICK A DOCUMENT".

WHY IT RUNS ON ITS OWN NODE
It uses a SECOND, separate model instance so an intake never competes with the
booth's answer path. The big TP=2 model stays free for visitor questions; this
one lives alongside the records repository on the third Spark, which was
otherwise only running the verifier and the watchdog.

HONESTY RULES (these are the whole reason for the booth)
  * The summary and the questions come from the model, from the document's own
    text. We never invent a plausible-looking entry.
  * If the model is unreachable or returns nothing usable, the entry still gets
    created by a DETERMINISTIC fallback and is clearly marked as such, rather
    than fabricating a summary. A booth screen must not claim a model wrote
    something it did not.
  * Proposed questions are checked against the document: a question whose key
    terms do not appear in the text is dropped. The worst outcome here is a
    suggested question the corpus cannot answer.

  GET  /health
  POST /api/parse   {"title": "...", "text": "..."} -> {title, summary, questions}
"""
from __future__ import annotations

import json, os, re, time, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("INTAKE_PORT", "8600"))
MODEL_URL = os.environ.get("INTAKE_MODEL_URL", "http://127.0.0.1:8001/v1")
MODEL_NAME = os.environ.get("INTAKE_MODEL_NAME", "intake-model")
TIMEOUT = int(os.environ.get("INTAKE_TIMEOUT", "240"))
MAX_CHARS = int(os.environ.get("INTAKE_MAX_CHARS", "9000"))

PROMPT = """You are cataloguing a document for a records repository.

Read the document and reply with ONLY a JSON object, no other text:

{{"title": "<short descriptive title, max 10 words>",
  "summary": "<ONE sentence, max 30 words, describing what this document is>",
  "questions": ["<question>", "<question>", "<question>"]}}

RULES
- The questions must be answerable FROM THIS DOCUMENT. Do not ask about
  anything the document does not cover.
- Make the questions specific to this document's content: name the actual
  deadlines, amounts, findings or parties it contains.
- Keep each question under 110 characters.

DOCUMENT
--------
{doc}
--------
"""


def call_model(text: str) -> dict | None:
    body = json.dumps({
        "model": MODEL_NAME,
        "messages": [{"role": "user", "content": PROMPT.format(doc=text[:MAX_CHARS])}],
        "max_tokens": 1200,
        "temperature": 0.2,
    }).encode()
    req = urllib.request.Request(f"{MODEL_URL}/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            data = json.load(r)
    except Exception as e:
        print(f"  intake: model call failed: {e}", flush=True)
        return None
    try:
        msg = data["choices"][0]["message"]
        # A reasoning model populates `content` AND `reasoning`; prefer content.
        raw = (msg.get("content") or "") or (msg.get("reasoning") or "")
    except Exception as e:
        print(f"  intake: unexpected response shape: {e}", flush=True)
        return None
    return extract_json(raw)


def extract_json(content: str) -> dict | None:
    """Pull a JSON object out of prose + code fences.

    A naive `{.*}` match spans from the first brace in prose to the last brace
    in a trailing example and yields invalid JSON, so fall back to counting
    braces from the LAST opening brace.
    """
    if not content:
        return None
    m = re.search(r"\{.*\}", content, re.DOTALL)
    if m:
        try:
            return json.loads(m.group())
        except Exception:
            pass
    start = content.rfind("{")
    if start >= 0:
        depth = 0
        for i in range(start, len(content)):
            if content[i] == "{":
                depth += 1
            elif content[i] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(content[start:i + 1])
                    except Exception:
                        return None
    return None


_WORD = re.compile(r"[a-z0-9$][a-z0-9$,.%-]{3,}")
STOP = {"what", "when", "which", "where", "does", "this", "that", "with", "from",
        "have", "must", "the", "and", "for", "are", "document", "report",
        "requires", "required", "happens", "under", "about", "there", "their"}


def grounded(question: str, doc_lower: str) -> bool:
    """Drop a question whose distinctive terms are absent from the document.

    Cheap guard against a suggested question the corpus cannot answer -- the
    exact failure that reads to a visitor as "the demo is broken".
    """
    terms = [w for w in _WORD.findall(question.lower()) if w not in STOP]
    if not terms:
        return False
    hits = sum(1 for t in terms if t.strip(",.%") in doc_lower)
    return hits >= max(1, len(terms) // 3)


def deterministic(title: str, text: str) -> dict:
    """No model, no invention: describe only what is measurably in the file."""
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    heads = [l.lstrip("# ").strip() for l in lines if l.startswith("#")]
    words = len(text.split())
    bits = []
    if re.search(r"\$[\d,]+", text):
        bits.append("dollar amounts")
    if re.search(r"\b\d{1,3}\s*(calendar\s+)?days?\b", text, re.I):
        bits.append("deadlines")
    if re.search(r"\b(shall|must|require[sd]?)\b", text, re.I):
        bits.append("obligations")
    what = ", ".join(bits) if bits else "narrative text"
    return {
        "title": title or (heads[0] if heads else "Uploaded document"),
        "summary": f"{words}-word document containing {what}"
                   + (f"; sections: {', '.join(heads[1:4])}" if len(heads) > 1 else "") + ".",
        "questions": [
            "What are the key dates or deadlines in this document?",
            "What dollar thresholds or amounts does it specify?",
            "What does this document NOT tell me that I would need to know?",
        ],
        "by": "deterministic parser (model unavailable)",
    }


def parse(title: str, text: str) -> dict:
    t0 = time.time()
    out = call_model(text)
    doc_lower = text.lower()
    if isinstance(out, dict) and out.get("summary"):
        qs = [str(q).strip() for q in (out.get("questions") or []) if str(q).strip()]
        kept = [q for q in qs if grounded(q, doc_lower)][:4]
        dropped = len(qs) - len(kept)
        if not kept:
            kept = deterministic(title, text)["questions"]
            dropped_note = " (model questions were not grounded in the text)"
        else:
            dropped_note = f" ({dropped} ungrounded question(s) dropped)" if dropped else ""
        return {
            "title": " ".join(str(out.get("title") or title).split())[:120] or title,
            "summary": " ".join(str(out["summary"]).split())[:300],
            "questions": kept,
            "by": f"{MODEL_NAME}{dropped_note}",
            "elapsed": round(time.time() - t0, 1),
        }
    d = deterministic(title, text)
    d["elapsed"] = round(time.time() - t0, 1)
    return d


class H(BaseHTTPRequestHandler):
    server_version = "IntakeAgent/1.0"

    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?")[0] in ("/health", "/api/health"):
            ok = False
            try:
                with urllib.request.urlopen(f"{MODEL_URL}/models", timeout=5) as r:
                    ok = bool(json.load(r).get("data"))
            except Exception:
                ok = False
            return self._send(200, {"ok": True, "model_ready": ok, "model": MODEL_NAME})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/api/parse":
            return self._send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = 0
        if n <= 0:
            return self._send(400, {"error": "empty body"})
        try:
            payload = json.loads(self.rfile.read(n).decode("utf-8", "replace"))
        except Exception as e:
            return self._send(400, {"error": f"bad JSON: {e}"})
        text = payload.get("text") or ""
        if not text.strip():
            return self._send(400, {"error": "no document text"})
        try:
            return self._send(200, parse(payload.get("title", ""), text))
        except Exception as e:
            return self._send(500, {"error": str(e)})


if __name__ == "__main__":
    print(f"intake agent on :{PORT} -> {MODEL_URL} ({MODEL_NAME})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
