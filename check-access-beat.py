#!/usr/bin/env python3
"""End-to-end proof of the MANUAL document-access beat, as a visitor sees it.

  1. access GRANTED  -> run -> real cited answer
  2. operator REVOKES document access
  3. same run        -> agent reports it cannot read the file (and says why)
  4. operator GRANTS -> run works again

Asserts the middle case actually FAILS. A containment demo that cannot be
shown failing is not a containment demo.
"""
import json, sys, time, urllib.parse, urllib.request

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:8500"
DOC = "grant-award"
Q = "What are the three most important deadlines?"


def post(path, timeout=240):
    req = urllib.request.Request(f"http://{HOST}{path}", method="POST", data=b"")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def get(path, timeout=90):
    with urllib.request.urlopen(f"http://{HOST}{path}", timeout=timeout) as r:
        return json.load(r)


def run_once(timeout=300):
    post(f"/api/run?doc={DOC}&question={urllib.parse.quote(Q)}", 40)
    t0 = time.time()
    while time.time() - t0 < timeout:
        time.sleep(5)
        r = (get("/api/state") or {}).get("run") or {}
        if r.get("status") in ("done", "error"):
            return r
    return {"status": "timeout", "answer": ""}


ok = True

print("=== 1. access GRANTED -> normal run ===")
a = get("/api/access")
if not a["doc_access"]:
    post("/api/access/grant"); time.sleep(3)
r = run_once()
print(f"   status={r['status']}  elapsed={round(r.get('elapsed',0),1)}s")
print(f"   {(r.get('answer') or '')[:120].replace(chr(10),' ')}…")
if r["status"] != "done":
    print("   FAIL: baseline run did not succeed"); ok = False

print("\n=== 2. operator REVOKES document access ===")
d = post("/api/access/revoke")
print(f"   doc_access={d['doc_access']}  agent probe http={d['http']}")
if d["doc_access"]:
    print("   FAIL: access still granted after revoke"); ok = False

print("\n=== 3. SAME run, nothing else changed ===")
r2 = run_once()
print(f"   status={r2['status']}")
print(f"   {(r2.get('answer') or '')[:200].replace(chr(10),' ')}")
if r2["status"] == "done":
    print("   FAIL: the run SUCCEEDED while access was revoked"); ok = False
elif "could not retrieve" not in (r2.get("answer") or "").lower():
    print("   WARN: failed, but not with the expected explanation")

print("\n=== 4. operator GRANTS access again ===")
d2 = post("/api/access/grant", 300)
print(f"   doc_access={d2['doc_access']}  http={d2['http']}")
r3 = run_once()
print(f"   status={r3['status']}  elapsed={round(r3.get('elapsed',0),1)}s")
if r3["status"] != "done":
    print("   FAIL: did not recover after granting access"); ok = False

print("\n" + ("BEAT PROVED: granted -> revoked -> blocked -> restored"
             if ok else "BEAT NOT PROVED"))
sys.exit(0 if ok else 1)
