#!/usr/bin/env bash
# Measure REAL serving numbers: single-stream tok/s and concurrent throughput.
# Usage: bench-model.sh <node> <served-name> [port] [concurrency]
#
# Reports tokens/sec from the server's own usage accounting, not a guess.
set -uo pipefail
NODE="${1:?need node}"
NAME="${2:?need served model name}"
PORT="${3:-8000}"
CONC="${4:-4}"

read -r -d '' PY <<'PYEOF' || true
import json, sys, time, urllib.request, concurrent.futures as cf

url, model, conc = sys.argv[1], sys.argv[2], int(sys.argv[3])
PROMPT = ("You are reviewing a federal grant award notice. List the three most "
          "important compliance deadlines a program officer must track, and say "
          "briefly why each matters.")

def one(max_tokens=256):
    body = json.dumps({"model": model,
                       "messages":[{"role":"user","content":PROMPT}],
                       "max_tokens":max_tokens, "temperature":0.2}).encode()
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type":"application/json"})
    t0=time.time()
    with urllib.request.urlopen(req, timeout=900) as r:
        d=json.load(r)
    el=time.time()-t0
    u=d.get("usage",{})
    return el, u.get("completion_tokens",0), u.get("prompt_tokens",0), \
           d["choices"][0]["message"].get("content","")

print("=== warmup ===")
el,ct,pt,txt = one(32)
print(f"  {el:.1f}s, {ct} tokens")

print("\n=== SINGLE STREAM (3 runs, 256 tok) ===")
rates=[]
for i in range(3):
    el,ct,pt,txt = one(256)
    r = ct/el if el else 0
    rates.append(r)
    print(f"  run {i+1}: {el:6.1f}s  {ct:4d} tok  {r:5.2f} tok/s  (prompt {pt})")
print(f"  AVERAGE: {sum(rates)/len(rates):.2f} tok/s")

print(f"\n=== CONCURRENT ({conc} parallel, 256 tok each) ===")
t0=time.time()
with cf.ThreadPoolExecutor(max_workers=conc) as ex:
    res=list(ex.map(lambda _: one(256), range(conc)))
wall=time.time()-t0
tot=sum(r[1] for r in res)
print(f"  wall: {wall:.1f}s   total tokens: {tot}")
print(f"  AGGREGATE: {tot/wall:.2f} tok/s   per-stream: {tot/wall/conc:.2f} tok/s")
print(f"  speedup vs single stream: {(tot/wall)/(sum(rates)/len(rates)):.2f}x")

print("\n=== SAMPLE OUTPUT (first 400 chars) ===")
print(" ", res[0][3][:400].replace("\n"," "))
PYEOF

printf '%s' "$PY" | ssh -o BatchMode=yes "nvidia@$NODE" \
  "cat > /tmp/bench_model.py && python3 /tmp/bench_model.py http://127.0.0.1:$PORT/v1/chat/completions '$NAME' $CONC"
