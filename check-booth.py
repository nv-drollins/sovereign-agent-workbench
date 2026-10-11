#!/usr/bin/env python3
"""End-to-end booth check: exercise EXACTLY what a visitor's browser does.

Catches the class of bug where the backend works fine but the UI shows
nothing (e.g. /ws 404 because uvicorn was installed without [standard]).
Asserts on the EVENTS the page needs, not just HTTP 200s.
"""
import asyncio, json, sys, time, urllib.parse, urllib.request

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:8500"
DOC = "grant-award"
Q = "What are the three most important deadlines, and what happens if each is missed?"


def get(path):
    with urllib.request.urlopen(f"http://{HOST}{path}", timeout=15) as r:
        return json.load(r)


def post(path):
    req = urllib.request.Request(f"http://{HOST}{path}", method="POST", data=b"")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


async def main():
    import websockets
    ok = True

    print("1. page loads")
    with urllib.request.urlopen(f"http://{HOST}/", timeout=15) as r:
        html = r.read().decode()
    assert "Sovereign Agent" in html, "index missing"
    print("   OK")

    print("2. state has documents + model")
    s = get("/api/state")
    assert s["documents"], "no documents"
    print(f"   model={s['model']}  docs={len(s['documents'])}")

    print("3. websocket connects and RECEIVES events during a run")
    got = {"phase": 0, "answer": 0, "tick": 0}
    answer_text = ""

    async with websockets.connect(f"ws://{HOST}/ws") as ws:
        url = f"/api/run?doc={DOC}&question={urllib.parse.quote(Q)}"
        await asyncio.to_thread(post, url)
        t0 = time.time()
        while time.time() - t0 < 300:
            try:
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
            except asyncio.TimeoutError:
                continue
            got[msg.get("type", "?")] = got.get(msg.get("type", "?"), 0) + 1
            if msg.get("type") == "answer":
                answer_text = msg.get("answer", "")
                break
            if msg.get("type") == "error":
                print("   ERROR event:", msg.get("msg", "")[:200])
                ok = False
                break

    print(f"   events: {got}")
    if not answer_text:
        print("   FAIL: no answer event reached the browser")
        ok = False
    else:
        print(f"   answer {len(answer_text)} chars in {time.time()-t0:.0f}s")
        print("   first line:", answer_text.splitlines()[0][:90])

    print("4. containment proof")
    p = post("/api/prove-egress")
    blocked = [k for k, v in p.items() if v.get("blocked")]
    allowed = [k for k, v in p.items() if v.get("allowed")]
    print(f"   blocked={blocked}  allowed={allowed}")
    if not blocked or not allowed:
        print("   FAIL: containment proof incomplete")
        ok = False

    print("\n" + ("ALL CHECKS PASSED" if ok else "FAILURES PRESENT"))
    return 0 if ok else 1


sys.exit(asyncio.run(main()))
