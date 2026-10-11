#!/usr/bin/env python3
"""Smoke-test the retrieval service with realistic booth questions."""
import json, sys, urllib.request

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:8700"
QUERIES = [
    "What dollar threshold triggers a single audit?",
    "How long do I have for closeout?",
    "Which protest grounds were sustained?",
    "What must be reported within 72 hours?",
]


def search(q, k=2):
    body = json.dumps({"query": q, "k": k}).encode()
    req = urllib.request.Request(f"http://{HOST}/search", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


for q in QUERIES:
    print(f"Q: {q}")
    for h in search(q)["hits"]:
        print(f"   [{h['score']:5.2f}] {h['doc']} / {h['section'][:38]}")
        print(f"           {h['text'][:120].replace(chr(10), ' ')}…")
        print(f"           matched: {', '.join(h['matched'][:6])}")
    print()
