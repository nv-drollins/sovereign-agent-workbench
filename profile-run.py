#!/usr/bin/env python3
"""Where does the booth run's wall-clock actually go?

Splits the 160s run into: raw model time vs agent/sandbox overhead.
Run ON the serving node.
"""
import json, time, urllib.request, subprocess, os, sys
from pathlib import Path

DOC = os.environ.get("PROFILE_DOC", str(Path.home() / "booth/documents/grant-award.md"))
Q = "What are the three most important deadlines, and what happens if each is missed?"
URL = "http://127.0.0.1:8000/v1/chat/completions"
MODEL = os.environ.get("MODEL", "nemotron-super-120b")

doc = open(DOC).read()
prompt = f"Read the document and answer.\n\n{doc}\n\nQUESTION: {Q}"


def call(label, max_tokens=400, **extra):
    body = {"model": MODEL,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens}
    body.update(extra)
    req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    d = json.load(urllib.request.urlopen(req, timeout=900))
    el = time.time() - t0
    u = d.get("usage", {})
    m = d["choices"][0]["message"]
    ct = u.get("completion_tokens", 0)
    rl = len(m.get("reasoning") or m.get("reasoning_content") or "")
    print(f"  {label:34} {el:6.1f}s  prompt={u.get('prompt_tokens'):5}  "
          f"out={ct:4}  {ct/el if el else 0:5.1f} tok/s  reasoning_chars={rl}")
    return el


print("=== raw model, no agent ===")
call("default")
call("reasoning_effort=low", reasoning_effort="low")
call("low + 200 tok cap", 200, reasoning_effort="low")

print("\n=== through the agent (hermes in sandbox) ===")
t0 = time.time()
p = subprocess.run(
    ["timeout", "-k", "5", "400",
     os.path.expanduser("~/.local/bin/openshell"), "sandbox", "exec",
     "--name", "sovereign-agent", "--no-tty", "--timeout", "360", "--",
     "hermes", "-z", prompt, "--yolo"],
    capture_output=True, text=True)
print(f"  {'hermes -z (full agent path)':34} {time.time()-t0:6.1f}s  rc={p.returncode}")
