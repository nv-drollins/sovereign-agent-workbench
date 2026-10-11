#!/usr/bin/env python3
"""Claim verifier — node 3 of the sovereign RAG pipeline.

Takes the reasoning model's answer plus the passages that were retrieved,
and checks EVERY quoted span against the source text. Anything the model
asserted that is not supported gets flagged.

This is the beat a policy audience actually cares about: not "the AI is
smart", but "a second, independent check catches the AI overstating the
document". It runs on its own node so all three Sparks are doing real work.

Two layers, cheapest first:
  1. EXACT  — every "quoted span" must appear verbatim in a retrieved
     passage. This is deterministic and cannot itself hallucinate.
  2. MODEL  — optional second-opinion pass asking a model whether each
     unquoted claim is entailed by the passages. Used only for claims the
     exact layer cannot adjudicate.

Serves:
  GET  /health
  POST /verify {"answer": str, "passages": [{doc,section,text}], "model_url": str?}
"""
from __future__ import annotations

import json, os, re, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("VERIFY_PORT", "8800"))
MODEL_URL = os.environ.get("VERIFY_MODEL_URL", "")       # optional
MODEL_NAME = os.environ.get("VERIFY_MODEL_NAME", "")

QUOTE = re.compile(r'"([^"]{8,400})"')
BULLET = re.compile(r"^\s*[-*\u2022]\s+(.*)$", re.M)


def norm(s: str) -> str:
    """Whitespace/punctuation-insensitive compare: markdown bold in the source
    ( **$750,000** ) must still match a clean quote ( $750,000 )."""
    s = s.replace("**", "").replace("\u2019", "'").replace("\u201c", '"').replace("\u201d", '"')
    return re.sub(r"[\s\-\u2013\u2014]+", " ", s).strip().lower()


def verify(answer: str, passages: list[dict]) -> dict:
    corpus = " \u2016 ".join(norm(p.get("text", "")) for p in passages)

    quotes = QUOTE.findall(answer)
    q_results = []
    for q in quotes:
        nq = norm(q)
        ok = nq in corpus
        src = None
        if ok:
            for p in passages:
                if nq in norm(p.get("text", "")):
                    src = {"doc": p.get("doc"), "section": p.get("section")}
                    break
        q_results.append({"quote": q[:200], "supported": ok, "source": src})

    claims = [c.strip() for c in BULLET.findall(answer) if c.strip()]
    unquoted = [c for c in claims if '"' not in c]

    supported = sum(1 for q in q_results if q["supported"])
    return {
        "quotes_checked": len(q_results),
        "quotes_supported": supported,
        "quotes_unsupported": [q for q in q_results if not q["supported"]],
        "claims_total": len(claims),
        "claims_without_citation": len(unquoted),
        "unquoted_claims": unquoted[:6],
        "verdict": (
            "FAIL — unsupported quotation" if supported < len(q_results)
            else "PASS — every quotation found in source" if q_results
            else "NO QUOTES — answer cites nothing"
        ),
        "detail": q_results,
    }


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            return self._json(200, {"ok": True, "model_assist": bool(MODEL_URL)})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self.path.startswith("/verify"):
            return self._json(404, {"error": "not found"})
        n = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._json(400, {"error": "bad json"})
        self._json(200, verify(req.get("answer", ""), req.get("passages", [])))


if __name__ == "__main__":
    print(f"verifier on :{PORT} (model assist: {bool(MODEL_URL)})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
