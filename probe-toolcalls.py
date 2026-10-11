#!/usr/bin/env python3
"""Does the SERVER emit structured tool_calls at all?

Isolates the layer: if vLLM returns a proper tool_calls array here, the
problem is in the agent (Hermes/OpenShell). If it returns reasoning-only
with no tool_calls, the problem is the model/parser and no agent config
will fix it.
"""
import json, sys, urllib.request, urllib.error

URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000/v1/chat/completions"
MODEL = sys.argv[2] if len(sys.argv) > 2 else "gpt-oss-120b"

TOOLS = [{
    "type": "function",
    "function": {
        "name": "run_terminal",
        "description": "Run a shell command and return its stdout.",
        "parameters": {
            "type": "object",
            "properties": {"command": {"type": "string", "description": "the shell command"}},
            "required": ["command"],
        },
    },
}]


def probe(label, **extra):
    body = {
        "model": MODEL,
        "messages": [{"role": "user", "content":
                      "Run the shell command `echo 61` using the run_terminal tool."}],
        "tools": TOOLS,
        "tool_choice": extra.pop("tool_choice", "auto"),
        "max_tokens": 300,
    }
    body.update(extra)
    req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=240) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        print(f"  {label:28} HTTP {e.code}: {e.read().decode()[:300]}")
        return
    except Exception as e:
        print(f"  {label:28} TRANSPORT ERROR {str(e)[:100]}")
        return
    if "error" in d:
        print(f"  {label:28} API ERROR {str(d['error'])[:140]}")
        return
    ch = d["choices"][0]
    m = ch["message"]
    tc = m.get("tool_calls") or []
    content = (m.get("content") or "").strip()
    reasoning = (m.get("reasoning") or m.get("reasoning_content") or "").strip()
    print(f"  {label:28} tool_calls={len(tc)} finish={ch.get('finish_reason'):12} "
          f"content_len={len(content):4d} reasoning_len={len(reasoning):5d}")
    if tc:
        f = tc[0].get("function", {})
        print(f"      -> {f.get('name')}({str(f.get('arguments'))[:70]})")


print(f"=== structured tool_calls for {MODEL} ===")
probe("tool_choice=auto")
probe("tool_choice=required", tool_choice="required")
probe("auto + low effort", reasoning_effort="low")
probe("required + low effort", tool_choice="required", reasoning_effort="low")
