#!/usr/bin/env python3
"""Probe how gpt-oss responds with and without enable_thinking.

Run ON the serving node. The point: find out whether the reasoning-only
failure can be fixed at the vLLM request level at all, before blaming the
agent layer.
"""
import json, sys, urllib.request

URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000/v1/chat/completions"
MODEL = sys.argv[2] if len(sys.argv) > 2 else "gpt-oss-120b"


def call(label, extra=None, max_tokens=64):
    body = {
        "model": MODEL,
        "messages": [{"role": "user", "content": "Say exactly: HELLO"}],
        "max_tokens": max_tokens,
    }
    if extra:
        body.update(extra)
    req = urllib.request.Request(
        URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            d = json.load(r)
    except Exception as e:
        print(f"  {label:34} TRANSPORT ERROR: {str(e)[:120]}")
        return
    if "error" in d:
        print(f"  {label:34} API ERROR: {str(d['error'])[:120]}")
        return
    ch = d["choices"][0]
    m = ch["message"]
    content = (m.get("content") or "").strip()
    reasoning = (m.get("reasoning") or m.get("reasoning_content") or "").strip()
    u = d.get("usage", {})
    print(
        f"  {label:34} content={content[:40]!r:44} "
        f"reasoning_len={len(reasoning):5d} finish={ch.get('finish_reason')} "
        f"tok={u.get('completion_tokens')}"
    )


print("=== gpt-oss reasoning behaviour ===")
call("baseline (no kwargs)")
call("enable_thinking=false", {"chat_template_kwargs": {"enable_thinking": False}})
call("reasoning_effort=low", {"reasoning_effort": "low"})
call("both", {"chat_template_kwargs": {"enable_thinking": False}, "reasoning_effort": "low"})
call("bigger budget (512 tok)", None, 512)
