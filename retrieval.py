#!/usr/bin/env python3
"""Local retrieval service — node 1 of the sovereign RAG pipeline.

Deliberately dependency-light: BM25 lexical retrieval over the document
corpus, pure stdlib. No embedding model, no torch, no network.

WHY NOT a neural embedding model (yet): for a 3-document booth corpus BM25
is strictly better value — it is exact, explainable ("matched these terms"),
starts in milliseconds, and cannot hallucinate a neighbour. An embedding
model earns its place when the corpus is large enough that vocabulary
mismatch hurts; swap `score()` then and the rest of the pipeline is unchanged.

Serves:
  GET  /health
  POST /search   {"query": str, "k": int}     -> ranked passages + scores
"""
from __future__ import annotations

import json, math, os, re, sys
from collections import Counter
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DOCS = Path(os.environ.get("RAG_DOCS", Path.home() / "rag" / "documents"))
PORT = int(os.environ.get("RAG_PORT", "8700"))

_WORD = re.compile(r"[A-Za-z0-9$%.]+")
STOP = set("the a an and or of to in for on at by is are be shall must with "
           "that this which as from any not no if it its".split())


def tok(s: str) -> list[str]:
    return [w.lower().strip(".") for w in _WORD.findall(s)
            if w.lower() not in STOP and len(w) > 1]


def split_passages(text: str, doc_id: str) -> list[dict]:
    """Split on blank lines; keep the nearest preceding heading for citation."""
    out, heading = [], ""
    for block in re.split(r"\n\s*\n", text):
        block = block.strip()
        if not block:
            continue
        if block.startswith("#"):
            heading = block.lstrip("# ").strip()
            continue
        out.append({"doc": doc_id, "section": heading, "text": block})
    return out


class Index:
    def __init__(self, docs_dir: Path):
        self.passages: list[dict] = []
        for f in sorted(docs_dir.glob("*.md")):
            self.passages += split_passages(f.read_text(errors="ignore"), f.stem)
        self.toks = [tok(p["text"]) for p in self.passages]
        self.df = Counter()
        for t in self.toks:
            self.df.update(set(t))
        self.N = max(1, len(self.passages))
        self.avdl = sum(len(t) for t in self.toks) / self.N if self.N else 1

    def score(self, query: str, k: int = 4) -> list[dict]:
        """Okapi BM25."""
        q = tok(query)
        k1, b = 1.5, 0.75
        hits = []
        for i, t in enumerate(self.toks):
            if not t:
                continue
            tf = Counter(t)
            dl = len(t)
            s = 0.0
            matched = []
            for term in q:
                f = tf.get(term, 0)
                if not f:
                    continue
                idf = math.log(1 + (self.N - self.df[term] + 0.5) / (self.df[term] + 0.5))
                s += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * dl / self.avdl))
                matched.append(term)
            if s > 0:
                p = dict(self.passages[i])
                p["score"] = round(s, 3)
                p["matched"] = sorted(set(matched))
                hits.append(p)
        hits.sort(key=lambda h: -h["score"])
        return hits[:k]


INDEX = Index(DOCS)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):          # quiet; the booth app logs instead
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
            return self._json(200, {"ok": True, "passages": len(INDEX.passages),
                                    "docs": len({p['doc'] for p in INDEX.passages})})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self.path.startswith("/search"):
            return self._json(404, {"error": "not found"})
        n = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._json(400, {"error": "bad json"})
        hits = INDEX.score(req.get("query", ""), int(req.get("k", 4)))
        self._json(200, {"query": req.get("query", ""), "hits": hits})


if __name__ == "__main__":
    print(f"retrieval: {len(INDEX.passages)} passages from {DOCS} on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
